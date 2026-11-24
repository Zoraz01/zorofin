#!/usr/bin/env python3
"""Copy an xctestrun beside its source and set only the synthetic fixture path."""
import argparse
from pathlib import Path
import plistlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, output, fixture = args.xctestrun.resolve(), args.output.resolve(), args.fixture_root.resolve()
    if source == output or source.parent != output.parent:
        parser.error("Use a new sibling .xctestrun so product-relative paths stay valid")
    if not all((fixture / name).is_file() for name in ["profile.json", "master.m3u8", "stream.m3u8"]):
        parser.error("Generate the synthetic HLS fixture first")
    if output.exists():
        parser.error("Choose a fresh output .xctestrun")
    data = plistlib.loads(source.read_bytes())
    configurations = data.get("TestConfigurations", [])
    targets = [target for config in configurations for target in config.get("TestTargets", [])]
    if not configurations:
        targets = [target for target in data.values() if isinstance(target, dict)]
    changed = 0
    for target in targets:
        identity = str(target.get("BlueprintName", "")) + str(target.get("TestBundlePath", ""))
        if "Zorofin-PlayerTests" not in identity:
            continue
        target.setdefault("EnvironmentVariables", {})["ZOROFIN_ROTATION_FIXTURE_ROOT"] = str(fixture)
        changed += 1
    if changed != 1:
        parser.error(f"Expected one hosted player target, found {changed}")
    output.write_bytes(plistlib.dumps(data))
    output.chmod(0o600)
    print("Configured one hosted player target in a new sibling xctestrun")


if __name__ == "__main__":
    main()
