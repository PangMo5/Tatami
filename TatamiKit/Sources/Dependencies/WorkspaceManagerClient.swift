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
  /// "Most recently used" focus target (no pinned app): the exact window
  /// to raise, so focus lands on the window the user last used — not just
  /// the app's main window. Nil → fall back to the app-level target.
  var windowKeyToFocus: WindowKey?
  /// Apps of a borrowed workspace to also keep visible during a composition
  /// (the borrowed block's windows must stay up alongside the host's).
  var borrowedApps: [AppAssignment] = []
  /// The Tatami-managed "universe": every bundle id registered to a workspace
  /// in the active profile, plus shared apps. When non-empty, the hide pass
  /// only hides apps in this set — an app the user never registered (a floating
  /// utility, a system dialog) is left alone. Supplied on *borrow* activations
  /// (borrow in / release); a plain switch passes an empty set → legacy "hide
  /// every non-kept app".
  var managedBundleIds: Set<String> = []

  init(
    workspace: Workspace,
    sharedApps: [SharedApp],
    targetDisplay: DisplayName?,
    setFocus: Bool = true,
    mouseHidesOnFocus: Bool = false,
    windowKeyToFocus: WindowKey? = nil,
    borrowedApps: [AppAssignment] = [],
    managedBundleIds: Set<String> = []
  ) {
    self.workspace = workspace
    self.sharedApps = sharedApps
    self.targetDisplay = targetDisplay
    self.setFocus = setFocus
    self.mouseHidesOnFocus = mouseHidesOnFocus
    self.windowKeyToFocus = windowKeyToFocus
    self.borrowedApps = borrowedApps
    self.managedBundleIds = managedBundleIds
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
        @Dependency(\.debugLog) var debugLog
        let workspaceBundleIds = Set(request.workspace.apps.map(\.bundleIdentifier))
        let sharedBundleIds = Set(request.sharedApps.map(\.bundleIdentifier))
        let borrowedBundleIds = Set(request.borrowedApps.map(\.bundleIdentifier))
        let keepVisible = workspaceBundleIds.union(sharedBundleIds).union(borrowedBundleIds)
        let managedBundleIds = request.managedBundleIds

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
          func autoOpenIfNeeded(_ bundleId: String) {
            let instances = runningByBundle[bundleId] ?? []
            let hasVisibleWindow = instances.contains {
              onScreenOwnerPids.contains($0.processIdentifier)
            }
            if hasVisibleWindow { return }
            guard let url = NSWorkspace.shared
              .urlForApplication(withBundleIdentifier: bundleId)
            else {
              debugLog.log("Manager", "autoOpen \(bundleId): no app URL — skipped")
              return
            }
            debugLog.log("Manager", "autoOpen \(bundleId) (running=\(!instances.isEmpty))")
            let config = NSWorkspace.OpenConfiguration()
            // On a followAppFocus switch (setFocus=false) auto-open must not
            // steal the foreground: re-opening an already-running auto-open app
            // (e.g. Dia) would `openApplication`-activate it and raise it over
            // the app the user just switched to (Comet). Only a deliberate
            // switch (setFocus=true) lets a launched app come to front; there
            // the focus block still owns the final focus.
            config.activates = request.setFocus
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
              if let error {
                logger.error(
                  "open \(bundleId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
              }
            }
          }
          for app in request.workspace.apps where app.autoOpen {
            autoOpenIfNeeded(app.bundleIdentifier)
          }
          // Borrowed apps auto-open too (a borrowed workspace should bring its
          // apps up when summoned); performBorrow forces this on for a
          // scratchpad so all of its apps open.
          for app in request.borrowedApps where app.autoOpen {
            autoOpenIfNeeded(app.bundleIdentifier)
          }
          // Shared apps are present in every workspace, so an auto-open one is
          // (re)opened on any activation — this is what restores a minimized
          // shared app now that focus no longer de-minimizes it.
          for app in request.sharedApps where app.autoOpen {
            autoOpenIfNeeded(app.bundleIdentifier)
          }

          // Resolve the focus target among the workspace's own apps.
          // No pinned app ("Most recently used") → the MRU window's app;
          // last registered app only as a final fallback.
          let focusBundleId = request.workspace.appToFocusBundleId
            ?? request.windowKeyToFocus?.bundleId
            ?? request.workspace.apps.last?.bundleIdentifier
          let appsToShow = running.filter { keepVisible.contains($0.bundleIdentifier ?? "") }
          // The MRU focus target can be a transient (unregistered) window —
          // folded into the host's tree this session and restored on a borrow
          // return. It isn't in `keepVisible`/`appsToShow`, but it's on screen and
          // is the window the user last used, so honor it directly from the
          // running set instead of falling back to a registered app.
          let toFocus = appsToShow.first { $0.bundleIdentifier == focusBundleId }
            ?? request.windowKeyToFocus.flatMap { mru in
              running.first { $0.processIdentifier == mru.pid }
            }
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
            debugLog.log(
              "Manager",
              "focus \(toFocus.bundleIdentifier ?? "?") "
                + "(preferred=\(focusBundleId ?? "nil"))"
            )
            // Raise the exact MRU window when it belongs to the focused app;
            // otherwise fall back to the app's main window. For the MRU case,
            // force it to the front via SLPS: an accessory app's
            // NSRunningApplication.activate() doesn't reliably transfer the
            // frontmost application (especially for a window on a secondary
            // display), which left a workspace switch focused on the wrong app.
            if let mruKey = request.windowKeyToFocus,
               mruKey.bundleId == toFocus.bundleIdentifier {
              focusWindow(
                pid: toFocus.processIdentifier, windowID: mruKey.windowID, forceFront: true
              )
            } else {
              // No specific target window (no MRU / pin yet) — front the app's
              // main window via SLPS too. Plain activate() didn't transfer the
              // frontmost app on a secondary display, so a switch to e.g. a
              // Figma workspace there left keyboard focus (and window cycling)
              // on the previous display's workspace.
              focusAppFront(pid: toFocus.processIdentifier)
            }
          } else if request.setFocus {
            // Empty workspace — none of its apps are running, so nothing
            // above took focus. Hand it to Finder BEFORE the hide pass:
            // hiding the frontmost app with no successor makes macOS
            // reactivate (and *unhide*) the previously active app, so the
            // outgoing workspace's window resurfaces and followAppFocus
            // chases it right back ("switch to empty Coding bounced to
            // AI"). Finder is the app the hide pass below deliberately
            // leaves visible for exactly this empty-desktop case.
            debugLog.log(
              "Manager",
              "focus → Finder (no workspace app running, empty desktop)"
            )
            running.first { $0.isFinder }?
              .activate()
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
            // Borrow-scoped: only hide apps Tatami actually manages somewhere.
            // An app the user never registered — a floating utility, a system
            // dialog, a one-off window — is never ours to hide, so a borrow in
            // or release leaves it where it is. (Empty set → legacy hide-
            // everything for plain switches that don't supply the universe.)
            if !managedBundleIds.isEmpty, !managedBundleIds.contains(bundleId) { continue }
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

          debugLog.log(
            "Manager",
            "showHide ws=\(request.workspace.name) "
              + "display=\(request.targetDisplay?.name ?? "all") "
              + "shown=\(appsToShow.compactMap(\.bundleIdentifier)) hide=\(hiddenCount) "
              + "displayScoped=\(pidsOnTargetDisplay != nil)"
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
    let mainWindow = raw as! AXUIElement
    // Don't restore a window the user minimized (see raiseWindow).
    guard !axWindowIsMinimized(mainWindow) else { return }
    AXUIElementPerformAction(mainWindow, kAXRaiseAction as CFString)
  }

  /// Raise a specific window of this app by `CGWindowID` (the MRU focus
  /// target). Falls back to the main window when that window is gone —
  /// e.g. the MRU window was closed since it was last focused.
  fileprivate func raiseWindow(windowID: CGWindowID) {
    let app = AXUIElementCreateApplication(processIdentifier)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      app, kAXWindowsAttribute as CFString, &raw
    ) == .success,
      let windows = raw as? [AXUIElement]
    else {
      raiseMainWindow()
      return
    }
    for window in windows {
      var wid: CGWindowID = 0
      if _AXUIElementGetWindow(window, &wid) == .success, wid == windowID {
        // The MRU target is minimized → the user put it away; leave it.
        // Restoring is auto-open's job, not focus's.
        guard !axWindowIsMinimized(window) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return
      }
    }
    raiseMainWindow()
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "WorkspaceManager")
