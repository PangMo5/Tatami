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
///  2. unhide every app in `sharedApps`
///  3. hide every other regular running app on the same display (the
///     unassigned ones included)
///  4. focus the workspace's preferred app
///
/// The BSP tile pass runs separately (`WindowTilerClient`) after the
/// show/hide step completes, on the assumption that windows already
/// belong to the right Spaces.
@DependencyClient
struct WorkspaceManagerClient: Sendable {
  var activate: @Sendable (ActivationRequest) async -> Void
}

/// Reads as `@Dependency(\.mouse).hideUntilMouseMoves`. Surfaced via a
/// dedicated `Sendable` thunk so `WorkspaceManagerClient.live` can
/// invoke the cursor-hide side effect without reaching for a
/// singleton.
private struct CursorHideSink: Sendable {
  let invoke: @Sendable () -> Void
}

struct ActivationRequest: Sendable, Hashable {
  var workspace: Workspace
  var sharedApps: [SharedApp]
  /// Display this activation targets. `nil` → all displays.
  var targetDisplay: DisplayName?
  var setFocus: Bool
  /// Mouse-follows-focus warps the cursor *after* the BSP tile pass (so
  /// it lands on the window's final tiled position), so it's handled by
  /// the activation reducer — not here.
  var mouseHidesOnFocus: Bool

  init(
    workspace: Workspace,
    sharedApps: [SharedApp],
    targetDisplay: DisplayName?,
    setFocus: Bool = true,
    mouseHidesOnFocus: Bool = false
  ) {
    self.workspace = workspace
    self.sharedApps = sharedApps
    self.targetDisplay = targetDisplay
    self.setFocus = setFocus
    self.mouseHidesOnFocus = mouseHidesOnFocus
  }
}

extension WorkspaceManagerClient: DependencyKey {
  static let liveValue: WorkspaceManagerClient = .live()

  static let testValue = WorkspaceManagerClient(activate: { _ in })
  static let previewValue = WorkspaceManagerClient(activate: { request in
    logger.debug("[preview] activate \(request.workspace.name)")
  })

  static func live() -> WorkspaceManagerClient {
    // Resolve the cursor-hide side effect through the dependency
    // system instead of a singleton. `withDependencies(_:)` reads the
    // current scope at call time — so test overrides of `\.mouse`
    // still win.
    let cursorHide = CursorHideSink {
      @Dependency(\.mouse) var mouse
      mouse.hideUntilMouseMoves()
    }
    return _live(cursorHide: cursorHide)
  }

  private static func _live(cursorHide: CursorHideSink) -> WorkspaceManagerClient {
    WorkspaceManagerClient(
      activate: { request in
        let workspaceBundleIds = Set(request.workspace.apps.map(\.bundleIdentifier))
        let sharedBundleIds = Set(request.sharedApps.map(\.bundleIdentifier))
        let keepVisible = workspaceBundleIds.union(sharedBundleIds)

        await MainActor.run {
          let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
          }
          let isAnyWorkspaceAppRunning = running.contains {
            workspaceBundleIds.contains($0.bundleIdentifier ?? "")
          }

          // 0. Auto-open: (re)open assigned apps flagged autoOpen that have no
          //    visible window — whether fully quit or just running with their
          //    window closed (Electron apps that hide on close, etc.). Opening
          //    the app URL launches it, or replays a Dock-style "reopen" that
          //    brings the window back. They join the layout via the
          //    window-created observer. Apps that already have a window on
          //    screen are left alone.
          // One WindowServer snapshot serves both the auto-open check here
          // and the multi-display hide scoping below — under system load a
          // second round trip is not free.
          let onScreenWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
          ) as? [[String: Any]] ?? []
          let onScreenOwnerPids = Set(
            onScreenWindows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
          )
          let runningByBundle = Dictionary(grouping: running) { $0.bundleIdentifier ?? "" }
          for app in request.workspace.apps where app.autoOpen {
            let instances = runningByBundle[app.bundleIdentifier] ?? []
            let hasVisibleWindow = instances.contains {
              onScreenOwnerPids.contains($0.processIdentifier)
            }
            if hasVisibleWindow { continue }
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
          //
          // Multi-display: scope the hide pass to apps whose windows live on
          // this workspace's target display, so switching one display's
          // workspace leaves the *other* display's active workspace visible.
          // (Single display → `nil` → hide globally as before.) `hide()` is
          // app-level, so an app spanning two displays still hides on both —
          // that's the no-SIP limit, same as FlashSpace.
          let pidsOnTargetDisplay: Set<pid_t>? = {
            guard NSScreen.screens.count > 1,
                  let target = request.targetDisplay
            else { return nil }
            return Self.pids(onDisplay: target, in: onScreenWindows)
          }()

          var hiddenCount = 0
          for app in running {
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else { continue }
            if MacApp.isTatami(bundleId) {
              continue
            }
            if keepVisible.contains(bundleId) { continue }
            if app.isFinder, !isAnyWorkspaceAppRunning { continue }
            if let pidsOnTargetDisplay,
               !pidsOnTargetDisplay.contains(app.processIdentifier) {
              continue
            }
            if !app.isHidden {
              app.hide()
              hiddenCount += 1
            }
          }

          if request.mouseHidesOnFocus {
            cursorHide.invoke()
          }

          logger.info(
            """
            Activated '\(request.workspace.name)' on \
            \(request.targetDisplay?.name ?? "any"): \
            show=\(workspaceBundleIds.count) float=\(sharedBundleIds.count) \
            hide=\(hiddenCount)
            """
          )
        }
      }
    )
  }

  /// pids whose on-screen, layer-0 windows are centered on the named display,
  /// filtered from an already-taken `CGWindowListCopyWindowInfo` snapshot.
  /// Used to scope an activation's hide pass to a single display.
  @MainActor
  private static func pids(
    onDisplay ref: DisplayName, in windows: [[String: Any]]
  ) -> Set<pid_t> {
    guard let primary = DisplayResolver.primaryScreen(),
          let screen = DisplayResolver.connectedScreen(for: ref)
    else { return [] }
    // CGWindowList bounds are top-left / Quartz, primary-anchored. Convert the
    // target screen's Cocoa frame into that space (same flip as ScreenGeometry).
    let primaryHeight = primary.frame.height
    let f = screen.frame
    let target = CGRect(
      x: f.origin.x,
      y: primaryHeight - f.origin.y - f.height,
      width: f.width,
      height: f.height
    )
    var pids: Set<pid_t> = []
    for entry in windows {
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
            let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
            let b = entry[kCGWindowBounds as String] as? [String: CGFloat],
            let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
      else { continue }
      if target.contains(CGPoint(x: x + w / 2, y: y + h / 2)) { pids.insert(pid) }
    }
    return pids
  }
}

extension DependencyValues {
  var workspaceManager: WorkspaceManagerClient {
    get { self[WorkspaceManagerClient.self] }
    set { self[WorkspaceManagerClient.self] = newValue }
  }
}

extension NSRunningApplication {
  var isFinder: Bool { bundleIdentifier == MacApp.finderBundleId }

  /// Bring the app's main window to the front via Accessibility — the
  /// reliable way to surface an app that was just unhidden (plain
  /// `activate` often leaves the window behind Finder). Falls back to
  /// `unhide()` when there's no main window yet.
  ///
  /// Both AX round trips block on the target app's run loop, bounded by
  /// the process-global messaging timeout (`boundGlobalAXMessagingTimeout`,
  /// 1 s) — sized for a genuinely hung app, not as a latency lever: a
  /// merely busy app should still get its raise.
  fileprivate func raiseMainWindow() {
    let app = AXUIElementCreateApplication(processIdentifier)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      app, kAXMainWindowAttribute as CFString, &raw
    ) == .success,
      let raw, CFGetTypeID(raw) == AXUIElementGetTypeID()
    else {
      unhide()
      return
    }
    AXUIElementPerformAction(raw as! AXUIElement, kAXRaiseAction as CFString)
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WorkspaceManager")
