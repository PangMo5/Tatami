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
    guard !request.bundleIdToFrame.isEmpty else {
      logger.debug("apply: no frames to apply")
      return
    }
    let trusted = await MainActor.run { ensureAccessibilityTrust() }
    guard trusted else {
      logger.warning(
        """
        Accessibility permission not granted — open System Settings → \
        Privacy & Security → Accessibility and enable Tatami.
        """
      )
      return
    }
    await MainActor.run {
      logger.info("apply: \(request.bundleIdToFrame.count) frames")
      for (bundleId, frame) in request.bundleIdToFrame {
        let ok = applyFrame(frame, toFirstWindowOf: bundleId)
        logger.debug(
          "apply \(bundleId) → \(frame.debugDescription) = \(ok ? "ok" : "fail")"
        )
      }
    }
  }

  public static let testValue = WindowTilerClient(apply: { _ in })
  public static let previewValue = testValue

  @MainActor
  @discardableResult
  private static func applyFrame(_ frame: CGRect, toFirstWindowOf bundleId: String) -> Bool {
    guard
      let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    else { return false }

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
    else { return false }

    var ok = true
    var position = CGPoint(x: frame.minX, y: frame.minY)
    if let posValue = AXValueCreate(.cgPoint, &position) {
      let r = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
      if r != .success { ok = false }
    }
    var size = CGSize(width: frame.width, height: frame.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      let r = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
      if r != .success { ok = false }
    }
    return ok
  }
}

/// Returns true when the app already has AX permission; otherwise asks
/// macOS to surface the prompt. The prompt key lives in a global var
/// in C, so the conversion to a Swift String is wrapped behind a
/// `MainActor` hop to keep strict concurrency happy.
@MainActor
@discardableResult
public func ensureAccessibilityTrust() -> Bool {
  if AXIsProcessTrusted() { return true }
  // Inline the framework constant; the C symbol itself is `var` and
  // therefore not concurrency-safe to reference under Swift 6 strict
  // mode. The string is part of Apple's public API surface and is
  // documented as immutable.
  let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
  return AXIsProcessTrustedWithOptions(options)
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
