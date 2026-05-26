import AppKit
import Dependencies
import Foundation
import OSLog

/// Side-effect surface for "make this workspace active": showing/hiding
/// macOS apps via `NSRunningApplication`. Display-aware — hiding only
/// affects apps whose windows sit on the workspace's target display(s).
public struct WorkspaceManagerClient: Sendable {
  public var activate: @Sendable (ActivationRequest) async -> Void

  public init(activate: @escaping @Sendable (ActivationRequest) async -> Void) {
    self.activate = activate
  }
}

/// What the activation engine needs to flip "active" to a workspace.
public struct ActivationRequest: Sendable, Hashable {
  public var workspace: Workspace
  public var floatingApps: [FloatingApp]
  /// Display this activation targets. `nil` → all displays (dynamic mode).
  public var targetDisplay: DisplayName?
  /// Bundle identifiers belonging to *other* workspaces on the same display.
  /// These are the apps we need to hide. Anything not in this set (and not
  /// in `workspace.apps` or `floatingApps`) is treated as "unassigned" and
  /// left visible.
  public var displayPeerBundleIds: Set<String>
  public var setFocus: Bool
  public var mouseFollowsFocus: Bool
  public var mouseHidesOnFocus: Bool

  public init(
    workspace: Workspace,
    floatingApps: [FloatingApp],
    targetDisplay: DisplayName?,
    displayPeerBundleIds: Set<String> = [],
    setFocus: Bool = true,
    mouseFollowsFocus: Bool = false,
    mouseHidesOnFocus: Bool = false
  ) {
    self.workspace = workspace
    self.floatingApps = floatingApps
    self.targetDisplay = targetDisplay
    self.displayPeerBundleIds = displayPeerBundleIds
    self.setFocus = setFocus
    self.mouseFollowsFocus = mouseFollowsFocus
    self.mouseHidesOnFocus = mouseHidesOnFocus
  }
}

extension WorkspaceManagerClient: DependencyKey {
  public static let liveValue: WorkspaceManagerClient = .live()

  public static let testValue = WorkspaceManagerClient(activate: { _ in })
  public static let previewValue = WorkspaceManagerClient(activate: { request in
    logger.debug("[preview] activate \(request.workspace.name)")
  })

  static func live() -> WorkspaceManagerClient {
    WorkspaceManagerClient(
      activate: { request in
        let workspace = request.workspace
        let workspaceBundleIds = Set(workspace.apps.map(\.bundleIdentifier))
        let floatingBundleIds = Set(request.floatingApps.map(\.bundleIdentifier))
        let appsToHide = request.displayPeerBundleIds
          .subtracting(workspaceBundleIds)
          .subtracting(floatingBundleIds)

        await MainActor.run {
          let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
          }

          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }

            if workspaceBundleIds.contains(bundleId) || floatingBundleIds.contains(bundleId) {
              if app.isHidden {
                app.unhide()
              }
            } else if appsToHide.contains(bundleId), !app.isHidden {
              app.hide()
            }
            // Apps not in any workspace on this display: leave alone.
          }

          let focusedApp: NSRunningApplication?
          if request.setFocus, let focusBundleId = workspace.appToFocusBundleId
             ?? workspace.apps.last?.bundleIdentifier
          {
            focusedApp = running.first { $0.bundleIdentifier == focusBundleId }
            focusedApp?.activate(options: [.activateIgnoringOtherApps])
          } else if request.setFocus {
            focusedApp = running.first { workspaceBundleIds.contains($0.bundleIdentifier ?? "") }
            focusedApp?.activate(options: [.activateIgnoringOtherApps])
          } else {
            focusedApp = nil
          }

          if request.mouseFollowsFocus, let app = focusedApp,
             let center = focusedWindowCenter(of: app)
          {
            CGWarpMouseCursorPosition(center)
            CGAssociateMouseAndMouseCursorPosition(1)
          }
          if request.mouseHidesOnFocus {
            CGDisplayHideCursor(CGMainDisplayID())
          }
        }

        let displayLabel = request.targetDisplay?.rawValue ?? "any"
        logger.info(
          """
          Activated workspace '\(workspace.name)' on display '\(displayLabel)': \
          show=\(workspaceBundleIds.count) float=\(floatingBundleIds.count) \
          hide=\(appsToHide.count)
          """
        )
      }
    )
  }
}

extension DependencyValues {
  public var workspaceManager: WorkspaceManagerClient {
    get { self[WorkspaceManagerClient.self] }
    set { self[WorkspaceManagerClient.self] = newValue }
  }
}

@MainActor
private func focusedWindowCenter(of app: NSRunningApplication) -> CGPoint? {
  let axApp = AXUIElementCreateApplication(app.processIdentifier)
  var focusedValue: CFTypeRef?
  let copyResult = AXUIElementCopyAttributeValue(
    axApp,
    kAXFocusedWindowAttribute as CFString,
    &focusedValue
  )
  guard copyResult == .success, let raw = focusedValue,
        CFGetTypeID(raw) == AXUIElementGetTypeID()
  else { return nil }
  let window = raw as! AXUIElement

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
  return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WorkspaceManager")
