#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
flutter_command="${FLUTTER:-flutter}"
"$flutter_command" build web --release --no-web-resources-cdn --pwa-strategy=none \
  --dart-define=ZOROFIN_WEBOS_WEB=true "$@"
python3 tool/webos-web/prepare.py
cli="${ARES_PACKAGE:-$PWD/tool/webos-web/node_modules/.bin/ares-package}"
"$cli" build/webos-web/app --outdir build/webos-web
