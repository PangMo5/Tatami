import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Side-effect surface for "make this workspace active". Activation uses
/// a show-before-hide policy:
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
@DependencyClient
public struct WorkspaceManagerClient: Sendable {
  public var activate: @Sendable (ActivationRequest) async -> Void
}

public struct ActivationRequest: Sendable, Hashable {
  public var workspace: Workspace
  public var floatingApps: [FloatingApp]
  /// Display this activation targets. `nil` → all displays.
  public var targetDisplay: DisplayName?
  public var setFocus: Bool
  /// Mouse-follows-focus warps the cursor *after* the BSP tile pass (so
  /// it lands on the window's final tiled position), so it's handled by
  /// the activation reducer — not here.
  public var mouseHidesOnFocus: Bool

  public init(
    workspace: Workspace,
    floatingApps: [FloatingApp],
    targetDisplay: DisplayName?,
    setFocus: Bool = true,
    mouseHidesOnFocus: Bool = false
  ) {
    self.workspace = workspace
    self.floatingApps = floatingApps
    self.targetDisplay = targetDisplay
    self.setFocus = setFocus
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

          // 0. Auto-open: launch assigned apps flagged autoOpen that
          //    aren't running yet. They join the layout later via the
          //    window-created observer.
          let runningBundleIds = Set(running.compactMap(\.bundleIdentifier))
          for app in request.workspace.apps
          where app.autoOpen && !runningBundleIds.contains(app.bundleIdentifier) {
            guard let url = NSWorkspace.shared
              .urlForApplication(withBundleIdentifier: app.bundleIdentifier)
            else { continue }
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
              if let error {
                logger.error(
                  "open \(app.bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
              }
            }
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

          // 2. Hide everything else. Finder is special-cased: only hide
          //    it when a workspace app is actually running — otherwise
          //    we'd be left on an empty desktop.
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
  /// `unhide()` when there's no main window yet.
  fileprivate func raiseMainWindow() {
    guard let mainAXWindow else {
      unhide()
      return
    }
    AXUIElementPerformAction(mainAXWindow, kAXRaiseAction as CFString)
  }
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
