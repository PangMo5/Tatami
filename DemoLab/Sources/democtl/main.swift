// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoCtlKit
import Foundation

// democtl runs entirely on the main actor: it drives AppKit (NSRunningApplication,
// NSScreen) and CoreGraphics, and every operation is a deliberate sequence.
exit(MainActor.assumeIsolated { DemoCtl.main() })
