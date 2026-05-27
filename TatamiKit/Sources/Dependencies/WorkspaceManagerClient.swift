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
          let isAnyWorkspaceAppRunning = running.contains {
            workspaceBundleIds.contains($0.bundleIdentifier ?? "")
          }

          // Resolve the focus target among the workspace's own apps.
          let focusBundleId = request.workspace.appToFocusBundleId
            ?? request.workspace.apps.last?.bundleIdentifier
          let appsToShow = running.filter { keepVisible.contains($0.bundleIdentifier ?? "") }
          let toFocus = appsToShow.first { $0.bundleIdentifier == focusBundleId }
            ?? appsToShow.first { workspaceBundleIds.contains($0.bundleIdentifier ?? "") }

          // 1. Show the workspace + floating apps and focus FIRST, before
          //    hiding anything. Hiding first lets macOS surface Finder (or
          //    another leftover app) as frontmost, which then steals focus.
          for app in appsToShow where app.isHidden {
            app.unhide()
          }
          if request.setFocus, let toFocus {
            // unhide → raise → activate: just unhiding + activate leaves
            // the window behind Finder, so raise the main window via AX
            // before activating to land focus reliably.
            toFocus.raiseMainWindow()
            toFocus.activate(options: [.activateIgnoringOtherApps])
          }

          // 2. Hide everything else. Finder is special-cased like
          //    FlashSpace: only hide it when a workspace app is actually
          //    running — otherwise we'd be left on an empty desktop.
          var hiddenCount = 0
          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }
            if bundleId == "dev.PangMo5.Tatami" || bundleId == "dev.PangMo5.Tatami.dev" {
              continue
            }
            if keepVisible.contains(bundleId) { continue }
            if app.isFinder, !isAnyWorkspaceAppRunning { continue }
            if !app.isHidden {
              app.hide()
              hiddenCount += 1
            }
          }

          if request.mouseFollowsFocus, let app = toFocus,
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

extension NSRunningApplication {
  var isFinder: Bool { bundleIdentifier == MacApp.finderBundleId }

  fileprivate var mainAXWindow: AXUIElement? {
    let app = AXUIElementCreateApplication(processIdentifier)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      app, kAXMainWindowAttribute as CFString, &raw
    ) == .success,
      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return nil }
    return (raw as! AXUIElement)
  }

  /// Bring the app's main window to the front via Accessibility — the
  /// reliable way to surface an app that was just unhidden (plain
  /// `activate` often leaves the window behind Finder). Falls back to
  /// `unhide()` when there's no main window yet. Mirrors FlashSpace.
  fileprivate func raiseMainWindow() {
    guard let mainAXWindow else {
      unhide()
      return
    }
    AXUIElementPerformAction(mainAXWindow, kAXRaiseAction as CFString)
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
