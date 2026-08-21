// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Accessibility (AX) permission: status, prompting, and applying a new grant.
///
/// macOS does not apply a *new* grant to the already-running process —
/// `AXIsProcessTrusted()` stays stale until relaunch (revokes do apply live).
/// So a fresh grant is applied by relaunching, the same way yabai/AeroSpace
/// require. There is no reliable in-process "grant detected" signal, hence no
/// polling.
@DependencyClient
struct AccessibilityClient: Sendable {
  /// Current trust state (non-prompting). Reflects revokes immediately.
  var isTrusted: @Sendable () -> Bool = { false }
  /// Prompt for Accessibility access (shows the system dialog if untrusted).
  var requestAccess: @Sendable () async -> Void
  /// Open System Settings → Privacy & Security → Accessibility.
  var openSettings: @Sendable () async -> Void
  /// Relaunch the app so a freshly-granted permission takes effect.
  var relaunch: @Sendable () async -> Void
  /// Ticks whenever the trust DB changes or the app re-activates — a cue to
  /// re-read `isTrusted()`. (The broadcast is global, so callers just re-read;
  /// it carries no per-app payload.)
  var changes: @Sendable () -> AsyncStream<Void> = { .finished }
}

/// Holds notification observers so they can be torn down from the stream's
/// `@Sendable` termination handler. The tokens/centers aren't `Sendable`, but
/// they're only ever touched on the notification machinery, so the box is a
/// documented `@unchecked Sendable`.
private final class ObserverTokens: @unchecked Sendable {
  let distributed = DistributedNotificationCenter.default()
  let local = NotificationCenter.default
  var tokens: [any NSObjectProtocol] = []
  func removeAll() {
    for token in tokens { distributed.removeObserver(token); local.removeObserver(token) }
    tokens = []
  }
}

extension AccessibilityClient: DependencyKey {
  static let liveValue = AccessibilityClient(
    isTrusted: { AXIsProcessTrusted() },
    requestAccess: {
      await MainActor.run { _ = ensureAccessibilityTrust() }
    },
    openSettings: {
      await MainActor.run {
        guard let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
      }
    },
    relaunch: {
      await MainActor.run {
        // `open -n` runs independently, so it survives this process exiting.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        do {
          try task.run()
        } catch {
          // Don't terminate if the relauncher never started — that would
          // turn "relaunch" into a plain quit with no explanation.
          logger.error("relaunch failed to spawn open: \(error.localizedDescription, privacy: .public)")
          return
        }
        NSApp.terminate(nil)
      }
    },
    changes: {
      AsyncStream { continuation in
        let observers = ObserverTokens()
        observers.tokens = [
          observers.distributed.addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil, queue: nil
          ) { _ in continuation.yield() },
          observers.local.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: nil
          ) { _ in continuation.yield() },
        ]
        continuation.onTermination = { _ in observers.removeAll() }
      }
    }
  )

  static let testValue = AccessibilityClient(
    isTrusted: { true },
    requestAccess: {},
    openSettings: {},
    relaunch: {},
    changes: { .finished }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var accessibility: AccessibilityClient {
    get { self[AccessibilityClient.self] }
    set { self[AccessibilityClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "Accessibility")
