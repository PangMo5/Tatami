// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import os

// MARK: - OverlayAwareProcess

struct OverlayAwareProcess: Hashable, Sendable {
  var bundleId: String
  var pid: pid_t
}

// MARK: - OverlayEvaluationToken

struct OverlayEvaluationToken: Hashable, Sendable {
  fileprivate var rawValue: UInt64
}

// MARK: - OverlayWindowSurface

/// WindowServer evidence joined with an app's top-level AX window list.
/// `CGWindowList` alone is deliberately insufficient: Electron helper/menu
/// surfaces also use elevated layers but must not keep a whole app visible.
struct OverlayWindowSurface: Equatable, Sendable {
  var windowID: CGWindowID
  var ownerPID: pid_t
  var layer: Int
  var alpha: Double
  var frame: CGRect
}

func hasVisibleElevatedOverlay(
  topLevelWindowIDs: Set<CGWindowID>,
  ownerPID: pid_t,
  surfaces: [OverlayWindowSurface],
) -> Bool {
  surfaces.contains { surface in
    surface.ownerPID == ownerPID
      && topLevelWindowIDs.contains(surface.windowID)
      && surface.layer != 0
      && surface.alpha > 0
      && surface.frame.width > 1
      && surface.frame.height > 1
  }
}

// MARK: - OverlayAwarenessClient

/// Runtime contract for apps that recreate themselves when an elevated,
/// persistent overlay is alive (for example a meeting recorder pill).
///
/// Registration only permits the behavior. A process is actually preserved
/// after fresh AX top-level-window evidence intersects an on-screen nonzero
/// WindowServer layer. Preserved processes are mirrored here so FFM and the
/// activation reducer can exclude their ordinary background windows.
@DependencyClient
struct OverlayAwarenessClient: Sendable {
  var configure: @Sendable ([String]) -> Void
  var beginEvaluation: @Sendable ([OverlayAwareProcess]) -> OverlayEvaluationToken = { _ in
    OverlayEvaluationToken(rawValue: 0)
  }

  var commitEvaluation: @Sendable (
    _ token: OverlayEvaluationToken,
    _ preserving: Set<OverlayAwareProcess>,
  ) -> Set<OverlayAwareProcess> = { _, _ in [] }
  var promoteBackgrounded: @Sendable (
    _ token: OverlayEvaluationToken,
    _ process: OverlayAwareProcess,
  ) -> Bool = { _, _ in false }
  var endEvaluation: @Sendable (OverlayEvaluationToken) -> Void
  var processesToKeepVisible: @Sendable (
    _ token: OverlayEvaluationToken,
    _ processes: [OverlayAwareProcess],
  ) async -> Set<OverlayAwareProcess> = { _, _ in [] }
  var setBackgrounded: @Sendable (_ process: OverlayAwareProcess, _ isBackgrounded: Bool) -> Void
  var clearBackgroundedProcess: @Sendable (_ pid: pid_t) -> Void
  var clearBackgroundedBundle: @Sendable (_ bundleId: String) -> Void
  var isBackgroundedBundle: @Sendable (_ bundleId: String) -> Bool = { _ in false }
  var isBackgroundedProcess: @Sendable (_ pid: pid_t) -> Bool = { _ in false }
}

// MARK: DependencyKey

extension OverlayAwarenessClient: DependencyKey {
  static let liveValue: OverlayAwarenessClient = {
    let state = OverlayAwarenessState()
    return OverlayAwarenessClient(
      configure: { state.configure($0) },
      beginEvaluation: { state.beginEvaluation($0) },
      commitEvaluation: { state.commitEvaluation($0, preserving: $1) },
      promoteBackgrounded: { state.promoteBackgrounded($1, from: $0) },
      endEvaluation: { state.endEvaluation($0) },
      processesToKeepVisible: { await state.processesToKeepVisible($1, from: $0) },
      setBackgrounded: { state.setBackgrounded($0, $1) },
      clearBackgroundedProcess: { state.clearBackgrounded(pid: $0) },
      clearBackgroundedBundle: { state.clearBackgrounded(bundleId: $0) },
      isBackgroundedBundle: { state.isBackgrounded(bundleId: $0) },
      isBackgroundedProcess: { state.isBackgrounded(pid: $0) },
    )
  }()

  static let testValue = OverlayAwarenessClient(
    configure: { _ in },
    beginEvaluation: { _ in OverlayEvaluationToken(rawValue: 0) },
    commitEvaluation: { _, preserving in preserving },
    promoteBackgrounded: { _, _ in false },
    endEvaluation: { _ in },
    processesToKeepVisible: { _, _ in [] },
    setBackgrounded: { _, _ in },
    clearBackgroundedProcess: { _ in },
    clearBackgroundedBundle: { _ in },
    isBackgroundedBundle: { _ in false },
    isBackgroundedProcess: { _ in false },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var overlayAwareness: OverlayAwarenessClient {
    get { self[OverlayAwarenessClient.self] }
    set { self[OverlayAwarenessClient.self] = newValue }
  }
}

// MARK: - OverlayAwarenessState

final class OverlayAwarenessState: @unchecked Sendable {

  // MARK: Internal

  func configure(_ bundleIds: [String]) {
    let configured = Set(bundleIds.lazy.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })
    lock.withLock { state in
      state.configuredBundleIds = configured
      // Removing an allowlist entry cannot immediately drop suppression: the
      // layer-zero app window is still visible until the next manager hide
      // pass. That authoritative pass hides first and only then clears the
      // exact process, so FFM never gets a live gap onto the stray window.
      state.lastOverlayEvidence = state.lastOverlayEvidence.filter {
        configured.contains($0.key.bundleId)
      }
    }
  }

  func processesToKeepVisible(
    _ processes: [OverlayAwareProcess],
    from token: OverlayEvaluationToken,
  ) async -> Set<OverlayAwareProcess> {
    let cancellation = OverlayScanCancellationFlag()
    return await withTaskCancellationHandler {
      let (configured, provisional) = lock.withLock {
        ($0.configuredBundleIds, $0.provisionalBackgrounded[token] ?? [])
      }
      let candidates = Array(Set(processes)).filter {
        configured.contains($0.bundleId) && provisional.contains($0)
      }
      guard !candidates.isEmpty, !cancellation.isCancelled else { return [] }

      async let surfacesResult = currentOnScreenSurfaces(cancellation: cancellation)
      let topLevelIDs = await withTaskGroup(
        of: (OverlayAwareProcess, Set<CGWindowID>?).self,
        returning: [OverlayAwareProcess: Set<CGWindowID>].self,
      ) { group in
        for process in candidates {
          group.addTask {
            guard !cancellation.isCancelled else { return (process, nil) }
            let ids = await self.topLevelAXWindowIDs(
              pid: process.pid,
              cancellation: cancellation,
            )
            return (process, cancellation.isCancelled ? nil : ids)
          }
        }
        var result = [OverlayAwareProcess: Set<CGWindowID>]()
        for await (process, ids) in group {
          if let ids { result[process] = ids }
        }
        return result
      }
      let surfaces = await surfacesResult
      guard !cancellation.isCancelled else { return [] }
      var preserved = Set<OverlayAwareProcess>()
      for process in candidates {
        guard !cancellation.isCancelled else { return [] }
        let authoritative: Bool? =
          if let surfaces, let ids = topLevelIDs[process] {
            hasVisibleElevatedOverlay(
              topLevelWindowIDs: ids,
              ownerPID: process.pid,
              surfaces: surfaces,
            )
          } else {
            nil
          }
        let keepsVisible: Bool = lock.withLock { state in
          guard !cancellation.isCancelled else { return false }
          guard
            state.configuredBundleIds.contains(process.bundleId),
            state.provisionalBackgrounded[token]?.contains(process) == true
          else {
            return false
          }
          if let authoritative {
            state.lastOverlayEvidence[process] = authoritative
            return authoritative
          }
          // A transient AX/WindowServer read failure is not evidence that a
          // previously-proved overlay vanished. Retain only prior affirmative
          // evidence; a never-proved process still follows normal hide rules.
          return state.lastOverlayEvidence[process] == true
        }
        guard !cancellation.isCancelled else { return [] }
        if keepsVisible { preserved.insert(process) }

        if authoritative == nil {
          debugLog.log(
            "OverlayAware",
            "evidence unavailable \(process.bundleId) pid=\(process.pid); "
              + "retainPrior=\(keepsVisible)",
          )
        } else if debugLog.isEnabled() {
          let elevated = (surfaces ?? []).filter {
            $0.ownerPID == process.pid && $0.layer != 0
          }.map { "\($0.windowID):layer=\($0.layer)" }
          debugLog.log(
            "OverlayAware",
            "evaluate \(process.bundleId) pid=\(process.pid) preserve=\(keepsVisible) "
              + "topLevel=\(topLevelIDs[process]?.sorted() ?? []) "
              + "elevated=\(elevated)",
          )
        }
      }
      return preserved
    } onCancel: {
      cancellation.cancel()
    }
  }

  func setBackgrounded(_ process: OverlayAwareProcess, _ isBackgrounded: Bool) {
    lock.withLock { state in
      if isBackgrounded {
        state.backgrounded.insert(process)
      } else {
        state.backgrounded.remove(process)
      }
    }
  }

  func beginEvaluation(
    _ processes: [OverlayAwareProcess]
  ) -> OverlayEvaluationToken {
    let (token, hasProvisionalProcesses) = lock.withLock { state in
      state.nextEvaluationToken &+= 1
      let token = OverlayEvaluationToken(rawValue: state.nextEvaluationToken)
      let configured = Set(processes.filter {
        state.configuredBundleIds.contains($0.bundleId)
      })
      if !configured.isEmpty {
        state.provisionalBackgrounded[token] = configured
      }
      return (token, !configured.isEmpty)
    }
    if hasProvisionalProcesses {
      invalidatePendingWindowFocus()
    }
    return token
  }

  func endEvaluation(_ token: OverlayEvaluationToken) {
    lock.withLock { state in
      state.provisionalBackgrounded[token] = nil
    }
  }

  /// Atomically validates a scan result against both its still-live lease and
  /// the current allowlist. A target activation, termination, or settings
  /// removal can revoke a provisional process while AX is suspended; that
  /// revoked process must never be reintroduced by the older result.
  func commitEvaluation(
    _ token: OverlayEvaluationToken,
    preserving processes: Set<OverlayAwareProcess>,
  ) -> Set<OverlayAwareProcess> {
    lock.withLock { state in
      guard let provisional = state.provisionalBackgrounded[token] else {
        return []
      }
      let committed = provisional.intersection(processes).filter {
        state.configuredBundleIds.contains($0.bundleId)
      }
      state.backgrounded.formUnion(committed)
      state.provisionalBackgrounded[token] = provisional.subtracting(committed)
      return committed
    }
  }

  /// Promote a failed asynchronous hide to persistent suppression, but only
  /// while this transaction still owns the provisional process (or an older
  /// committed state is already protecting it). Exact clear operations revoke
  /// both sources under the same lock, preventing stale PID resurrection.
  func promoteBackgrounded(
    _ process: OverlayAwareProcess,
    from token: OverlayEvaluationToken,
  ) -> Bool {
    lock.withLock { state in
      let isProvisional = state.provisionalBackgrounded[token]?.contains(process) == true
      guard isProvisional || state.backgrounded.contains(process) else {
        return false
      }
      state.backgrounded.insert(process)
      return true
    }
  }

  func clearBackgrounded(bundleId: String) {
    lock.withLock { state in
      state.backgrounded = state.backgrounded.filter { $0.bundleId != bundleId }
      for token in Array(state.provisionalBackgrounded.keys) {
        guard let current = state.provisionalBackgrounded[token] else { continue }
        let remaining = current.filter { $0.bundleId != bundleId }
        if remaining.isEmpty {
          state.provisionalBackgrounded[token] = nil
        } else {
          state.provisionalBackgrounded[token] = remaining
        }
      }
    }
  }

  func clearBackgrounded(pid: pid_t) {
    lock.withLock { state in
      state.backgrounded = state.backgrounded.filter { $0.pid != pid }
      for token in Array(state.provisionalBackgrounded.keys) {
        guard let current = state.provisionalBackgrounded[token] else { continue }
        let remaining = current.filter { $0.pid != pid }
        if remaining.isEmpty {
          state.provisionalBackgrounded[token] = nil
        } else {
          state.provisionalBackgrounded[token] = remaining
        }
      }
      state.lastOverlayEvidence = state.lastOverlayEvidence.filter {
        $0.key.pid != pid
      }
    }
  }

  func isBackgrounded(bundleId: String) -> Bool {
    lock.withLock { state in
      state.backgrounded.contains { $0.bundleId == bundleId }
        || state.provisionalBackgrounded.values.contains { processes in
          processes.contains { $0.bundleId == bundleId }
        }
    }
  }

  func isBackgrounded(pid: pid_t) -> Bool {
    lock.withLock { state in
      state.backgrounded.contains { $0.pid == pid }
        || state.provisionalBackgrounded.values.contains { processes in
          processes.contains { $0.pid == pid }
        }
    }
  }

  // MARK: Private

  private struct State {
    var configuredBundleIds = Set<String>()
    var backgrounded = Set<OverlayAwareProcess>()
    var provisionalBackgrounded = [OverlayEvaluationToken: Set<OverlayAwareProcess>]()
    var lastOverlayEvidence = [OverlayAwareProcess: Bool]()
    var nextEvaluationToken: UInt64 = 0
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())
  @Dependency(\.debugLog) private var debugLog

  private static func surface(from entry: [String: Any]) -> OverlayWindowSurface? {
    guard
      let describedPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
      let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
      let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
      let x = bounds["X"],
      let y = bounds["Y"],
      let width = bounds["Width"],
      let height = bounds["Height"]
    else { return nil }
    let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    return OverlayWindowSurface(
      windowID: windowID,
      ownerPID: describedPID,
      layer: layer,
      alpha: alpha,
      frame: CGRect(x: x, y: y, width: width, height: height),
    )
  }

  private func topLevelAXWindowIDs(
    pid: pid_t,
    cancellation: OverlayScanCancellationFlag,
  ) async -> Set<CGWindowID>? {
    await withCheckedContinuation { continuation in
      overlayAXQueues.queue(for: pid).async {
        guard !cancellation.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
          app,
          kAXWindowsAttribute as CFString,
          &raw,
        )
        guard
          !cancellation.isCancelled,
          error == .success,
          let windows = raw as? [AXUIElement]
        else {
          continuation.resume(returning: nil)
          return
        }
        let ids = Set(windows.compactMap { window -> CGWindowID? in
          guard !cancellation.isCancelled else { return nil }
          var windowID: CGWindowID = 0
          guard
            _AXUIElementGetWindow(window, &windowID) == .success,
            windowID != kCGNullWindowID
          else { return nil }
          return windowID
        })
        continuation.resume(returning: cancellation.isCancelled ? nil : ids)
      }
    }
  }

  private func currentOnScreenSurfaces(
    cancellation: OverlayScanCancellationFlag
  ) async -> [OverlayWindowSurface]? {
    await withCheckedContinuation { continuation in
      overlayWindowServerQueue.async {
        guard !cancellation.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        guard
          let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID,
          ) as? [[String: Any]]
        else {
          continuation.resume(returning: nil)
          return
        }
        guard !cancellation.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: raw.compactMap(Self.surface(from:)))
      }
    }
  }

}

private let overlayAXQueues = AXPIDSerialQueueRegistry(
  label: "dev.PangMo5.Tatami.ax-overlay-awareness"
)

private let overlayWindowServerQueue = DispatchQueue(
  label: "dev.PangMo5.Tatami.window-server-overlay-awareness",
  qos: .userInitiated,
)

// MARK: - OverlayScanCancellationFlag

private final class OverlayScanCancellationFlag: @unchecked Sendable {

  // MARK: Internal

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  // MARK: Private

  private let lock = NSLock()
  private var cancelled = false

}
