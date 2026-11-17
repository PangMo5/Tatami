// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - ManagedDesktopPreparation

struct ManagedDesktopPreparation: Equatable, Sendable {
  var id: UUID
  var display: DisplayName
  var home: UInt64
  var bundleIDs: Set<String>
  var requestedAtUptime: TimeInterval
}

// MARK: - ManagedDesktopPreparationResult

enum ManagedDesktopPreparationResult: Sendable {
  case prepared(DesktopSpaces)
  case failed(String)
  case cancelled
}

// MARK: - ManagedDesktopClient

/// Explicit workspace commands prepare their native Desktop before the
/// ordinary activation pipeline is allowed to show, hide, focus, or tile apps.
@DependencyClient
struct ManagedDesktopClient: Sendable {
  var prepare: @Sendable (ManagedDesktopPreparation) async -> ManagedDesktopPreparationResult = { _ in .cancelled }
}

// MARK: DependencyKey

extension ManagedDesktopClient: DependencyKey {
  static let liveValue = ManagedDesktopClient(prepare: { request in
    await ManagedDesktopNavigator.shared.prepare(request)
  })

  static let testValue = ManagedDesktopClient(prepare: { _ in
    .failed("The target monitor is not on its managed macOS Desktop, or its Space state is unavailable")
  })

  static let previewValue = testValue
}

extension DependencyValues {
  var managedDesktop: ManagedDesktopClient {
    get { self[ManagedDesktopClient.self] }
    set { self[ManagedDesktopClient.self] = newValue }
  }
}
