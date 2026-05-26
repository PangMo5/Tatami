import AppKit
import ApplicationServices
import Dependencies
import Foundation
import OSLog

/// Arranges the windows of a workspace on activation according to its
/// `TilingMode`. Phase 3g-2 ships a real AX-driven implementation for
/// single-display BSP and Stack modes; Floating is a no-op.
public struct WindowTilerClient: Sendable {
  public var tile: @Sendable (TilingRequest) async -> Void

  public init(tile: @escaping @Sendable (TilingRequest) async -> Void) {
    self.tile = tile
  }
}

public struct TilingRequest: Sendable, Hashable {
  public var workspaceId: Workspace.ID
  public var mode: TilingMode
  public var bundleIdentifiers: [String]
  public var targetDisplay: DisplayName?

  public init(
    workspaceId: Workspace.ID,
    mode: TilingMode,
    bundleIdentifiers: [String],
    targetDisplay: DisplayName?
  ) {
    self.workspaceId = workspaceId
    self.mode = mode
    self.bundleIdentifiers = bundleIdentifiers
    self.targetDisplay = targetDisplay
  }
}

extension WindowTilerClient: DependencyKey {
  public static let liveValue = WindowTilerClient { request in
    guard request.mode != .floating else { return }
    guard AXIsProcessTrusted() else {
      logger.warning("Skipping tile — Accessibility permission not granted")
      return
    }
    await MainActor.run {
      perform(request)
    }
  }

  public static let testValue = WindowTilerClient(tile: { _ in })
  public static let previewValue = testValue

  @MainActor
  private static func perform(_ request: TilingRequest) {
    let screen = resolveScreen(request.targetDisplay)
    guard let screen else {
      logger.warning("No screen for display \(request.targetDisplay?.rawValue ?? "any")")
      return
    }
    let workArea = workAreaInAXCoordinates(for: screen)

    let frames: [String: CGRect]
    switch request.mode {
    case .bsp:
      frames = BSPNode<String>
        .build(request.bundleIdentifiers, in: workArea)?
        .frames(in: workArea, gap: 8) ?? [:]
    case .stack:
      frames = Dictionary(uniqueKeysWithValues:
        request.bundleIdentifiers.map { ($0, workArea) })
    case .floating:
      return
    }

    for (bundleId, frame) in frames {
      applyFrame(frame, toFirstWindowOf: bundleId)
    }
  }

  /// macOS AX uses top-origin coordinates anchored to the **primary**
  /// screen. NSScreen.visibleFrame is bottom-origin. Translate once
  /// per screen.
  @MainActor
  private static func workAreaInAXCoordinates(for screen: NSScreen) -> CGRect {
    guard let primary = NSScreen.screens.first else { return screen.visibleFrame }
    let primaryHeight = primary.frame.height
    let v = screen.visibleFrame
    let axY = primaryHeight - v.origin.y - v.height
    return CGRect(x: v.origin.x, y: axY, width: v.width, height: v.height)
  }

  @MainActor
  private static func resolveScreen(_ name: DisplayName?) -> NSScreen? {
    if let name {
      return NSScreen.screens.first(where: { $0.localizedName == name.rawValue })
        ?? NSScreen.main
    }
    return NSScreen.main
  }

  @MainActor
  private static func applyFrame(_ frame: CGRect, toFirstWindowOf bundleId: String) {
    guard
      let app = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleId)
        .first(where: { !$0.isTerminated && $0.activationPolicy == .regular })
    else { return }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var windowsValue: CFTypeRef?
    let copyResult = AXUIElementCopyAttributeValue(
      axApp,
      kAXWindowsAttribute as CFString,
      &windowsValue
    )
    guard copyResult == .success,
          let windows = windowsValue as? [AXUIElement],
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

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
