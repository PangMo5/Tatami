// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation

/// Screen Recording (TCC) permission: status, prompting, and the System
/// Settings deep link. Tatami needs it only for floating windows — their
/// always-on-top mirrors are ScreenCaptureKit captures.
///
/// Like Accessibility, a *new* grant doesn't reach the running process:
/// `SCStream` keeps failing until relaunch (revokes apply live). The
/// Settings UI pairs the grant button with the existing relaunch row.
@DependencyClient
struct ScreenRecordingClient: Sendable {
  /// Current grant state (non-prompting).
  var isGranted: @Sendable () -> Bool = { false }
  /// Show the system prompt (no-op if macOS already considers it decided —
  /// then the System Settings page is the only way, hence `openSettings`).
  var requestAccess: @Sendable () async -> Void
  /// Open System Settings → Privacy & Security → Screen Recording.
  var openSettings: @Sendable () async -> Void
}

extension ScreenRecordingClient: DependencyKey {
  static let liveValue = ScreenRecordingClient(
    isGranted: { CGPreflightScreenCaptureAccess() },
    requestAccess: {
      await MainActor.run { _ = CGRequestScreenCaptureAccess() }
    },
    openSettings: {
      await MainActor.run {
        guard let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
      }
    }
  )

  static let testValue = ScreenRecordingClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var screenRecording: ScreenRecordingClient {
    get { self[ScreenRecordingClient.self] }
    set { self[ScreenRecordingClient.self] = newValue }
  }
}
