import AppKit
import ApplicationServices
import Dependencies
import Foundation
import OSLog

/// Applies a precomputed set of `(bundleId → frame)` assignments to the
/// running apps' windows via Accessibility. BSP tree maths live in the
/// reducer; this dependency is a thin AX wrapper.
public struct WindowTilerClient: Sendable {
  public var apply: @Sendable (FrameApplication) async -> Void

  public init(apply: @escaping @Sendable (FrameApplication) async -> Void) {
    self.apply = apply
  }
}

public struct FrameApplication: Sendable, Hashable {
  public var bundleIdToFrame: [String: CGRect]
  public var targetDisplay: DisplayName?

  public init(
    bundleIdToFrame: [String: CGRect],
    targetDisplay: DisplayName?
  ) {
    self.bundleIdToFrame = bundleIdToFrame
    self.targetDisplay = targetDisplay
  }
}

extension WindowTilerClient: DependencyKey {
  public static let liveValue = WindowTilerClient { request in
    guard !request.bundleIdToFrame.isEmpty else { return }
    guard AXIsProcessTrusted() else {
      logger.warning("Skipping apply — Accessibility permission not granted")
      return
    }
    await MainActor.run {
      for (bundleId, frame) in request.bundleIdToFrame {
        applyFrame(frame, toFirstWindowOf: bundleId)
      }
    }
  }

  public static let testValue = WindowTilerClient(apply: { _ in })
  public static let previewValue = testValue

  @MainActor
  private static func applyFrame(_ frame: CGRect, toFirstWindowOf bundleId: String) {
    guard
      let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    else { return }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    let copyResult = AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw
    )
    guard copyResult == .success,
          let windows = raw as? [AXUIElement],
          let window = windows.first
    else { return }

    var position = CGPoint(x: frame.minX, y: frame.minY)
    if let posValue = AXValueCreate(.cgPoint, &position) {
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
    }
    var size = CGSize(width: frame.width, height: frame.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
  }
}

extension DependencyValues {
  public var windowTiler: WindowTilerClient {
    get { self[WindowTilerClient.self] }
    set { self[WindowTilerClient.self] = newValue }
  }
}

/// Resolve the AX work area of the named screen (or the main screen if
/// `name` is nil). Coordinates are top-origin, anchored to the primary
/// screen — same convention as `AXUIElementCopyAttributeValue` returns
/// for `kAXPositionAttribute`.
public enum ScreenGeometry {
  @MainActor
  public static func workArea(for name: DisplayName?) -> CGRect {
    let screen: NSScreen?
    if let name {
      screen = NSScreen.screens.first(where: { $0.localizedName == name.rawValue })
        ?? NSScreen.main
    } else {
      screen = NSScreen.main
    }
    guard let screen, let primary = NSScreen.screens.first else { return .zero }
    let primaryHeight = primary.frame.height
    let v = screen.visibleFrame
    let axY = primaryHeight - v.origin.y - v.height
    return CGRect(x: v.origin.x, y: axY, width: v.width, height: v.height)
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
