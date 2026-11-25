#!/usr/bin/env bash
# Builds the app and installs it on a Roku in Developer Mode.
# Usage: tool/sideload.sh <roku-ip>
# The developer password is read from ROKU_DEV_PASSWORD, or on a Mac from the
# login Keychain item "zorofin-roku-dev". It is never stored in the repository.
set -euo pipefail
ip="${1:-${ROKU_IP:-}}"
if [[ -z "$ip" ]]; then
  echo "Usage: tool/sideload.sh <roku-ip>" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
password="${ROKU_DEV_PASSWORD:-}"
if [[ -z "$password" ]] && command -v security >/dev/null 2>&1; then
  password="$(security find-generic-password -s zorofin-roku-dev -w 2>/dev/null || true)"
fi
if [[ -z "$password" ]]; then
  echo "Set ROKU_DEV_PASSWORD or add the Keychain item zorofin-roku-dev." >&2
  exit 2
fi
node tool/package.js
# Digest auth is what the Roku developer web server accepts. The password goes
# through a curl config on stdin so it never shows in the process list.
page="$(printf 'user = "rokudev:%s"\n' "$password" | curl --silent --show-error --fail --digest --config - \
  -F "mysubmit=Install" -F "archive=@out/zorofin-roku.zip" \
  "http://$ip/plugin_install")"
printf '%s' "$page" | grep -o '<font color="red">[^<]*' | sed 's/<font color="red">//' || true
if ! printf '%s' "$page" | grep -Eq 'Install Success|Identical to previous version'; then
  echo "Roku did not confirm installation; stopping before packaging." >&2
  exit 1
fi
echo "Installed on $ip. Logs: telnet $ip 8085"
