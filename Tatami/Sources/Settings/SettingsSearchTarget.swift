// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

extension EnvironmentValues {
  @Entry var highlightedSettingsItem: String?
}

extension View {
  func settingsSearchTarget(_ id: String) -> some View {
    modifier(SettingsSearchTarget(id: id))
  }
}

// MARK: - SettingsSearchTarget

private struct SettingsSearchTarget: ViewModifier {

  // MARK: Internal

  let id: String

  func body(content: Content) -> some View {
    let target = content
      .id(id)
      .overlay {
        if highlighted == id {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.tint, lineWidth: 2)
            .allowsHitTesting(false)
        }
      }
    // Section identifiers propagate to every descendant control in a macOS
    // Form, replacing the controls' own identities. Only rows expose an AX id.
    if id.hasPrefix("section.") {
      target
    } else {
      target.accessibilityIdentifier("setting-\(id)")
    }
  }

  // MARK: Private

  @Environment(\.highlightedSettingsItem) private var highlighted

}
