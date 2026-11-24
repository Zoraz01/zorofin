#!/usr/bin/env python3
"""Summarize synthetic rotation traces without confusing animation with settled layout."""
import argparse
import json
import math
from pathlib import Path


def finite_vector(value, count):
    return isinstance(value, list) and len(value) == count and all(
        isinstance(v, (int, float)) and math.isfinite(v) for v in value)


def differences(row):
    errors = {}
    window, cover = row.get("windowBounds"), row.get("coverBounds")
    actual, safe = row.get("surfaceInWindow"), row.get("windowSafeRect")
    viewport, bounds, video = row.get("controlsViewport"), row.get("surfaceBounds"), row.get("videoRect")
    if finite_vector(window, 4) and finite_vector(cover, 4):
        errors["cover"] = max(abs(window[i] - cover[i]) for i in [2, 3])
    if finite_vector(actual, 4) and finite_vector(safe, 4):
        errors["surface"] = max(abs(a - b) for a, b in zip(actual, safe))
    if finite_vector(viewport, 2) and finite_vector(safe, 4):
        errors["controls"] = max(abs(viewport[0] - safe[2]), abs(viewport[1] - safe[3]))
    if row.get("readyForDisplay") and finite_vector(video, 4) and video[3] > 0 and finite_vector(bounds, 4):
        errors["videoCenter"] = max(abs(video[i] + video[i + 2] / 2 - bounds[i] - bounds[i + 2] / 2) for i in [0, 1])
        errors["videoAspect"] = abs(video[2] / video[3] - 16 / 9)
    return errors


def summarize(data):
    rows = data["samples"]
    stable = [row for row in rows if row.get("reason") == "marker" and row.get("stage", "").endswith("-settled")]
    issues = []
    for row in stable:
        errors = differences(row)
        outside = {k: round(v, 4) for k, v in errors.items() if v > (0.01 if k == "videoAspect" else 1)}
        if outside:
            issues.append(dict(t=row["t"], stage=row["stage"], errors=outside))
    longest, began, previous_t = 0, None, None
    for row in rows:
        if row.get("stage") in ["before-account-dismissal", "dismissed"]:
            break
        errors = differences(row)
        mismatch = any(v > (0.01 if k == "videoAspect" else 1) for k, v in errors.items())
        if mismatch and began is None:
            began = row["t"]
        if not mismatch and began is not None:
            longest = max(longest, row["t"] - began); began = None
        previous_t = row["t"]
    if began is not None and previous_t is not None:
        longest = max(longest, previous_t - began)
    first = data.get("firstFrameAt")
    rotation = next((row["t"] for row in rows if row.get("stage") == "first-frame-before-rotation"), None)
    rotation_row = next((row for row in rows if row.get("reason") == "marker" and row.get("stage") == "first-frame-before-rotation"), {})
    settled_at = next((row["t"] for row in rows if row.get("reason") == "marker" and row.get("stage") == "first-frame-landscape-settled"), None)
    held_at_rotation = [event["path"] for event in data.get("requests", [])
        if rotation is not None and event.get("held") and event.get("respondedAt") is not None
        and event["requestedAt"] <= rotation < event["respondedAt"]]
    held_during_rotation = sorted({event["path"] for event in data.get("requests", [])
        if rotation is not None and settled_at is not None and event.get("held") and event.get("respondedAt") is not None
        and event["requestedAt"] < settled_at and event["respondedAt"] > rotation})
    holds = [dict(path=event["path"], seconds=round(event["respondedAt"] - event["requestedAt"], 3), sendFailed=event.get("sendFailed"))
             for event in data.get("requests", []) if event.get("held") and event.get("respondedAt") is not None]
    return dict(case=data["case"], simulatorModel=data.get("simulatorModel"), os=data.get("os"),
        samples=len(rows), settledCheckpoints=len(stable), settledIssues=issues,
        settledVideoCheckpoints=sum(bool(row.get("readyForDisplay")) for row in stable),
        reachedPlaying=any(row.get("phase") == "playing" for row in rows),
        observedFailure=any(row.get("phase") == "failed" for row in rows),
        completedDismissal=any(row.get("reason") == "marker" and row.get("stage") == "dismissed" for row in rows),
        firstFrameSeconds=first,
        firstFrameToRotationSeconds=round(rotation - first, 3) if first is not None and rotation is not None else None,
        firstFrameRotationPhase=rotation_row.get("phase"), mediaHeldAtFirstRotation=held_at_rotation,
        mediaHeldDuringFirstRotation=held_during_rotation,
        longestObservedMismatchSpanSeconds=round(longest, 3),
        maxSamplingGapSeconds=round(max((b["t"] - a["t"] for a, b in zip(rows, rows[1:])), default=0), 3),
        horizontalSizeClasses=sorted({row["horizontalSizeClass"] for row in rows}),
        itemGenerations=max((row.get("itemGeneration", 0) for row in rows), default=0),
        heldRequests=holds)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachments", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    results = []
    for path in sorted(args.attachments.rglob("*.json")):
        data = json.loads(path.read_text())
        if isinstance(data, dict) and data.get("schema") == 1 and "samples" in data:
            results.append(summarize(data))
    if not results:
        parser.error("No numeric rotation traces found in exported attachments")
    text = json.dumps(results, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
