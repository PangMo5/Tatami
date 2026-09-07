#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
# Fetch an explicit batch through a new archive. Reusing filenames on virtiofs
# can target a cached inode after the host moved a previous take away.
set -euo pipefail
VM_NAME="${VM_NAME:-tatami-demo}"
GUEST_DIR="${GUEST_DIR:-DemoLab/recordings}"
GUEST_SHARE="${GUEST_SHARE:-/Volumes/My Shared Files/demolab}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lab_root="$(cd "${here}/../.." && pwd)"
dest="${1:?usage: fetch-recordings.sh NEW_DESTINATION}"
command -v tart >/dev/null || { echo 'error: tart is required' >&2; exit 1; }
[ ! -e "${dest}" ] || { echo "error: destination exists: ${dest}" >&2; exit 1; }
stamp="$(date +%s)-$$"
relative=".sync/fetch-${stamp}.tar"
marker=".sync/fetch-${stamp}.marker"
mkdir -p "${lab_root}/.sync"
printf '%s' "${stamp}" > "${lab_root}/${marker}"
trap 'rm -f "${lab_root}/${relative}" "${lab_root}/${marker}"' EXIT
remote_sha="$(tart exec "${VM_NAME}" /usr/bin/env \
  "LAB_BATCH=${GUEST_DIR}" "LAB_SHARE=${GUEST_SHARE}" "LAB_ARCHIVE=${relative}" \
  "LAB_MARKER=${marker}" "LAB_STAMP=${stamp}" /bin/bash -lc '
  set -euo pipefail
  [ "$(cat "${LAB_SHARE}/${LAB_MARKER}")" = "${LAB_STAMP}" ] || exit 5
  cd "${HOME}/${LAB_BATCH}"
  shopt -s nullglob
  movies=(*.mov)
  [ "${#movies[@]}" -gt 0 ] || { echo "no movies in ${LAB_BATCH}" >&2; exit 6; }
  files=("${movies[@]}" *.ass *.timeline.json *.take.json *.scene.json *.secondary.json)
  [ ! -f capture-report.json ] || files+=(capture-report.json)
  tar cf "${LAB_SHARE}/${LAB_ARCHIVE}" -- "${files[@]}"
  shasum -a 256 "${LAB_SHARE}/${LAB_ARCHIVE}" | cut -d " " -f 1
')"
local_sha="$(shasum -a 256 "${lab_root}/${relative}" | cut -d ' ' -f 1)"
[ "${local_sha}" = "${remote_sha}" ] || { echo 'error: guest/host archive hashes differ' >&2; exit 1; }
mkdir -p "${dest}"
tar xf "${lab_root}/${relative}" -C "${dest}"
printf 'Fetched %s into %s (archive SHA256 %s)\n' "${GUEST_DIR}" "${dest}" "${local_sha}"
