#!/usr/bin/env bash
# Builds the Samsung Tizen TV .tpk with flutter-tizen.
#
# flutter-tizen ships a newer Flutter than the one pinned for the LG and
# Android builds, and the Tizen plugin implementations need it. To keep the
# shared pubspec.lock untouched, the app is copied to build/tizen-stage and the
# Tizen-only packages are added there.
#
# Usage: apps/tv/tool/tizen/build_tpk.sh [--release|--debug] [--build-name X] [--build-number N]
# Needs: flutter-tizen on PATH, .NET SDK 8+, Tizen SDK (TIZEN_SDK) with an
# active certificate profile. See docs/SAMSUNG_TIZEN.md.
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/../.." && pwd)"
build_dir="${ZOROFIN_TIZEN_BUILD_DIR:-$app_dir/build}"
stage="$build_dir/tizen-stage"
mode="--release"
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|--debug|--profile) mode="$1"; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done

rm -rf "$stage" && mkdir -p "$stage"
tar -C "$app_dir" -cf - \
  --exclude=./build --exclude=./.dart_tool --exclude=./android --exclude=./webos \
  --exclude=./linux --exclude=./tool --exclude=./tizen/flutter \
  --exclude=./release --exclude=./tizen/bin --exclude=./tizen/obj . | tar -C "$stage" -xf -

cd "$stage"
# LG-only packages are pulled from git and not needed on Tizen.
python3 - <<'PY'
import re
p = open("pubspec.yaml").read()
p = re.sub(r"^  (?:video_player_webos|shared_preferences_webos):\n(?:[ \t]{4}[^\n]*\n)*", "", p, flags=re.MULTILINE)
open("pubspec.yaml", "w").write(p)
PY
if [[ -f "$app_dir/release/tizen/pubspec.lock" ]]; then
  cp "$app_dir/release/tizen/pubspec.lock" pubspec.lock
else
  rm -f pubspec.lock
fi
flutter-tizen pub add video_player_tizen:2.6.0 shared_preferences_tizen:2.3.5
# Give the generated entrypoint a package URI so release snapshots do not
# embed the build machine's absolute workspace path.
python3 - <<'PY'
import json
from pathlib import Path
p = Path('.dart_tool/package_config.json')
c = json.loads(p.read_text())
c['packages'].append({'name': 'zorofin_tizen_runner', 'rootUri': '../tizen/flutter/',
                      'packageUri': '', 'languageVersion': '3.10'})
p.write_text(json.dumps(c, indent=2) + '\n')
PY
export PathMap="$stage=/_/app,${TIZEN_FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter-tizen)")/.." && pwd)}=/_/sdk"
flutter-tizen build tpk --no-pub --device-profile tv "$mode" ${extra[@]+"${extra[@]}"}
mkdir -p "$build_dir/tizen"
cp build/tizen/tpk/*.tpk "$build_dir/tizen/"
ls -l "$build_dir/tizen/"*.tpk
