#!/usr/bin/env python3
"""Opt one phone UI target into a private, bounded download journey."""
import argparse
import os
from pathlib import Path
import plistlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, output = args.xctestrun.resolve(), args.output.resolve()
    if source == output or source.parent != output.parent:
        parser.error("Choose a new sibling .xctestrun to preserve product-relative paths")
    required = ["ZOROFIN_UI_DOWNLOAD_TEST", "ZOROFIN_UI_DOWNLOAD_ITEM_ID",
                "ZOROFIN_UI_DOWNLOAD_SEARCH", "ZOROFIN_UI_DOWNLOAD_SERVER_NAME",
                "ZOROFIN_UI_DOWNLOAD_VIEWER"]
    optional = ["ZOROFIN_UI_DOWNLOAD_QUALITY", "ZOROFIN_UI_DOWNLOAD_MAX_BYTES",
                "ZOROFIN_UI_DOWNLOAD_KEEP"]
    values = {key: os.environ[key] for key in required + optional if key in os.environ}
    if any(not values.get(key, "").strip() for key in required):
        parser.error("Supply all required private download selection environment variables")
    if values["ZOROFIN_UI_DOWNLOAD_TEST"] != "1":
        parser.error("Explicit ZOROFIN_UI_DOWNLOAD_TEST=1 is required")
    if values.get("ZOROFIN_UI_DOWNLOAD_QUALITY", "Original") not in {"Original", "High", "Standard", "Data saver"}:
        parser.error("Unknown download quality")
    try:
        maximum = int(values.get("ZOROFIN_UI_DOWNLOAD_MAX_BYTES", "67108864"))
    except ValueError:
        parser.error("Maximum bytes must be an integer")
    if not 1 <= maximum <= 268_435_456:
        parser.error("Maximum bytes must be between 1 and 256 MiB")
    if values.get("ZOROFIN_UI_DOWNLOAD_KEEP", "0") not in {"0", "1"}:
        parser.error("KEEP must be 0 or 1")
    data = plistlib.loads(source.read_bytes())
    configurations = data.get("TestConfigurations", [])
    targets = [target for config in configurations for target in config.get("TestTargets", [])]
    if not configurations:
        targets = [target for target in data.values() if isinstance(target, dict)]
    selected = []
    for target in targets:
        if (target.get("BlueprintName") == "Zorofin-iPhoneUITests"
                or Path(str(target.get("TestBundlePath", ""))).name == "Zorofin-iPhoneUITests.xctest"):
            selected.append(target)
    if len(selected) != 1:
        parser.error("Expected exactly one physical iPhone UI target")
    target = selected[0]
    env = target.setdefault("EnvironmentVariables", {})
    for key in required + optional:
        env.pop(key, None)
    env.update(values)
    target["OnlyTestIdentifiers"] = ["IPhoneAcceptanceTests/testSelectedDownloadLifecycleAndCleanup"]
    # Never overwrite a previous receipt; create with restrictive permissions
    # before writing selectors. They go to the test runner, not the app.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        plistlib.dump(data, stream)
    print("Configured one phone download test in a new private sibling xctestrun")


if __name__ == "__main__":
    main()
