#!/usr/bin/env python3
"""Recover a numeric replay profile from private, offline Jellyfin evidence."""
import argparse
from fractions import Fraction
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--item", type=Path, required=True)
    parser.add_argument("--sessions", type=Path, required=True)
    parser.add_argument("--delivered-probe", type=Path, required=True)
    parser.add_argument("--resume-log", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    item = json.loads(args.item.read_text())
    sessions = json.loads(args.sessions.read_text())
    matches = [session for session in sessions
               if session.get("Client") == "Zorofin" and session.get("NowPlayingItem", {}).get("Id") == item.get("Id")]
    if len(matches) != 1:
        parser.error("Expected one matching item/client session in the offline snapshot")
    state = matches[0].get("PlayState", {})
    if state.get("PlayMethod") != "Transcode":
        parser.error("This reproducer expects a negotiated transcode")
    source_streams = item.get("MediaStreams") or item.get("MediaSources", [{}])[0].get("MediaStreams", [])
    source_video = next((stream for stream in source_streams if stream.get("Type") == "Video"), {})
    source_audio = next((stream for stream in source_streams if stream.get("Type") == "Audio"
                         and stream.get("Index") == state.get("AudioStreamIndex")), {})
    if (source_video.get("Codec") != "hevc" or source_video.get("Width") != 3840 or source_video.get("Height") != 2160
            or source_audio.get("Codec") != "eac3" or source_audio.get("Channels") != 6 or state.get("SubtitleStreamIndex") != -1):
        parser.error("This replay's source DTO supports 2160p HEVC/6-channel E-AC-3 with subtitles Off")
    raw = args.resume_log.read_text(errors="replace")
    if not item.get("Id") or item["Id"].lower() not in raw.lower():
        parser.error("Selected transcode log does not identify the same item")
    seek = re.search(r'(?<!\S)-ss\s+(\d+):(\d+):([\d.]+)', raw)
    if not seek:
        parser.error("Selected transcode log has no absolute resume seek")
    resume = 3600 * int(seek[1]) + 60 * int(seek[2]) + float(seek[3])
    streams = json.loads(args.delivered_probe.read_text())["streams"]
    video = next(stream for stream in streams if stream.get("codec_type") == "video")
    audio = next(stream for stream in streams if stream.get("codec_type") == "audio")
    if video.get("codec_name") != "h264" or audio.get("codec_name") != "aac":
        parser.error("Expected delivered H.264/AAC evidence")
    rate = Fraction(video["r_frame_rate"])
    profile = dict(durationSeconds=round(item["RunTimeTicks"] / 10_000_000, 3), resumeSeconds=round(resume, 3),
        width=video["width"], height=video["height"], frameRateNumerator=rate.numerator,
        frameRateDenominator=rate.denominator, audioSampleRate=int(audio["sample_rate"]),
        audioChannels=audio["channels"], audioStreamIndex=state["AudioStreamIndex"],
        subtitleStreamIndex=state["SubtitleStreamIndex"])
    # The output intentionally excludes identity, paths, titles, tokens, URLs,
    # raw commands and device identifiers. Treat exact session timing as private.
    args.output.write_text(json.dumps(profile, indent=2) + "\n")
    args.output.chmod(0o600)
    print("Recovered numeric replay settings from matching offline evidence; no identity or URLs exported")


if __name__ == "__main__":
    main()
