#!/bin/bash
# Build Tatami in Debug, re-sign with the local Apple Development cert
# so the binary hash stays stable across rebuilds (otherwise macOS
# re-prompts for every TCC permission), and install into /Applications.
#
# The Tuist-generated project keeps falling back to ad-hoc signing for
# the app target because of how its build settings interact with
# Swift macros. The re-sign step after build is the most reliable
# workaround until that is untangled at the project level.

set -euo pipefail

CERT_HASH="${TATAMI_CERT_HASH:-<DEV_CERT_HASH>}"   # Apple Development: <redacted-name> (<APPLE_DEV_USER_ID>)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS="$ROOT/Tatami/Tatami.entitlements"
SRC="$HOME/Library/Developer/Xcode/DerivedData/Tatami-abzoohblcyzqwbfbfgakdjqklexa/Build/Products/Debug/Tatami.app"
DEST="/Applications/Tatami.app"

if [[ ! -d "$SRC" ]]; then
  echo "Build artifact not found at $SRC — run a Debug build first." >&2
  exit 1
fi

# Quit running instance so /Applications/Tatami.app can be replaced.
osascript -e 'tell application "Tatami" to quit' 2>/dev/null || true
sleep 1

rm -rf "$DEST"
ditto "$SRC" "$DEST"

# Re-sign every embedded framework first (the app's sealed-resources
# hash includes them), then the app bundle itself.
while IFS= read -r -d '' fw; do
  /usr/bin/codesign --force --sign "$CERT_HASH" --options runtime --timestamp=none "$fw" \
    >/dev/null 2>&1 || true
done < <(find "$DEST/Contents/Frameworks" -name '*.framework' -maxdepth 1 -print0 2>/dev/null)

/usr/bin/codesign --force --sign "$CERT_HASH" \
  --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  "$DEST"

echo "Re-signed and installed at $DEST"
/usr/bin/codesign -d -vv "$DEST" 2>&1 | grep -E 'Signature|TeamIdentifier|Authority' | head -5
