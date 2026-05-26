#!/bin/bash
# Build Tatami in Debug, re-sign with a local Apple Development cert
# so the binary hash stays stable across rebuilds (otherwise macOS
# re-prompts for every TCC permission), and install into /Applications.
#
# Cert selection priority:
#   1. $TATAMI_CERT_HASH (explicit hash via env var)
#   2. $TATAMI_CERT_NAME (explicit name via env var, e.g. "Apple Development: <name>")
#   3. First available Apple Development cert from the login keychain
#
# Keep all identifying info out of the repo by relying on these.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Tatami/Tatami.entitlements"
SRC="$HOME/Library/Developer/Xcode/DerivedData/Tatami-abzoohblcyzqwbfbfgakdjqklexa/Build/Products/Debug/Tatami.app"
DEST="/Applications/Tatami.app"

if [[ ! -d "$SRC" ]]; then
  echo "Build artifact not found at $SRC — run a Debug build first." >&2
  exit 1
fi

# Resolve cert identity.
if [[ -n "${TATAMI_CERT_HASH:-}" ]]; then
  CERT_SELECTOR="$TATAMI_CERT_HASH"
elif [[ -n "${TATAMI_CERT_NAME:-}" ]]; then
  CERT_SELECTOR="$TATAMI_CERT_NAME"
else
  # Pick the first Apple Development cert available locally.
  CERT_SELECTOR="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')"
  if [[ -z "$CERT_SELECTOR" ]]; then
    echo "No Apple Development cert found in the keychain." >&2
    echo "Set TATAMI_CERT_HASH or TATAMI_CERT_NAME to override." >&2
    exit 1
  fi
fi

# Quit running instance so /Applications/Tatami.app can be replaced.
osascript -e 'tell application "Tatami" to quit' 2>/dev/null || true
sleep 1

rm -rf "$DEST"
ditto "$SRC" "$DEST"

# Re-sign every embedded framework first (the app's sealed-resources
# hash includes them), then the app bundle itself.
while IFS= read -r -d '' fw; do
  /usr/bin/codesign --force --sign "$CERT_SELECTOR" --options runtime --timestamp=none "$fw" \
    >/dev/null 2>&1 || true
done < <(find "$DEST/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print0 2>/dev/null)

/usr/bin/codesign --force --sign "$CERT_SELECTOR" \
  --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$DEST"

echo "Installed at $DEST (signed with $CERT_SELECTOR)"
