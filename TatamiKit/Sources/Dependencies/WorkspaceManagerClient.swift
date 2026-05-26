import AppKit
import ApplicationServices
import Dependencies
import Foundation
import OSLog

/// Side-effect surface for "make this workspace active". Activation
/// follows FlashSpace's policy:
///
///  1. unhide every app belonging to the target workspace
///  2. unhide every app in `floatingApps`
///  3. hide every other regular running app on the same display (the
///     unassigned ones included)
///  4. focus the workspace's preferred app
///
/// The BSP tile pass runs separately (`WindowTilerClient`) after the
/// show/hide step completes, on the assumption that windows already
/// belong to the right Spaces.
public struct WorkspaceManagerClient: Sendable {
  public var activate: @Sendable (ActivationRequest) async -> Void

  public init(activate: @escaping @Sendable (ActivationRequest) async -> Void) {
    self.activate = activate
  }
}

public struct ActivationRequest: Sendable, Hashable {
  public var workspace: Workspace
  public var floatingApps: [FloatingApp]
  /// Display this activation targets. `nil` → all displays.
  public var targetDisplay: DisplayName?
  public var setFocus: Bool
  public var mouseFollowsFocus: Bool
  public var mouseHidesOnFocus: Bool

  public init(
    workspace: Workspace,
    floatingApps: [FloatingApp],
    targetDisplay: DisplayName?,
    setFocus: Bool = true,
    mouseFollowsFocus: Bool = false,
    mouseHidesOnFocus: Bool = false
  ) {
    self.workspace = workspace
    self.floatingApps = floatingApps
    self.targetDisplay = targetDisplay
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
        let workspaceBundleIds = Set(request.workspace.apps.map(\.bundleIdentifier))
        let floatingBundleIds = Set(request.floatingApps.map(\.bundleIdentifier))
        let keepVisible = workspaceBundleIds.union(floatingBundleIds)

        await MainActor.run {
          let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
          }

          var hiddenCount = 0
          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }
            // Skip ourselves (and any agent app the user keeps).
            if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
              continue
            }

            if keepVisible.contains(bundleId) {
              if app.isHidden { app.unhide() }
            } else if !app.isHidden {
              app.hide()
              hiddenCount += 1
            }
          }

          let focusedApp: NSRunningApplication?
          if request.setFocus, let focusBundleId = request.workspace.appToFocusBundleId
             ?? request.workspace.apps.last?.bundleIdentifier
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
            CursorHidingController.shared.hideUntilMouseMoves()
          }

          logger.info(
            """
            Activated '\(request.workspace.name)' on \
            \(request.targetDisplay?.rawValue ?? "any"): \
            show=\(workspaceBundleIds.count) float=\(floatingBundleIds.count) \
            hide=\(hiddenCount)
            """
          )
        }
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

/// Hides the cursor on activation; the first global mouse-moved event
/// brings it back. Reference-counts hides so back-to-back activations
/// don't double-hide.
@MainActor
final class CursorHidingController {
  static let shared = CursorHidingController()
  private var monitor: Any?
  private var isHidden = false

  func hideUntilMouseMoves() {
    if !isHidden {
      CGDisplayHideCursor(CGMainDisplayID())
      isHidden = true
    }
    guard monitor == nil else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      self?.show()
    }
  }

  func show() {
    if isHidden {
      CGDisplayShowCursor(CGMainDisplayID())
      isHidden = false
    }
    if let m = monitor {
      NSEvent.removeMonitor(m)
      monitor = nil
    }
  }

  private init() {}
}
