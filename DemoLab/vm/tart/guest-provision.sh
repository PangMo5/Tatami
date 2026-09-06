#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Guest side: copy the Demo Lab out of the shared directory, build it, install
# Tatami, and make the desktop deterministic.
#
# Run it inside the VM, either over `tart exec` or in a terminal on the guest's
# own screen. It is idempotent: running it twice is a no-op plus a rebuild.
set -euo pipefail

SHARE="${SHARE:-/Volumes/My Shared Files/demolab}"
WORK="${WORK:-$HOME/DemoLab}"
TATAMI_DMG="${TATAMI_DMG:-}"
# An already-built Tatami.app to copy in. Simpler than a .dmg when you want the
# exact build you already have: share the host's /Applications/Tatami.app into
# the guest and point at it.
TATAMI_APP="${TATAMI_APP:-}"

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

note "Preflight"
sw_vers

[ -d "${SHARE}" ] || die "shared directory not found at ${SHARE}. Start the VM with --dir=\"demolab:<path>\"."

if ! xcode-select -p >/dev/null 2>&1; then
  die "no developer tools. Run 'xcode-select --install' on the guest's own screen (it needs a GUI) and re-run this."
fi
swift --version | head -1

# Screen Recording cannot be granted from a script under SIP, and the TCC
# database is only writable with SIP off. Report the state rather than guessing.
sip_state="$(csrutil status 2>/dev/null || echo 'unknown')"
echo "SIP: ${sip_state}"

# ---------------------------------------------------------------------------
# Copy, then build from the copy
# ---------------------------------------------------------------------------

note "Copying the Demo Lab out of the share"
# Build from a local copy, never in place on the virtiofs mount: SwiftPM's build
# directory is write-heavy and a shared mount makes it both slow and a way for a
# guest build to clobber the host tree.
mkdir -p "${WORK}"
rsync -a --delete \
  --exclude '.build/' --exclude 'recordings/' \
  "${SHARE}/" "${WORK}/"
cd "${WORK}"

note "Building"
swift build -c release
./scripts/bundle-apps.sh

# ---------------------------------------------------------------------------
# Tatami
# ---------------------------------------------------------------------------

note "Tatami"
if [ -d /Applications/Tatami.app ]; then
  echo "already installed: $(defaults read /Applications/Tatami.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo '?')"
elif [ -n "${TATAMI_APP}" ]; then
  [ -d "${TATAMI_APP}" ] || die "TATAMI_APP points at something that is not an app bundle: ${TATAMI_APP}"
  echo "copying ${TATAMI_APP}"
  # `ditto`, not `cp -R`: an app bundle contains framework symlinks
  # (Sparkle.framework/Versions/Current and friends), and `cp -R` fails to copy
  # extended attributes across them on a virtiofs share — non-fatally for the
  # signature, but with a non-zero exit that `set -e` turns into an abort.
  ditto "${TATAMI_APP}" /Applications/Tatami.app
elif [ -n "${TATAMI_DMG}" ]; then
  [ -f "${TATAMI_DMG}" ] || die "TATAMI_DMG points at a file that does not exist: ${TATAMI_DMG}"
  echo "installing from ${TATAMI_DMG}"
  mount_point="$(mktemp -d)"
  hdiutil attach "${TATAMI_DMG}" -nobrowse -quiet -mountpoint "${mount_point}"
  ditto "${mount_point}/Tatami.app" /Applications/Tatami.app
  hdiutil detach "${mount_point}" -quiet
  rmdir "${mount_point}" 2>/dev/null || true
else
  cat >&2 <<'EOF'
error: Tatami is not installed, and neither TATAMI_APP nor TATAMI_DMG was given.

The Demo Lab drives the real Tatami; it never simulates it. Share a Tatami build
into the guest and point at it:

  TATAMI_APP="/Volumes/My Shared Files/tatami/Tatami.app" ./vm/tart/guest-provision.sh
  TATAMI_DMG="/Volumes/My Shared Files/demolab/Tatami.dmg" ./vm/tart/guest-provision.sh

Downloading it inside the VM is deliberately not attempted: the lab is required
to work with no network.
EOF
  exit 1
fi

note "Making the desktop deterministic"
"${WORK}/vm/tart/desktop-defaults.sh"

note "Checking the lab"
# `doctor` exits non-zero on a blocking problem. Before the one-time GUI grants
# some rows are expected to fail, so report rather than abort.
./bin/democtl doctor || true

cat <<EOF

Build and install done.

Still manual, once per golden image (see docs/PERMISSIONS.md):

  1. Accessibility for Tatami.app       — without it Tatami accepts every
                                           command and moves nothing.
  2. Screen Recording for DemoRecorder.app — grant it, then relaunch: a new grant
                                           never reaches the running process.
  3. Screen Recording for Tatami.app    — only if you keep Pulse as Always on Top
                                           (\`democtl seed --pulse unmanaged\` avoids it).

  4. Let macOS finish its own first-run notifications. A fresh Tahoe guest posts a
     "See what's new" banner that will otherwise land in the middle of a take.
     Wait for it, dismiss it, and only then snapshot.

Then snapshot the VM. Every later take starts from that snapshot, which is what
keeps the takes identical and stops macOS re-asking for screen capture.

First take:

  cd ${WORK}
  ./bin/democtl reset
  ./bin/democtl seed
  ./bin/democtl take hero
EOF
