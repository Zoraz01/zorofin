#!/usr/bin/env python3
"""Verify signed TV packages without rewriting them; retain failure diagnostics."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
EXPECTED_SIGNER = "6FCFA866159A3A404F007EDA38ABEC1BCD5FC783EEF37E90DC19204EA93EF971"
PACKAGE = "org.zorofin.tv"


def require(condition, message):
    if not condition:
        raise ValueError(message)


DISTRIBUTIONS = ("universal-tv", "google-play-tv", "google-play-mobile")


def check_manifest(xml, version_code, distribution):
    require(distribution in DISTRIBUTIONS, "Unknown distribution")
    root = ET.fromstring(xml)
    require(root.tag == "manifest", "Missing manifest root")
    require(root.get("package") == PACKAGE, "Unexpected package ID")
    require(root.get(ANDROID + "versionCode") == str(version_code), "Wrong versionCode")
    require(root.get(ANDROID + "versionName") == "1.4.0", "Wrong versionName")
    features = root.findall("uses-feature")
    for name, expected in (
        ("android.software.leanback", "true" if distribution == "google-play-tv" else "false"),
        ("android.hardware.touchscreen", "false"),
    ):
        matches = [f for f in features if f.get(ANDROID + "name") == name]
        require(len(matches) == 1, f"Expected exactly one {name} declaration")
        require(matches[0].get(ANDROID + "required") == expected,
                f"{distribution}: {name} must explicitly require={expected}")
    app = root.find("application")
    require(app is not None, "Missing application")
    require(app.get(ANDROID + "debuggable", "false") == "false", "Debuggable release")
    require(app.get(ANDROID + "allowBackup") == "false", "Backup protection missing")
    require(bool(app.get(ANDROID + "banner")), "TV banner missing")
    launchers = set()
    for activity in app.findall("activity") + app.findall("activity-alias"):
        if activity.get(ANDROID + "exported") != "true":
            continue
        for intent in activity.findall("intent-filter"):
            actions = {a.get(ANDROID + "name") for a in intent.findall("action")}
            categories = {c.get(ANDROID + "name") for c in intent.findall("category")}
            if "android.intent.action.MAIN" in actions:
                launchers |= categories
    require("android.intent.category.LEANBACK_LAUNCHER" in launchers,
            "Exported MAIN/LEANBACK_LAUNCHER activity missing")
    if distribution == "google-play-mobile":
        # Phones and tablets open the same activity from their launcher.
        require("android.intent.category.LAUNCHER" in launchers,
                "Exported MAIN/LAUNCHER activity missing")
    sdk = root.find("uses-sdk")
    return {"distribution": distribution, "packageId": PACKAGE,
            "versionCode": int(version_code), "versionName": "1.4.0",
            "leanbackRequired": distribution == "google-play-tv",
            "touchscreenRequired": False,
            "minSdk": sdk.get(ANDROID + "minSdkVersion") if sdk is not None else None,
            "targetSdk": sdk.get(ANDROID + "targetSdkVersion") if sdk is not None else None}


def check_apk_signer(text):
    # Older tools say Signer #1; build-tools 37+ uses V2 Signer: / V3.1 Signer:.
    digests = {value.upper() for value in re.findall(
        r"^(?:Signer #\d+|V\d+(?:\.\d+)* Signer:)\s+certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$",
        text, re.M)}
    require(bool(re.search(r"^Number of signers:\s*1\s*$", text, re.M)),
            "Expected one APK signer")
    require(digests == {EXPECTED_SIGNER}, "APK signing certificate missing/mismatched")


def check_aab_signer(verification, certificates):
    require(bool(re.search(r"^jar verified\.\s*$", verification, re.M)),
            "jarsigner did not positively verify the AAB")
    require("unsigned entries" not in verification.lower(), "AAB contains unsigned entries")
    digests = re.findall(r"^\s*SHA256:\s*([0-9A-Fa-f:]+)\s*$", certificates, re.M)
    require([v.replace(":", "").upper() for v in digests] == [EXPECTED_SIGNER],
            "Expected exactly the existing AAB signing certificate")


def git(*args):
    return subprocess.check_output(["git", "-c", "core.fsmonitor=false", *args], text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--aab", type=Path, required=True)
    parser.add_argument("--aab-distribution", choices=DISTRIBUTIONS[1:], default="google-play-tv")
    parser.add_argument("--bundletool", type=Path, required=True)
    parser.add_argument("--build-tools", type=Path, required=True)
    parser.add_argument("--apkanalyzer", type=Path, required=True)
    parser.add_argument("--version-code", type=int, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    marker = args.output / "UNVERIFIED.txt"
    marker.write_text("Diagnostic packages only. Do not install/upload until verification passes.\n")
    receipt = {"verificationStatus": "unverified", "expectedSourceSha": args.source_sha,
               "workflowRunId": os.environ.get("GITHUB_RUN_ID"),
               "workflowRunNumber": os.environ.get("GITHUB_RUN_NUMBER"),
               "expectedVersionCode": args.version_code,
               "expectedDartDefines": {"ZOROFIN_REQUESTS": "true", "ZOROFIN_PREVIEW_SEED": "1"},
               "artifacts": [],
               "deviceAcceptance": "pending", "playAcceptance": "pending"}

    def run(label, command):
        print(f"Verifying {label}", flush=True)
        result = subprocess.run([str(x) for x in command], capture_output=True, text=True)
        (args.output / f"{label}.txt").write_text(result.stdout + result.stderr)
        # Public package/tool diagnostics only; never pass signing passwords here.
        print(result.stdout + result.stderr, flush=True)
        require(result.returncode == 0, f"{label} failed, exit {result.returncode}")
        return result.stdout

    try:
        receipt["sourceSha"] = git("rev-parse", "HEAD")
        require(receipt["sourceSha"] == args.source_sha, "Source SHA mismatch")
        require(not git("status", "--porcelain"), "Source checkout is dirty")
        for path in (args.apk, args.aab):
            require(path.is_file(), f"Missing package: {path}")
            receipt["artifacts"].append({"name": path.name, "bytes": path.stat().st_size,
                                         "sha256": sha256(path)})
        apk_signer = run("apk-signature", [args.build_tools / "apksigner", "verify",
                                          "--verbose", "--print-certs", args.apk])
        check_apk_signer(apk_signer)
        run("apk-alignment", [args.build_tools / "zipalign", "-c", "-P", "16", "-v", "4", args.apk])
        jar = run("aab-signature", ["jarsigner", "-J-Duser.language=en", "-J-Duser.country=US",
                                    "-verify", args.aab])
        cert = run("aab-certificate", ["keytool", "-J-Duser.language=en", "-J-Duser.country=US",
                                      "-printcert", "-jarfile", args.aab])
        check_aab_signer(jar, cert)
        run("aab-validation", ["java", "-jar", args.bundletool, "validate", f"--bundle={args.aab}"])
        apk_xml = run("apk-manifest", [args.apkanalyzer, "manifest", "print", args.apk])
        aab_xml = run("aab-manifest", ["java", "-jar", args.bundletool, "dump", "manifest",
                                      f"--bundle={args.aab}", "--module=base"])
        receipt["manifests"] = {
            "apk": check_manifest(apk_xml, args.version_code, "universal-tv"),
            "aab": check_manifest(aab_xml, args.version_code, args.aab_distribution),
        }
        run("aab-config", ["java", "-jar", args.bundletool, "dump", "config", f"--bundle={args.aab}"])
        for path, artifact in zip((args.apk, args.aab), receipt["artifacts"]):
            require(sha256(path) == artifact["sha256"], f"Package changed during verification: {path}")
        require(not git("status", "--porcelain"), "Source changed during verification")
        receipt["certificateSha256"] = EXPECTED_SIGNER
        receipt["verificationStatus"] = "verified"
        marker.unlink()
    except Exception as exc:
        receipt["failure"] = str(exc)
        print(f"::error::{exc}", file=sys.stderr)
    finally:
        (args.output / "common-android-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return 0 if receipt["verificationStatus"] == "verified" else 1


if __name__ == "__main__":
    sys.exit(main())
