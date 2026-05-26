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
        let outcome = applyFrame(frame, toFirstWindowOf: bundleId)
        logger.info(
          "apply \(bundleId, privacy: .public) → \(frame.debugDescription, privacy: .public) = \(outcome, privacy: .public)"
        )
      }
    }
  }

  public static let testValue = WindowTilerClient(apply: { _ in })
  public static let previewValue = testValue

  @MainActor
  private static func applyFrame(
    _ frame: CGRect,
    toFirstWindowOf bundleId: String
  ) -> String {
    guard
      let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    else { return "app-not-running" }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    let copyResult = AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &raw
    )
    if copyResult != .success {
      return "windows-copy-fail(\(copyResult.rawValue))"
    }
    guard let windows = raw as? [AXUIElement] else {
      return "windows-cast-fail"
    }
    guard let window = windows.first else {
      return "no-windows"
    }

    // If the window is in macOS native fullscreen, AX setSize is
    // rejected with kAXErrorCannotComplete (-25200). Drop fullscreen
    // first so the BSP frame can apply.
    if isFullScreen(window) {
      _ = AXUIElementSetAttributeValue(
        window,
        "AXFullScreen" as CFString,
        false as CFTypeRef
      )
    }

    // Toggle the per-app "enhanced user interface" attribute so AX
    // resize/move bypasses the system window animation — same trick
    // yabai and Rectangle use to get instant tile updates.
    let enhanced = "AXEnhancedUserInterface" as CFString
    var enhancedWasOn = false
    var enhancedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, enhanced, &enhancedRaw) == .success,
       let value = enhancedRaw as? Bool
    {
      enhancedWasOn = value
    }
    if !enhancedWasOn {
      _ = AXUIElementSetAttributeValue(axApp, enhanced, true as CFTypeRef)
    }
    defer {
      if !enhancedWasOn {
        _ = AXUIElementSetAttributeValue(axApp, enhanced, false as CFTypeRef)
      }
    }

    var posError = AXError.success
    var position = CGPoint(x: frame.minX, y: frame.minY)
    if let posValue = AXValueCreate(.cgPoint, &position) {
      posError = AXUIElementSetAttributeValue(
        window, kAXPositionAttribute as CFString, posValue
      )
    }
    var sizeError = AXError.success
    var size = CGSize(width: frame.width, height: frame.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
      sizeError = AXUIElementSetAttributeValue(
        window, kAXSizeAttribute as CFString, sizeValue
      )
    }

    if posError == .success, sizeError == .success { return "ok" }
    return "pos=\(posError.rawValue) size=\(sizeError.rawValue)"
  }

  @MainActor
  private static func isFullScreen(_ window: AXUIElement) -> Bool {
    var raw: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      window,
      "AXFullScreen" as CFString,
      &raw
    )
    guard result == .success, let value = raw as? Bool else { return false }
    return value
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
