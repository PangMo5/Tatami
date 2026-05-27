import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Directional focus operations. Looks at every visible window on the
/// active display via Accessibility and picks the next focusable window
/// in the requested direction.
@DependencyClient
public struct FocusManagerClient: Sendable {
  public var moveFocus: @Sendable (FocusDirection) async -> Void
  public var cycleApp: @Sendable (_ direction: CycleDirection, _ bundleIds: [String]) async -> Void
}

public enum FocusDirection: Sendable, Hashable {
  case left, right, up, down
}

public enum CycleDirection: Sendable, Hashable {
  case next, previous
}

extension FocusManagerClient: DependencyKey {
  public static let liveValue = FocusManagerClient(
    moveFocus: { direction in
      guard AXIsProcessTrusted() else { return }
      await MainActor.run {
        FocusEngine.moveFocus(direction)
      }
    },
    cycleApp: { direction, bundleIds in
      await MainActor.run {
        FocusEngine.cycleApp(direction, bundleIds: bundleIds)
      }
    }
  )

  public static let testValue = FocusManagerClient(
    moveFocus: { _ in },
    cycleApp: { _, _ in }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var focusManager: FocusManagerClient {
    get { self[FocusManagerClient.self] }
    set { self[FocusManagerClient.self] = newValue }
  }
}

private enum FocusEngine {
  @MainActor
  static func moveFocus(_ direction: FocusDirection) {
    let windows = collectVisibleWindows()
    guard let current = focusedWindow(in: windows) else {
      logger.debug("No focused window for moveFocus")
      return
    }
    let candidates = windows.filter { $0.element != current.element }
    let next = candidates
      .filter { isInDirection(from: current.frame, to: $0.frame, direction: direction) }
      .min { lhs, rhs in
        distance(from: current.frame, to: lhs.frame, direction: direction)
          < distance(from: current.frame, to: rhs.frame, direction: direction)
      }
    guard let next else { return }
    if let app = NSRunningApplication(processIdentifier: next.pid) {
      app.activate(options: [.activateIgnoringOtherApps])
    }
    AXUIElementPerformAction(next.element, kAXRaiseAction as CFString)
  }

  @MainActor
  static func cycleApp(_ direction: CycleDirection, bundleIds: [String]) {
    let running = bundleIds.compactMap { bundleId in
      NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    }
    guard !running.isEmpty else { return }
    let frontmost = NSWorkspace.shared.frontmostApplication
    let currentIndex = running.firstIndex { $0 == frontmost } ?? -1
    let count = running.count
    let step = direction == .next ? 1 : -1
    let nextIndex = (currentIndex + step + count) % count
    running[nextIndex].activate(options: [.activateIgnoringOtherApps])
  }

  // MARK: - Helpers

  private struct WindowInfo {
    let element: AXUIElement
    let pid: pid_t
    let frame: CGRect
  }

  @MainActor
  private static func collectVisibleWindows() -> [WindowInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
      .flatMap { app -> [WindowInfo] in
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          axApp, kAXWindowsAttribute as CFString, &raw
        ) == .success,
        let windows = raw as? [AXUIElement]
        else { return [] }
        return windows.compactMap { window in
          guard let frame = windowFrame(window) else { return nil }
          return WindowInfo(element: window, pid: app.processIdentifier, frame: frame)
        }
      }
  }

  @MainActor
  private static func focusedWindow(in windows: [WindowInfo]) -> WindowInfo? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
      return nil
    }
    let axApp = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      axApp, kAXFocusedWindowAttribute as CFString, &raw
    ) == .success,
          let value = raw,
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return windows.first { $0.pid == pid } }
    let element = value as! AXUIElement
    return windows.first { $0.element == element }
      ?? windows.first { $0.pid == pid }
  }

  private static func windowFrame(_ window: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    guard let posRef, let sizeRef,
          CFGetTypeID(posRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    guard size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: pos, size: size)
  }

  private static func isInDirection(
    from source: CGRect,
    to target: CGRect,
    direction: FocusDirection
  ) -> Bool {
    switch direction {
    case .left: return target.midX < source.midX
    case .right: return target.midX > source.midX
    case .up: return target.midY < source.midY
    case .down: return target.midY > source.midY
    }
  }

  private static func distance(
    from source: CGRect,
    to target: CGRect,
    direction: FocusDirection
  ) -> CGFloat {
    let dx = target.midX - source.midX
    let dy = target.midY - source.midY
    // Penalize perpendicular distance so we prefer aligned windows.
    switch direction {
    case .left, .right:
      return abs(dx) + abs(dy) * 1.5
    case .up, .down:
      return abs(dy) + abs(dx) * 1.5
    }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FocusManager")
