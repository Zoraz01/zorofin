#!/usr/bin/env bash
# Creates the Android signing key for Zorofin TV test builds and Play
# uploads, and (optionally) stores it as GitHub Actions secrets so every CI
# APK is signed the same way and installs over the previous one.
#
# Usage (from the repository root, on your Mac):
#   apps/tv/tool/android/create_signing_key.sh             # create the key
#   apps/tv/tool/android/create_signing_key.sh --github    # also set secrets
#
# The key is written outside the repository to ~/.zorofin/android/. Back it
# up somewhere safe (a password manager). Losing it means testers must
# uninstall before installing a new build, and Play needs an upload key
# reset. Never commit it.
set -euo pipefail

dir="${ZOROFIN_KEY_DIR:-$HOME/.zorofin/android}"
store="$dir/zorofin-tv-upload.jks"
alias="zorofin-tv"
set_secrets=false
[[ "${1:-}" == "--github" ]] && set_secrets=true

command -v keytool >/dev/null || {
  echo "keytool not found. Install a JDK (for example: brew install --cask temurin@17)." >&2
  exit 1
}

mkdir -p "$dir"
chmod 700 "$dir"

if [[ -f "$store" ]]; then
  echo "Using the existing key at $store"
  read -r -s -p "Keystore password: " password; echo
else
  read -r -s -p "Choose a keystore password (at least 8 characters): " password; echo
  read -r -s -p "Repeat it: " repeat; echo
  [[ "$password" == "$repeat" ]] || { echo "Passwords differ." >&2; exit 1; }
  [[ ${#password} -ge 8 ]] || { echo "Use at least 8 characters." >&2; exit 1; }
  keytool -genkeypair -v -keystore "$store" -storetype PKCS12 \
    -alias "$alias" -keyalg RSA -keysize 4096 -validity 10000 \
    -storepass "$password" -keypass "$password" \
    -dname "CN=Zorofin TV, O=Zorofin"
  chmod 600 "$store"
  echo "Created $store"
fi

# Local release builds (flutter build apk --release) pick this up.
props="$(git rev-parse --show-toplevel)/apps/tv/android/key.properties"
cat > "$props" <<PROPS
storeFile=$store
storePassword=$password
keyAlias=$alias
keyPassword=$password
PROPS
chmod 600 "$props"
echo "Wrote $props (ignored by git)"

if $set_secrets; then
  command -v gh >/dev/null || { echo "Install the GitHub CLI (brew install gh) and run gh auth login." >&2; exit 1; }
  base64 < "$store" | tr -d '\n' | gh secret set ZOROFIN_ANDROID_KEYSTORE_BASE64
  printf '%s' "$password" | gh secret set ZOROFIN_ANDROID_KEYSTORE_PASSWORD
  printf '%s' "$alias" | gh secret set ZOROFIN_ANDROID_KEY_ALIAS
  echo "GitHub secrets set. The next TV app CI run signs with this key."
else
  echo "To sign CI builds too, run again with --github (needs the gh CLI)."
fi
