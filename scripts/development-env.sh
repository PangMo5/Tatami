#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Sourced by mise; keep Xcode selection local to this repository.
tatami_select_xcode() {
  [[ "$(uname -s)" == Darwin ]] || return 0

  local repository_root required_version selected_directory candidate version
  repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  required_version="$(cat "$repository_root/.xcode-version")"
  selected_directory="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"

  for candidate in "$selected_directory" /Applications/Xcode*.app/Contents/Developer; do
    [[ -d "$candidate" ]] || continue
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/../Info.plist" 2>/dev/null)" || continue
    if [[ "$version" == "$required_version" || "$version" == "$required_version.0" ]]; then
      export DEVELOPER_DIR="$candidate"
      return 0
    fi
  done

  printf 'Tatami requires Xcode %s. Install it in /Applications or set DEVELOPER_DIR to its developer directory.\n' "$required_version" >&2
  return 1
}

tatami_select_xcode
tatami_xcode_status=$?
unset -f tatami_select_xcode
return "$tatami_xcode_status"
