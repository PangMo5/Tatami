#!/bin/sh
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
cli="${TATAMI_CLI:-tatami}"
"$cli" workspace activate Design
"$cli" layout balance
"$cli" workspace borrow from Notes
printf '\nFocus-session commands submitted.\n'
