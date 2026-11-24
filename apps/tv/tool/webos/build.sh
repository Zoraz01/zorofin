#!/usr/bin/env bash
# Builds the LG webOS .ipk inside the Ubuntu container.
# Usage: apps/tv/tool/webos/build.sh [--debug|--profile|--release]
set -euo pipefail

mode="${1:---release}"
app_dir="$(cd "$(dirname "$0")/../.." && pwd)"
image="zorofin-flutter-webos"

docker build --platform linux/amd64 -t "$image" "$app_dir/tool/webos"
docker run --rm --platform linux/amd64 -v "$app_dir:/work" "$image" bash -lc "
  . \"\$WEBOS_FLUTTER_NDK_ENV\" &&
  flutter-webos pub get &&
  flutter-webos build webos $mode
"
find "$app_dir/build/webos" -name '*.ipk' -print
