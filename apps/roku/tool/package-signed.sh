#!/usr/bin/env bash
# Makes the signed Channel Store package (.pkg) on a Roku in Developer Mode.
#
#   tool/package-signed.sh <roku-ip> --genkey   once: make the signing key
#   tool/package-signed.sh <roku-ip>            every release: build the .pkg
#
# Roku signs packages on the device. --genkey asks the Roku for a new key and
# saves its password straight into the Mac login Keychain item
# "zorofin-roku-signing" (with the key's DevID as the account), so it never
# shows on screen or in a log. Every later update must be signed with the
# same key: keep the first signed .pkg and that Keychain item safe. To sign on
# another Roku later, rekey it from that .pkg and password in the device's
# Utilities page.
#
# The developer web password comes from ROKU_DEV_PASSWORD or the Keychain item
# "zorofin-roku-dev", the signing password from ROKU_SIGNING_PASSWORD or
# "zorofin-roku-signing". Neither is stored in the repository.
set -euo pipefail
ip="${1:-${ROKU_IP:-}}"
mode="${2:-}"
if [[ -z "$ip" ]]; then
  echo "Usage: tool/package-signed.sh <roku-ip> [--genkey]" >&2
  exit 2
fi
cd "$(dirname "$0")/.."

keychain() {
  command -v security >/dev/null 2>&1 && security find-generic-password -s "$1" -w 2>/dev/null || true
}

if [[ "$mode" == "--genkey" ]]; then
  if [[ -n "$(keychain zorofin-roku-signing)" ]]; then
    echo "A signing key is already saved (zorofin-roku-signing). Packages must keep using it; not making a new one." >&2
    exit 1
  fi
  out="$(printf 'genkey\n' | nc -w 30 "$ip" 8080 || true)"
  password="$(printf '%s\n' "$out" | sed -n 's/^Password: *//p' | tr -d '\r' | head -n1)"
  devid="$(printf '%s\n' "$out" | sed -n 's/^DevID: *//p' | tr -d '\r' | head -n1)"
  if [[ -z "$password" || -z "$devid" ]]; then
    echo "The Roku did not return a key. Check Developer Mode and that port 8080 is reachable." >&2
    exit 1
  fi
  # Through security's command mode on stdin, so the password never appears
  # in the process list. Roku key passwords are letters and digits only.
  printf 'add-generic-password -s zorofin-roku-signing -a %s -w %s\n' "$devid" "$password" | security -i >/dev/null
  if [[ -z "$(keychain zorofin-roku-signing)" ]]; then
    echo "Saving the password to Keychain failed. The key exists on the Roku (DevID $devid); run genkey again only after removing it in the device's Utilities." >&2
    exit 1
  fi
  echo "Signing key made on $ip (DevID $devid). Password saved in Keychain item zorofin-roku-signing."
  exit 0
fi

dev="${ROKU_DEV_PASSWORD:-$(keychain zorofin-roku-dev)}"
signing="${ROKU_SIGNING_PASSWORD:-$(keychain zorofin-roku-signing)}"
if [[ -z "$dev" ]]; then echo "Set ROKU_DEV_PASSWORD or add the Keychain item zorofin-roku-dev." >&2; exit 2; fi
if [[ -z "$signing" ]]; then echo "No signing key yet. Run: tool/package-signed.sh $ip --genkey" >&2; exit 2; fi

version="$(sed -n 's/^major_version=//p' manifest).$(sed -n 's/^minor_version=//p' manifest).$(sed -n 's/^build_version=//p' manifest)"

# Install the exact build to package, then ask the Roku to sign it. Passwords
# go to curl through a config on stdin so they never appear in the process list.
tool/sideload.sh "$ip"
page="$(printf 'user = "rokudev:%s"\nform-string = "passwd=%s"\n' "$dev" "$signing" | curl --silent --show-error --fail --digest --config - \
  -F "mysubmit=Package" -F "app_name=Zorofin/$version" -F "pkg_time=$(date +%s)000" \
  "http://$ip/plugin_package")"
pkg="$(printf '%s' "$page" | grep -o 'pkgs//*[A-Za-z0-9_.-]*\.pkg' | head -n1 | sed 's#//*#/#g')"
if [[ -z "$pkg" ]]; then
  printf '%s' "$page" | grep -o '<font color="red">[^<]*' | sed 's/<font color="red">/Roku: /' >&2 || true
  echo "Packaging failed. A wrong signing password or a different key on this Roku are the usual causes." >&2
  exit 1
fi
mkdir -p out
dest="out/zorofin-roku-$version.pkg"
printf 'user = "rokudev:%s"\n' "$dev" | curl --silent --show-error --fail --digest --config - -o "$dest" "http://$ip/$pkg"
echo "Signed package: apps/roku/$dest ($(wc -c < "$dest" | tr -d ' ') bytes). Upload it in the Roku Developer Dashboard."
