// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

// MARK: - ScreenRecordingClient

/// Screen Recording (TCC) permission: status, prompting, and the System
/// Settings deep link. Tatami needs it only for floating windows — their
/// always-on-top mirrors are ScreenCaptureKit captures.
///
/// Preflight reads and ScreenCaptureKit permission failures share one session
/// state. A known denial stays closed until relaunch after granting access.
@DependencyClient
struct ScreenRecordingClient: Sendable {
  /// Current grant state (non-prompting).
  var isGranted: @Sendable () -> Bool = { false }
  /// Show the system prompt (no-op if macOS already considers it decided —
  /// then the System Settings page is the only way, hence `openSettings`).
  var requestAccess: @Sendable () async -> Void
  /// Open System Settings → Privacy & Security → Screen Recording.
  var openSettings: @Sendable () async -> Void
  /// Initial state, capture permission denial, or app reactivation.
  var changes: @Sendable () -> AsyncStream<Void> = { .finished }
}

// MARK: DependencyKey

extension ScreenRecordingClient: DependencyKey {
  static let liveValue = live(access: .shared, notificationCenter: .default)

  static let testValue = ScreenRecordingClient(
    isGranted: { false },
    requestAccess: { },
    openSettings: { },
    changes: { .finished },
  )
  static let previewValue = testValue

  static func live(access: ScreenRecordingAccess, notificationCenter: NotificationCenter) -> Self {
    ScreenRecordingClient(
      isGranted: { access.isGranted() },
      requestAccess: {
        await MainActor.run { _ = CGRequestScreenCaptureAccess() }
      },
      openSettings: {
        await MainActor.run {
          guard
            let url = URL(
              string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
          else { return }
          NSWorkspace.shared.open(url)
        }
      },
      changes: {
        AsyncStream { continuation in
          let observers = PermissionObserverTokens(local: notificationCenter)
          observers.tokens = [
            observers.local.addObserver(
              forName: ScreenRecordingAccess.didCloseNotification,
              object: nil,
              queue: nil,
            ) { _ in continuation.yield() },
            observers.local.addObserver(
              forName: NSApplication.didBecomeActiveNotification,
              object: nil,
              queue: nil,
            ) { _ in continuation.yield() },
          ]
          continuation.onTermination = { _ in observers.removeAll() }
          continuation.yield()
        }
      },
    )
  }
}

extension DependencyValues {
  var screenRecording: ScreenRecordingClient {
    get { self[ScreenRecordingClient.self] }
    set { self[ScreenRecordingClient.self] = newValue }
  }
}
