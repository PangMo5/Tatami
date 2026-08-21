// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Decode-only shape for the old `floatingApps` config key. It deliberately
/// has no domain behavior or public API; the value exists only long enough for
/// `AppConfig` to map it into `SharedApp` during migration.
struct LegacyFloatingApp: Decodable {
  var bundleIdentifier: String
  var name: String
  var iconPath: String?
}
