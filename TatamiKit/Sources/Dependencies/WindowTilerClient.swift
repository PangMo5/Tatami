import AppKit
import Dependencies
import Foundation
import OSLog

/// Arranges the windows of a workspace on activation according to its
/// `TilingMode`. This is the dependency seam through which Tatami calls
/// the Accessibility API to move and resize windows.
///
/// **Phase 3g** ships an interface + a logging-only `liveValue` so the
/// reducer wiring is shippable and testable. The real AX-driven impl
/// lands in a follow-up phase.
public struct WindowTilerClient: Sendable {
  /// Arrange the windows of `workspace` on `display`. Implementations
  /// receive the full layout request so the caller does not need to
  /// guess display bounds or window order.
  public var tile: @Sendable (TilingRequest) async -> Void

  public init(tile: @escaping @Sendable (TilingRequest) async -> Void) {
    self.tile = tile
  }
}

public struct TilingRequest: Sendable, Hashable {
  public var workspaceId: Workspace.ID
  public var mode: TilingMode
  /// Bundle identifiers of the apps Tatami expects to participate in
  /// the layout. The implementation enumerates their running windows
  /// via AX.
  public var bundleIdentifiers: [String]
  /// The display the workspace was activated on. `nil` when the
  /// workspace is in dynamic-display mode.
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
    logger.info(
      """
      [stub] tile workspace=\(request.workspaceId.uuidString) \
      mode=\(request.mode.rawValue) \
      apps=\(request.bundleIdentifiers.count) \
      display=\(request.targetDisplay?.rawValue ?? "any")
      """
    )
  }

  public static let testValue = WindowTilerClient(tile: { _ in })
  public static let previewValue = testValue
}

extension DependencyValues {
  public var windowTiler: WindowTilerClient {
    get { self[WindowTilerClient.self] }
    set { self[WindowTilerClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WindowTiler")
