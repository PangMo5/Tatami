#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Host side of the Demo Lab VM workflow: clone a golden macOS image, pin its
# display, and boot it with the Demo Lab source shared in.
#
# Everything here is checked before it is used. The Tart command surface moves
# between releases, and several widely-copied invocations do not exist at all
# (`tart ssh`, `tart run --display`), so this script probes `--help` and fails
# with a clear message rather than running something that silently does nothing.
set -euo pipefail

# Whether the caller asked for specific hardware. An override that cannot be
# applied — see the "already running" branch below — has to fail loudly instead
# of being reported as pinned.
hw_override=0
for setting in DISPLAY_SIZE CPUS MEMORY_MB DISK_GB; do
  if [ -n "${!setting+x}" ]; then hw_override=1; fi
done

VM_NAME="${VM_NAME:-tatami-demo}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-sequoia-base:latest}"
DISPLAY_SIZE="${DISPLAY_SIZE:-1920x1200px}"
CPUS="${CPUS:-6}"
MEMORY_MB="${MEMORY_MB:-10240}"
DISK_GB="${DISK_GB:-120}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_root="$(cd "${here}/../.." && pwd)"

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Prints "running" or "stopped" for one VM, and nothing at all if `tart list`
# did not describe it in a shape this can read. Nothing is the caller's cue to
# refuse rather than guess: guessing "stopped" is what silently mis-pins a
# running guest. Matching the name field exactly is what `pgrep -f "tart run
# ${VM_NAME}"` could not do — that also matched `tart run ${VM_NAME}-golden`.
vm_state() {
  local listing
  # Captured rather than piped so that a failing `tart list` reaches the caller
  # as "unreadable" instead of tripping `pipefail` and killing the script.
  listing="$(tart list --format json 2>/dev/null || true)"
  printf '%s\n' "${listing}" | awk -v want="$1" '
    /\{/ { name = ""; run = "" }
    /"Name"[[:space:]]*:/ {
      if (match($0, /:[[:space:]]*"[^"]*"/)) {
        value = substr($0, RSTART, RLENGTH)
        gsub(/^:[[:space:]]*"|"$/, "", value)
        name = value
      }
    }
    /"Running"[[:space:]]*:/ { run = ($0 ~ /true/) ? "running" : "stopped" }
    /"State"[[:space:]]*:/   { if (run == "") run = ($0 ~ /"running"/) ? "running" : "stopped" }
    /\}/ { if (name == want && run != "") { print run; exit } }
  '
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

note "Preflight"

command -v tart >/dev/null || die "tart is not installed. See docs/VM-TART.md."
tart_version="$(tart --version 2>/dev/null || echo unknown)"
printf 'tart %s\n' "${tart_version}"

[ "$(uname -m)" = "arm64" ] || die "Apple silicon is required; Virtualization.framework cannot run a macOS guest on Intel."

# `tart exec` needs the guest agent and a macOS 14+ host. Probe rather than assume.
if ! tart --help 2>&1 | grep -q '^  exec'; then
  die "this tart build has no \`exec\` subcommand (added in 2.27.0). Upgrade tart."
fi

# The lab's config template and hook are read from the shared directory inside
# the guest, so a colon in the host path would be parsed as a share name.
case "${lab_root}" in
  *:*) die "the DemoLab path contains ':' which tart's --dir parser cannot express: ${lab_root}" ;;
esac

# macOS 15+ hosts need an unlocked login keychain before Virtualization.framework
# will start a VM; the failure is otherwise an opaque Security Server error.
if ! security show-keychain-info login.keychain-db >/dev/null 2>&1 \
  && ! security show-keychain-info login.keychain >/dev/null 2>&1; then
  printf '\033[33mwarning:\033[0m the login keychain looks locked. If the VM fails to start with a\n'
  printf '         Security Server error, run: security unlock-keychain\n'
fi

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

if tart list --format json 2>/dev/null | grep -q "\"Name\" *: *\"${VM_NAME}\""; then
  note "VM ${VM_NAME} already exists (delete it with \`tart delete ${VM_NAME}\` to start over)"
else
  note "Cloning ${BASE_IMAGE} -> ${VM_NAME}"
  # The `-base` images ship the Tart guest agent and are published with SIP
  # already disabled, which is what makes `tart exec` and the one-time TCC work
  # possible. A `-vanilla` image has neither.
  tart clone "${BASE_IMAGE}" "${VM_NAME}"
fi

# ---------------------------------------------------------------------------
# Hardware and boot
# ---------------------------------------------------------------------------

# `tart set` has no running-VM guard: it rewrites config.json and exits 0 while
# the VM is up, and `tart run` reads that file exactly once, at boot. Pinning a
# running VM therefore changes nothing the guest sees, and `tart get` reads the
# same file straight back and reports the pin as applied. So the boot state has
# to be decided before the hardware is touched, not after.
state="$(vm_state "${VM_NAME}")"
case "${state}" in
  running|stopped) ;;
  *)
    die "cannot tell whether ${VM_NAME} is running: \`tart list --format json\` reported no
       state for it. Refusing to touch its hardware, because pinning a running VM is
       silently ignored by the guest. Check \`tart list\`, stop the VM, and re-run."
    ;;
esac

if [ "${state}" = "running" ]; then
  note "${VM_NAME} is already running"
  if [ "${hw_override}" -eq 1 ]; then
    die "hardware values cannot be applied to a running VM: --display, --cpu and --memory are
       read once, at boot. Run \`tart stop ${VM_NAME}\`, then re-run this script."
  fi
  printf '\033[33mwarning:\033[0m skipping the hardware pin; the guest keeps what it booted with.\n'
  printf '         To re-pin it: tart stop %s, then re-run this script.\n' "${VM_NAME}"
else
  note "Pinning hardware"
  # `--no-display-refit` matters more than it looks: macOS guests default to
  # refitting the guest resolution to the host window, so without it the
  # recording resolution changes whenever the window is resized.
  tart set "${VM_NAME}" \
    --display "${DISPLAY_SIZE}" \
    --no-display-refit \
    --cpu "${CPUS}" \
    --memory "${MEMORY_MB}"
  tart set "${VM_NAME}" --disk-size "${DISK_GB}" 2>/dev/null || true
fi

tart get "${VM_NAME}" --format json 2>/dev/null || tart get "${VM_NAME}"

note "Booting ${VM_NAME}"
if [ "${state}" = "running" ]; then
  echo "already running"
else
  # Shared read-write so recordings can be written straight back to the host.
  tart run "${VM_NAME}" --dir="demolab:${lab_root}" >"/tmp/tart-${VM_NAME}.log" 2>&1 &
  echo "started (log: /tmp/tart-${VM_NAME}.log)"
fi

note "Waiting for the guest"
ip="$(tart ip "${VM_NAME}" --wait 300)" || die "the VM never got an IP address"
echo "ip: ${ip}"

# An IP only means the network came up. Tart has no boot-complete signal, so
# poll for something that proves a usable login session exists.
deadline=$(( $(date +%s) + 300 ))
until tart exec "${VM_NAME}" /usr/bin/true >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "${deadline}" ] || die "the guest agent never answered; is this a -base or -xcode image?"
  sleep 2
done
echo "guest agent responding"

note "Guest environment"
tart exec "${VM_NAME}" /usr/bin/sw_vers || true
echo -n 'SIP: '
tart exec "${VM_NAME}" /usr/bin/csrutil status || true

cat <<EOF

Next, inside the guest:

  tart exec ${VM_NAME} /bin/bash -lc \\
    '"/Volumes/My Shared Files/demolab/vm/tart/guest-provision.sh"'

Shared directory in the guest : /Volumes/My Shared Files/demolab
Screen sharing (needs the GUI): open vnc://${ip}   (user admin / password admin)

The one-time permission grants must be done in the guest's GUI. See
docs/PERMISSIONS.md — they cannot be scripted, and the whole point of the
golden snapshot is that you only do them once.
EOF
