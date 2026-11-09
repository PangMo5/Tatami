// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TatamiCLIProtocol

/// TatamiKit umbrella — re-exports the feature surface so the App target imports
/// only TatamiKit.
public enum TatamiKit {
  public static let version = TatamiVersion.current
}
