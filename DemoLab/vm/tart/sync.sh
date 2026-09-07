#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# Push the working tree into a running guest, for the edit-and-retry loop.
#
# Why an archive with a fresh name instead of rsync straight off the share:
# virtiofs was measured serving STALE CONTENT for a file rewritten in place on
# the host. The guest saw the new mtime and the old bytes, so `rsync` decided
# there was nothing to copy and the guest quietly kept building yesterday's
# source. A uniquely named archive cannot be served from that cache, and the
# guest extracts from it rather than diffing against it.
#
# Provisioning does not hit this, because it copies files the guest has never
# seen. Only the second and later syncs of the same path do.
set -euo pipefail

VM_NAME="${VM_NAME:-tatami-demo}"
GUEST_DIR="${GUEST_DIR:-DemoLab}"
SHARE="${SHARE:-/Volumes/My Shared Files/demolab}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_root="$(cd "${here}/../.." && pwd)"

command -v tart >/dev/null || { echo "error: tart is not installed" >&2; exit 1; }
tart exec "${VM_NAME}" /usr/bin/true >/dev/null 2>&1 \
  || { echo "error: ${VM_NAME} is not running, or its guest agent is not up" >&2; exit 1; }

python3 "${lab_root}/scripts/video_theme.py"
stamp="$(date +%s)-$$"
archive=".sync/lab-${stamp}.tgz"
mkdir -p "${lab_root}/.sync"
# `.build` and `recordings` stay on the guest: one is huge and machine-specific,
# the other is the artifact we came for.
tar czf "${lab_root}/${archive}" -C "${lab_root}" \
  Package.swift publication.json Sources Tests Localization config scenes scripts bin vm docs README.md
trap 'rm -f "${lab_root}/${archive}"' EXIT

echo "pushing $(du -h "${lab_root}/${archive}" | cut -f1) to ${VM_NAME}:~/${GUEST_DIR}"
tart exec "${VM_NAME}" /usr/bin/env "LAB_GUEST_DIR=${GUEST_DIR}" "LAB_ARCHIVE=${SHARE}/${archive}" \
  /bin/bash -lc '
    set -euo pipefail
    target="${HOME}/${LAB_GUEST_DIR}"
    stage="$(mktemp -d)"
    cleanup() {
      rm -rf "${stage}"
    }
    trap cleanup EXIT
    tar xzf "${LAB_ARCHIVE}" -C "${stage}"
    mkdir -p "${target}"
    # Mirror only managed source paths. Runtime data and recordings stay intact.
    # Archive extraction alone leaves deleted Swift files active in the guest.
    for entry in Package.swift publication.json Sources Tests Localization config scenes scripts bin vm docs README.md; do
      if [ -d "${stage}/${entry}" ]; then
        mkdir -p "${target}/${entry}"
        rsync -a --delete "${stage}/${entry}/" "${target}/${entry}/"
      else
        cp "${stage}/${entry}" "${target}/${entry}"
      fi
    done
  '


if [ "${BUILD:-1}" = "1" ]; then
  echo "building in the guest"
  tart exec "${VM_NAME}" /bin/bash -lc \
    "set -euo pipefail; cd ~/${GUEST_DIR} && swift build -c release 2>&1 | tail -2 && ./scripts/bundle-apps.sh >/dev/null && echo 'bundles rebuilt'"
fi

echo "done. Next: tart exec ${VM_NAME} /bin/bash -lc 'cd ~/${GUEST_DIR} && ./bin/democtl reset && ./bin/democtl seed'"
