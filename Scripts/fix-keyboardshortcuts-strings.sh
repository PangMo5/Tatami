#!/bin/bash
# Xcode 26+ rejects KeyboardShortcuts' .strings files due to:
#   1. UTF-8 encoding without BOM — Xcode wants UTF-16
#   2. Unescaped inner double quotes (e.g. ar.lproj line 5)
#
# This script normalizes every Localizable.strings file to UTF-16 LE with BOM,
# escaping any unescaped inner quotes via Python parsing.
#
# Run after `tuist install`. The Makefile chains this into the `install` target.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOC_DIR="$ROOT/Tuist/.build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Localization"

if [[ ! -d "$LOC_DIR" ]]; then
  echo "No KeyboardShortcuts Localization dir; skipping."
  exit 0
fi

count=0
while IFS= read -r -d '' f; do
  chmod u+w "$f"
  python3 - "$f" <<'PY'
import sys, re, codecs

path = sys.argv[1]

# Read as UTF-16 if BOM, else UTF-8.
with open(path, 'rb') as fp:
    raw = fp.read()
if raw.startswith(codecs.BOM_UTF16_LE) or raw.startswith(codecs.BOM_UTF16_BE):
    text = raw.decode('utf-16')
elif raw.startswith(codecs.BOM_UTF8):
    text = raw[3:].decode('utf-8')
else:
    text = raw.decode('utf-8')

# Strings format: "key" = "value"; — escape unescaped " inside value.
def fix_line(line: str) -> str:
    m = re.match(r'^(\s*"(?:[^"\\]|\\.)*"\s*=\s*)"(.+)"(;\s*)$', line)
    if not m:
        return line
    prefix, value, suffix = m.groups()
    # If value already has properly escaped sequences, this is conservative.
    fixed_value = re.sub(r'(?<!\\)"', r'\\"', value)
    return f'{prefix}"{fixed_value}"{suffix}'

fixed = ''.join(fix_line(ln) for ln in text.splitlines(keepends=True))

# Write as UTF-16 LE with BOM (Xcode-preferred).
with open(path, 'wb') as fp:
    fp.write(codecs.BOM_UTF16_LE)
    fp.write(fixed.encode('utf-16-le'))
PY
  count=$((count + 1))
done < <(find "$LOC_DIR" -name '*.strings' -print0)

echo "Normalized $count .strings file(s) to UTF-16 LE with quote escaping."
