#!/usr/bin/env bash
# Package the older-Samsung-TV app as an UNSIGNED .wgt.
# Signing happens per TV: TizenBrew Installer or Tizen Studio signs it with a
# certificate for that TV when it installs. See apps/legacy-tv/README.md.
#   apps/legacy-tv/tool/package_wgt.sh [output-dir]
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$here/build}"
version="$(tr "\n" " " < "$here/tizen/config.xml" | sed -n 's/.*<widget[^>]* version="\([^"]*\)".*/\1/p')"
[ -n "$version" ] || { echo "No version in config.xml" >&2; exit 1; }
node --test "$here/test/app.test.js" >/dev/null
mkdir -p "$out"
file="$out/zorofin-legacy-tv-$version.wgt"
rm -f "$file"
(cd "$here/tizen" && zip -q -X -r "$file" config.xml index.html icon.png wordmark.png css js fonts img)
echo "$file"
