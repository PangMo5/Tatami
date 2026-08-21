// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros

@DependencyClient
struct ClipboardClient: Sendable {
  var readString: @Sendable () -> String?
  var writeString: @Sendable (_ value: String) -> Bool = { _ in false }
}

extension ClipboardClient: DependencyKey {
  static let liveValue = ClipboardClient(
    readString: {
      NSPasteboard.general.string(forType: .string)
    },
    writeString: { value in
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      return pasteboard.setString(value, forType: .string)
    },
  )

  static let testValue = ClipboardClient(
    readString: { nil },
    writeString: { _ in false },
  )
}

extension DependencyValues {
  var clipboard: ClipboardClient {
    get { self[ClipboardClient.self] }
    set { self[ClipboardClient.self] = newValue }
  }
}
