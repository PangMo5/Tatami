// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Dependencies
import DependenciesMacros
import os

/// The window ids Tatami manages (tiled + floating). Written on the main
/// thread; read off-main by the focus-follows-mouse hit-test.
@DependencyClient
struct ManagedWindowsClient: Sendable {
  var setManaged: @Sendable (Set<CGWindowID>) -> Void
  var isManaged: @Sendable (CGWindowID) -> Bool = { _ in false }
}

extension ManagedWindowsClient: DependencyKey {
  static let liveValue: ManagedWindowsClient = {
    let ids = OSAllocatedUnfairLock<Set<CGWindowID>>(initialState: [])
    return ManagedWindowsClient(
      setManaged: { next in ids.withLock { $0 = next } },
      isManaged: { id in ids.withLock { $0.contains(id) } }
    )
  }()

  static let testValue = ManagedWindowsClient(setManaged: { _ in }, isManaged: { _ in false })
  static let previewValue = testValue
}

extension DependencyValues {
  var managedWindows: ManagedWindowsClient {
    get { self[ManagedWindowsClient.self] }
    set { self[ManagedWindowsClient.self] = newValue }
  }
}
