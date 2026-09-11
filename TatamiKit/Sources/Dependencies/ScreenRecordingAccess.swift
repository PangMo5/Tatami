// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

/// Shares known Screen Recording denial between capture and permission UI.
/// Screen capture has its own lifetime; closing it does not revoke AX input.
/// No permission request or capture is created just to check access.
final class ScreenRecordingAccess: @unchecked Sendable {

  // MARK: Lifecycle

  init(
    preflight: @escaping @Sendable () -> Bool,
    notificationCenter: NotificationCenter = .default,
  ) {
    self.preflight = preflight
    self.notificationCenter = notificationCenter
  }

  // MARK: Internal

  static let shared = ScreenRecordingAccess(preflight: { CGPreflightScreenCaptureAccess() })
  static let didCloseNotification = Notification.Name("dev.PangMo5.Tatami.screenRecordingAccessDidClose")

  var isClosed: Bool {
    lock.withLock { closed }
  }

  func isGranted() -> Bool {
    guard !isClosed else { return false }
    // Do not hold the UI-readable lock over a system permission query.
    if !preflight() { close() }
    return !isClosed
  }

  /// Capture startup/resume checks execute away from MainActor and revalidate
  /// their own request ownership after awaiting this result.
  func prepare() async -> Bool {
    await worker.run { self.isGranted() }
  }

  func captureFailed(_ error: any Error) {
    let error = error as NSError
    if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue {
      close()
    } else {
      // userStopped and operational failures are not permission denials.
      // A fresh preflight can still identify a concurrent actual revocation.
      Task { _ = await prepare() }
    }
  }

  // MARK: Private

  private let preflight: @Sendable () -> Bool
  private let notificationCenter: NotificationCenter
  private let worker = BlockingWorkQueue(label: "dev.PangMo5.Tatami.screen-recording-access", qos: .utility)
  private let lock = NSLock()
  private var closed = false

  private func close() {
    let changed = lock.withLock {
      guard !closed else { return false }
      closed = true
      return true
    }
    guard changed else { return }
    Logger(subsystem: "dev.PangMo5.Tatami", category: "ScreenRecording")
      .notice("Screen Recording access lost; stopping floating captures")
    notificationCenter.post(name: Self.didCloseNotification, object: nil)
  }

}
