#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/web-core-tests
dart run tool/verify_web_core.dart
dart compile js -O2 -o build/web-core-tests/verify.js tool/verify_web_core.dart
node build/web-core-tests/verify.js
