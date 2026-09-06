#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${root}/.build/tools"
clang -fobjc-arc -framework Cocoa -framework CoreGraphics "${root}/Sources/demodisplay/main.m" -o "${root}/.build/tools/demodisplay"
