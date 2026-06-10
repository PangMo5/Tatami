import AppKit
import ApplicationServices
import Dependencies
import OSLog
import ScreenCaptureKit

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

@MainActor
final class FloatingOverlayController {
  /// The only time-based values in the overlay — everything else is
  /// event- or verification-driven.
  private enum Timing {
    /// One display frame between raise-verification checks. Not a poll:
    /// the z-order has no change notification, so this is the finest
    /// granularity at which "did the raise composite?" can be observed.
    static let verifyStep: Duration = .milliseconds(16)
    /// Give up verifying after ~640 ms and keep the mirror up (truthful
    /// fallback) instead of exposing whatever sits behind it.
    static let verifyMaxSteps = 40
    /// Cosmetic fade for a verified hide — runs strictly after the
    /// z-order check, so its length is taste, not correctness.
    static let hideFade: TimeInterval = 0.08
  }

  private var panels: [WindowKey: NSPanel] = [:]
  private var captures: [WindowKey: WindowMirrorCapture] = [:]
  /// The set the reducer currently wants mirrored, updated synchronously
  /// by `setFloating` / `retainOnly` so `addMirrors` can re-validate each
  /// key after its `SCShareableContent` await gap. Without this, a key
  /// un-floated mid-await had no panel yet (removal no-oped) and came back
  /// as a ghost mirror with a live stream.
  private var desired: Set<WindowKey> = []
  /// Resolved `AXUIElement` per mirrored window — used to read the live
  /// frame and to raise the real window on interaction. AX calls are
  /// synchronous cross-process IPC and must stay on the main thread, so we
  /// resolve each window's element once and reuse it.
  private var axWindowCache: [WindowKey: AXUIElement] = [:]
  /// One `AXObserver` per owning pid for `kAXWindowMoved` / `kAXWindowResized`
  /// so mirrors follow their window event-driven, with no polling timer.
  private var axObservers: [pid_t: AXObserver] = [:]
  private var subscribed: Set<WindowKey> = []
  private var lastFrame: [WindowKey: NSRect] = [:]
  /// Mirrors currently hidden (click-through, stream stopped): the
  /// focused floating app's own windows, plus — while a float holds
  /// focus — sibling floats whose real window isn't covered by any tile,
  /// which therefore show themselves and need no mirror.
  private var suppressed: Set<WindowKey> = []
  /// Sibling mirrors dropped to `.normal` level just below the focused
  /// float's real window (tile-occluded siblings that must keep their
  /// mirror while a float holds focus). Demotion happens only *after*
  /// the focused window's raise is verified — ordering a panel against
  /// an unverified raise was the source of the old demotion blinks.
  private var demoted: Set<WindowKey> = []
  /// In-flight fade-out task per window.
  private var hideTasks: [WindowKey: Task<Void, Never>] = [:]
  /// `NSWorkspace.didActivateApplicationNotification` subscription — the
  /// single signal that flips mirrors between shown and suppressed.
  private var appActivationObserver: NSObjectProtocol?
  /// Global mouse-moved monitor, installed only while a mirror is
  /// suppressed. The cursor leaving the floating window is *the* race-free
  /// restore moment (Topit's timing): the window is still frontmost, so
  /// the mirror comes back over identical pixels, long before any focus
  /// change can drop the window behind something else.
  private var cursorMonitor: Any?
  /// Cursor-inside state per suppressed window — the restore acts on the
  /// inside→outside *edge*, not the level.
  private var cursorInside: [WindowKey: Bool] = [:]
  /// Listen-only mouse-down tap (created in `init`, enabled while panels
  /// exist): a click outside every suppressed floating window restores the
  /// mirrors *before* the clicked app raises. Covers the focus changes
  /// Tatami doesn't drive — the `focusWindow` hook can't see direct clicks,
  /// and the didActivate notification arrives after the z-order already
  /// changed (the intermittent "floating dips behind, then pops back up").
  private var clickTap: MirrorClickTap?
  /// Hover-handover gate, mirrored from the focus-follows-mouse setting
  /// (`setHoverActivation`). With FFM off, hovering a mirror must not move
  /// focus — only the already-focused app's mirror hands back on hover
  /// (no focus change involved); other mirrors hand over on click.
  var hoverActivates = true
  private let debugLog: DebugLogClient

  init(debugLog: DebugLogClient) {
    self.debugLog = debugLog
    clickTap = MirrorClickTap { [weak self] in
      Task { @MainActor [weak self] in self?.handleOutsideClick() }
    }
  }

  private var maxFPS: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

  // MARK: - Lifecycle

  func setFloating(_ windows: Set<WindowKey>) {
    desired = windows
    for key in panels.keys where !windows.contains(key) {
      removeWindow(key)
    }
    let toAdd = windows.filter { panels[$0] == nil }
    if !toAdd.isEmpty {
      Task { await addMirrors(for: toAdd) }
    }
    syncFrames()
  }

  /// Drop every mirror whose app isn't floating in the incoming workspace.
  func retainOnly(_ bundleIds: Set<String>) {
    desired = desired.filter { bundleIds.contains($0.bundleId) }
    for key in panels.keys where !bundleIds.contains(key.bundleId) {
      removeWindow(key)
    }
  }

  private func addMirrors(for keys: Set<WindowKey>) async {
    let content: SCShareableContent
    @Dependency(\.errorReporter) var reporter
    do {
      content = try await SCShareableContent.current
      reporter.resolve("Floating")
    } catch {
      logger.error(
        "SCShareableContent failed (screen-recording permission?): \(error.localizedDescription, privacy: .public)"
      )
      reporter.report(
        "Floating",
        "Floating mirrors unavailable — Screen Recording permission?",
        ErrorReportClient.describe(error)
      )
      return
    }
    var byID: [CGWindowID: SCWindow] = [:]
    for window in content.windows { byID[window.windowID] = window }

    for key in keys {
      // Re-check across the await gap: "already added" via `panels`, and
      // "no longer wanted" via `desired` (a `setFloating`/`retainOnly`
      // that ran mid-await couldn't remove a panel that didn't exist yet).
      guard desired.contains(key), panels[key] == nil else { continue }
      guard let scWindow = byID[key.windowID] else {
        logger.info("no SCWindow for \(key.bundleId, privacy: .public)#\(key.windowID)")
        continue
      }
      let capture = WindowMirrorCapture()
      let panel = makePanel(for: key, capture: capture)
      captures[key] = capture
      panels[key] = panel
      await capture.start(window: scWindow, maxFPS: maxFPS)
      // The mirrored app may already be frontmost (e.g. the user floated
      // the focused window) — start suppressed so the mirror doesn't cover
      // the live window they're using.
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == key.pid {
        suppressMirror(key)
      }
    }
    ensureActivationObserver()
    clickTap?.setEnabled(!panels.isEmpty)
    syncFrames()
  }

  private func makePanel(for key: WindowKey, capture: WindowMirrorCapture) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    // Above the tiles. `.nonactivatingPanel` + this level is what makes the
    // mirror sit on top without ever becoming the key window.
    panel.level = .floating
    // While shown, the mirror receives hover / click so it can hand off to
    // the real window — unlike the click-through marker dots.
    panel.ignoresMouseEvents = false
    // `.transient` keeps the mirror out of Mission Control / the app
    // switcher, where a fake duplicate window would look wrong.
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    let view = MirrorView(videoLayer: capture.videoLayer)
    // Touching the mirror = the user wants the real window. Activation is
    // all that happens here; the didActivateApplication notification then
    // suppresses the mirror once the raise actually lands.
    //
    // Suppressed gate: `ignoresMouseEvents` only stops *click* routing —
    // tracking-area mouseEntered still fires for a hidden, event-ignoring
    // panel. Without the gate, brushing the cursor across a hidden
    // mirror's frame (e.g. the overlap of two floats) hover-activated its
    // app and stole focus from the float the user was actually on.
    view.onHoverChange = { [weak self] hovering in
      // Demoted gate: tracking areas fire on geometry, not occlusion — a
      // demoted mirror tucked *below* the focused float's real window
      // still gets mouseEntered at their overlap, and must not react.
      guard let self, hovering,
            !self.suppressed.contains(key), !self.demoted.contains(key)
      else { return }
      // With focus-follows-mouse off, hover must not move focus (that
      // would be FFM in disguise, just for floats) — the mirror stays up
      // and scrolls forward via `onScroll`; focus moves on click. The
      // focused app's own mirror still hands back on hover: revealing the
      // real window of the app that already has focus moves no focus.
      guard self.hoverActivates
        || NSWorkspace.shared.frontmostApplication?.processIdentifier == key.pid
      else { return }
      self.activateRealWindow(key)
    }
    view.onClick = { [weak self] in
      guard let self, !self.suppressed.contains(key), !self.demoted.contains(key) else { return }
      self.activateRealWindow(key)
    }
    // Input parity with real windows: with FFM off the mirror sits under
    // the cursor, so scrolls, clicks, and drags land on the panel. Repost
    // each event to the owning app, tagged with the real window's id — a
    // bare posted event carries no window number, and an *inactive* app's
    // AppKit drops window-less mouse events instead of hit-testing them
    // (scrolls only started working after a click, i.e. once the handover
    // made them native). The real window sits at exactly the mirror's
    // frame, so the event's global location needs no translation.
    view.onForwardEvent = { event in
      guard let cg = event.cgEvent?.copy() else { return }
      // 51 = the CGS event-record window id (the field the window server
      // stamps on routed events; same one yabai sets on synthetic clicks).
      cg.setIntegerValueField(
        CGEventField(rawValue: 51)!, value: Int64(key.windowID)
      )
      cg.postToPid(key.pid)
    }
    panel.contentView = view
    return panel
  }

  /// Drop a window's mirror panel, capture stream, and AX subscription.
  private func removeWindow(_ key: WindowKey) {
    if subscribed.remove(key) != nil,
       let element = axWindowCache[key],
       let observer = axObservers[key.pid]
    {
      AXObserverRemoveNotification(observer, element, kAXWindowMovedNotification as CFString)
      AXObserverRemoveNotification(observer, element, kAXWindowResizedNotification as CFString)
    }
    captures[key]?.stop()
    captures.removeValue(forKey: key)
    if let panel = panels[key] {
      MirrorWindowRegistry.shared.set(mirror: CGWindowID(panel.windowNumber), target: nil)
      panel.orderOut(nil)
    }
    panels.removeValue(forKey: key)
    lastFrame.removeValue(forKey: key)
    axWindowCache.removeValue(forKey: key)
    hideTasks.removeValue(forKey: key)?.cancel()
    suppressed.remove(key)
    demoted.remove(key)
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    removeCursorMonitorIfIdle()
    // Don't let a stale focused-float pid (whose panels just went away,
    // e.g. on a workspace switch) gate the next workspace's mirrors.
    if let pid = focusedFloatPid, !panels.keys.contains(where: { $0.pid == pid }) {
      focusedFloatPid = nil
    }
    if panels.isEmpty { clickTap?.setEnabled(false) }
    if !panels.keys.contains(where: { $0.pid == key.pid }),
       let observer = axObservers.removeValue(forKey: key.pid)
    {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .defaultMode
      )
    }
    if panels.isEmpty { removeActivationObserver() }
  }

  // MARK: - Activation-driven visibility

  private func ensureActivationObserver() {
    guard appActivationObserver == nil, !panels.isEmpty else { return }
    appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
        .processIdentifier
      guard let pid else { return }
      // Delivered on the main queue (`queue: .main`), so hopping straight
      // onto the main actor is sound.
      MainActor.assumeIsolated { self?.handleAppActivated(pid) }
    }
  }

  private func removeActivationObserver() {
    if let observer = appActivationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      appActivationObserver = nil
    }
  }

  /// Floating pids by focus recency, most recent first. Mirrors stack in
  /// this order: the focused floating app on top, then the last-focused
  /// floating app, and so on.
  private var floatingMRU: [pid_t] = []

  /// The active app changed — mirrors of the now-active app hide. What
  /// happens to the *other* mirrors depends on who took focus:
  ///
  ///   * a non-floating app → it raises above everything at the normal
  ///     level, so every float needs its mirror back.
  ///   * a floating app → sibling floats whose real window isn't covered
  ///     by a tile need no mirror either: the real windows show
  ///     themselves and stack natively by activation recency. With every
  ///     mirror hidden there is no stream (recording indicator clears),
  ///     no ghost panel trailing a drag, and no hidden panel for hover
  ///     events to fall through to. Only a sibling genuinely covered by
  ///     a tile keeps its mirror.
  private func handleAppActivated(_ pid: pid_t) {
    debugLog.log("FocusDiag", "didActivate pid=\(pid)")
    noteFocus(pid)
    let targetIsFloating = panels.keys.contains { $0.pid == pid }
    for key in Array(panels.keys) where key.pid != pid {
      // A dead window's mirror is torn down, never shown: quitting a
      // floating app fires this activation (macOS focuses the next app)
      // *before* the reducer's terminate-sync removes the panel, which
      // used to resurrect the mirror as a frozen ghost.
      guard windowExists(key) else {
        removeWindow(key)
        continue
      }
      if targetIsFloating, isVisuallyOnTop(key) {
        suppressMirror(key)
      } else {
        restoreMirror(key)
        // Focus has moved — force the panel opaque even if a cursor-exit
        // restore is still waiting on its first frame.
        showPanel(key)
      }
    }
    for key in Array(panels.keys) where key.pid == pid {
      suppressMirror(key)
    }
    applyStackOrder(liftDemoted: !targetIsFloating)
  }

  /// Tatami is about to move focus to `pid`'s window (`focusWindow` hook).
  /// Restore the mirrors that need to be up *now*, before the activation,
  /// so they're already painted when the floating window drops behind the
  /// new focus — the didActivate notification alone arrives one beat too
  /// late. Returns whether any mirror was actually restored: the caller
  /// then delays the activation a beat so the restore commits first.
  func handleWillFocus(_ pid: pid_t) -> Bool {
    noteFocus(pid)
    let targetIsFloating = panels.keys.contains { $0.pid == pid }
    var needsCommit = false
    for key in Array(panels.keys) where key.pid != pid {
      // Same dead-window rule as didActivate.
      guard windowExists(key) else {
        removeWindow(key)
        continue
      }
      // Same occlusion rule as didActivate: when focus moves to a float,
      // an unoccluded sibling float keeps showing its real window — no
      // mirror needed.
      if targetIsFloating, isVisuallyOnTop(key) {
        suppressMirror(key)
        continue
      }
      // "Needs a commit beat" = this turn is flipping the panel visible.
      // Checking `suppressed` here is NOT equivalent: the cursor-exit
      // restore un-suppresses first and then waits for a fresh frame with
      // the panel still transparent — exactly the window in which the
      // focus change races us.
      if let panel = panels[key], panel.alphaValue < 1 { needsCommit = true }
      restoreMirror(key)
      showPanel(key)
    }
    applyStackOrder(liftDemoted: !targetIsFloating)
    return needsCommit
  }

  /// pid of the floating app that currently holds focus, if any. Gates
  /// the cursor-exit restore: only the focused float's mirror returns
  /// when the cursor leaves it — a hidden unoccluded sibling must not
  /// pop its mirror back just because the cursor brushed across it.
  private var focusedFloatPid: pid_t?

  /// Record `pid` as the focus target: track whether a float holds focus
  /// and bump it in the floating recency order.
  private func noteFocus(_ pid: pid_t) {
    let isFloating = panels.keys.contains { $0.pid == pid }
    focusedFloatPid = isFloating ? pid : nil
    guard isFloating else { return }
    floatingMRU.removeAll { $0 == pid }
    floatingMRU.insert(pid, at: 0)
  }

  /// Stack the floating band by focus recency — most recently focused on
  /// top. `liftDemoted` controls whether previously demoted mirrors come
  /// back up to the floating band: true when a non-floating app takes
  /// focus (every mirror must cover its window again), false while a
  /// float keeps focus (demoted siblings stay tucked under it; lifting
  /// them here only to re-demote after the next raise verification would
  /// flap them across levels).
  private func applyStackOrder(liftDemoted: Bool = true) {
    if liftDemoted { demoted.removeAll() }
    let ordered = panels.keys.sorted { mruIndex($0.pid) < mruIndex($1.pid) }
    var previousNumber: Int?
    for key in ordered {
      guard let panel = panels[key], !suppressed.contains(key) else { continue }
      if demoted.contains(key) { continue }
      panel.level = .floating
      if let previousNumber {
        panel.order(.below, relativeTo: previousNumber)
      } else if !panel.isVisible {
        panel.orderFrontRegardless()
      }
      previousNumber = panel.windowNumber
    }
  }

  /// Slot every still-visible sibling mirror at `.normal` level directly
  /// below `key`'s real window, in focus-recency order: focused float >
  /// tile-occluded sibling mirrors > tiles. Called only after `key`'s
  /// raise has been verified (`order(.below relativeTo:)` accepts another
  /// app's window number). Also takes these mirrors out of the hover
  /// path: sitting below the focused window, they no longer swallow the
  /// cursor at overlaps.
  private func demoteVisibleSiblings(below key: WindowKey) {
    let siblings = panels.keys
      .filter { $0.pid != key.pid && !suppressed.contains($0) }
      .sorted { mruIndex($0.pid) < mruIndex($1.pid) }
    var previousNumber: Int?
    for sibling in siblings {
      guard let panel = panels[sibling] else { continue }
      demoted.insert(sibling)
      panel.level = .normal
      panel.order(.below, relativeTo: previousNumber ?? Int(key.windowID))
      previousNumber = panel.windowNumber
    }
  }

  private func mruIndex(_ pid: pid_t) -> Int {
    floatingMRU.firstIndex(of: pid) ?? .max
  }

  /// Per-window maintenance used by geometry refreshes and the cursor-exit
  /// restore; full recency stacking happens in `applyStackOrder`. Demoted
  /// mirrors are left alone — a geometry event must not lift them back
  /// over the focused float — and hidden (suppressed) panels have nothing
  /// to order.
  private func applyOrdering(_ key: WindowKey) {
    guard let panel = panels[key],
          !demoted.contains(key),
          !suppressed.contains(key)
    else { return }
    panel.level = .floating
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  /// Hide `key`'s mirror: its real window is (or is about to be) showing
  /// itself — either its app took focus, or a sibling float took focus
  /// while this window sits unoccluded above the tiles. Goes
  /// click-through immediately; the fade waits until the real window is
  /// *verifiably* not covered by any tile. There is no notification for
  /// "raise composited" — a blind timer raced slow apps' raises (Xcode)
  /// and let the tile underneath flash through; the bounded per-frame
  /// z-order check is the only reliable gate.
  private func suppressMirror(_ key: WindowKey) {
    guard !suppressed.contains(key), let panel = panels[key] else { return }
    suppressed.insert(key)
    cursorInside[key] = panel.frame.contains(NSEvent.mouseLocation)
    syncSuppressedFrames()
    panel.ignoresMouseEvents = true
    ensureCursorMonitor()
    hideTasks.removeValue(forKey: key)?.cancel()
    hideTasks[key] = Task { @MainActor [weak self] in
      // Wait for the raise to land (almost always 0–2 iterations). Bail
      // out — mirror stays up, truthfully — if it never does.
      var raised = false
      for _ in 0..<Timing.verifyMaxSteps {
        guard let self, !Task.isCancelled, self.suppressed.contains(key) else { return }
        if self.isVisuallyOnTop(key) {
          raised = true
          break
        }
        try? await Task.sleep(for: Timing.verifyStep)
      }
      guard raised, let self, !Task.isCancelled, self.suppressed.contains(key) else { return }
      // The focused window is verifiably above the tiles — now (and only
      // now) it's safe to slot still-mirrored siblings underneath it.
      if key.pid == self.focusedFloatPid {
        self.demoteVisibleSiblings(below: key)
      }
      await NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = Timing.hideFade
        panel.animator().alphaValue = 0
      }
      guard !Task.isCancelled, self.suppressed.contains(key) else { return }
      // Back the layer with a still of the last frame first: a focus
      // change can force this panel visible before the stream restarts,
      // and an imageless layer would let whatever raised behind it show
      // through.
      if let capture = self.captures[key],
         let still = capture.stillImage(),
         let view = panel.contentView as? MirrorView
      {
        view.setStill(still)
      }
      // Stop the stream: it keeps the screen-recording indicator lit, and
      // while the mirror is hidden nothing is painted.
      self.captures[key]?.stop()
    }
  }

  /// No *non-floating* window of another app overlaps `key` above it —
  /// i.e. hiding the mirror would reveal the real window, not a tile.
  /// Floating apps' own windows are deliberately excluded: while a float
  /// holds focus, the floats sort themselves through native activation
  /// z-order, so a sibling float above is never a reason to keep a mirror.
  private func isVisuallyOnTop(_ key: WindowKey) -> Bool {
    guard let above = CGWindowListCopyWindowInfo(
      .optionOnScreenAboveWindow, key.windowID
    ) as? [[String: Any]] else { return true }
    guard let frame = lastFrame[key].map(AXWindowGeometry.flipToCG) else { return true }
    let floatingPids = Set(panels.keys.map(\.pid))
    for entry in above {
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
            let owner = entry[kCGWindowOwnerPID as String] as? pid_t,
            !floatingPids.contains(owner),
            ((entry[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
      else { continue }
      let rect = CGRect(
        x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
        width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
      )
      if rect.intersects(frame) { return false }
    }
    return true
  }

  /// Show `key`'s mirror again.
  ///
  /// `waitForFrame` is for the cursor-exit restore, where the real window
  /// is still frontmost: nothing is racing, so hold the panel until the
  /// resumed stream delivers a fresh frame and the swap is invisible. The
  /// focus-driven paths (hook / notification / click tap) pass `false` —
  /// there a stale frame beats a missing mirror.
  /// `onShown` (if given) runs right after the panel turns opaque — i.e.
  /// after the first fresh frame on the `waitForFrame` path — so callers
  /// can sequence z-order work against the moment the mirror is visible.
  private func restoreMirror(
    _ key: WindowKey,
    waitForFrame: Bool = false,
    onShown: (() -> Void)? = nil
  ) {
    guard suppressed.contains(key) else { return }
    // Funnel for every restore path (focus handlers, click tap, cursor
    // exit): a dead window's mirror never comes back — tear it down. The
    // cursor-exit path in particular can race the terminate cleanup and
    // used to resurrect a quit app's mirror on the first mouse move.
    guard windowExists(key) else {
      removeWindow(key)
      onShown?()
      return
    }
    suppressed.remove(key)
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    hideTasks.removeValue(forKey: key)?.cancel()
    removeCursorMonitorIfIdle()
    guard let panel = panels[key] else {
      onShown?()
      return
    }
    panel.ignoresMouseEvents = false
    let capture = captures[key]
    if waitForFrame, let capture, !capture.isRunning {
      Task {
        await capture.resume(maxFPS: maxFPS) { [weak self] in
          self?.showPanel(key)
          onShown?()
        }
      }
    } else {
      showPanel(key)
      if let capture, !capture.isRunning {
        Task { await capture.resume(maxFPS: maxFPS) }
      }
      onShown?()
    }
  }

  /// Make `key`'s panel opaque now. Direct model write — no animator — so
  /// it lands within the same frame as the pre-focus hook; the
  /// zero-duration animator pass stomps a possibly in-flight fade-out so it
  /// can't finish later and strand the mirror invisible. No-op while the
  /// key is (re-)suppressed.
  private func showPanel(_ key: WindowKey) {
    guard !suppressed.contains(key), let panel = panels[key] else { return }
    panel.alphaValue = 1
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0
      panel.animator().alphaValue = 1
    }
  }

  // MARK: - Cursor-exit restore

  private func ensureCursorMonitor() {
    guard cursorMonitor == nil else { return }
    cursorMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
      Task { @MainActor [weak self] in self?.handleCursorMoved(NSEvent.mouseLocation) }
    }
  }

  private func removeCursorMonitorIfIdle() {
    guard suppressed.isEmpty, let monitor = cursorMonitor else { return }
    NSEvent.removeMonitor(monitor)
    cursorMonitor = nil
  }

  /// The cursor left a suppressed (focused) floating window. Its real
  /// window is still frontmost at this instant, so restoring the mirror
  /// now is invisible — and by the time the focus actually moves (FFM, a
  /// click, a hotkey) the mirror is already up. This is what removes the
  /// "floating dips behind for a moment" race: focus-time restores can
  /// never beat the z-order change; cursor-exit restores don't have to.
  private func handleCursorMoved(_ cursor: NSPoint) {
    for key in Array(suppressed) {
      // Only the *focused* float swaps back to its mirror when the cursor
      // leaves it. A hidden unoccluded sibling stays hidden — its real
      // window shows itself, and brushing the cursor across it must not
      // pop a mirror.
      guard key.pid == focusedFloatPid, let panel = panels[key] else { continue }
      let inside = panel.frame.contains(cursor)
      let wasInside = cursorInside[key] ?? true
      cursorInside[key] = inside
      if wasInside, !inside {
        debugLog.log("FocusDiag", "cursor-exit restore \(key.bundleId)#\(key.windowID)")
        // Lift demoted siblings back to the floating band on cursor exit —
        // the last race-free moment before a possible native click-focus
        // on a tile: a demoted (.normal) mirror left below would get
        // raised over by the clicked window before the mouse-down tap's
        // main-actor hop lands (the "sibling dips behind, pops back up"
        // flicker with focus-follows-mouse off). But only *after* this
        // mirror is opaque: lifting in the same beat puts a sibling's
        // .floating mirror above the still-uncovered real window
        // (.normal), visibly dropping the focused float behind the
        // sibling at their overlap until the first fresh frame lands.
        restoreMirror(key, waitForFrame: true) { [weak self] in
          self?.applyStackOrder()
        }
      }
    }
  }

  /// Bring the mirrored window's real counterpart to the front and focus it.
  private func activateRealWindow(_ key: WindowKey) {
    debugLog.log("FocusDiag", "mirror hover/click activate \(key.bundleId)#\(key.windowID)")
    raiseAXWindow(key)
    NSRunningApplication(processIdentifier: key.pid)?
      .activate(options: [.activateIgnoringOtherApps])
    // An already-frontmost app fires no didActivate notification — settle
    // the suppression state directly (e.g. a mirror restored by a menu-bar
    // click while its app stayed active would otherwise stay up as an
    // event-eating picture over the live window).
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == key.pid {
      handleAppActivated(key.pid)
    }
  }

  /// Snap a drifted real window back to its mirror's frame and AX-raise it.
  /// In no-park mode the real window already sits at the mirror's frame, so
  /// the snap only writes when the two have actually drifted — a redundant
  /// AX move/resize makes some apps redraw, which reads as a flicker.
  private func raiseAXWindow(_ key: WindowKey) {
    ensureAXCacheCoversPanels()
    guard let element = axWindowCache[key] else { return }
    if let cocoa = lastFrame[key] {
      let target = AXWindowGeometry.flipToCG(cocoa)
      let current = AXWindowGeometry.frame(of: element)
      let drifted = current.map {
        abs($0.minX - target.minX) > 1 || abs($0.minY - target.minY) > 1
          || abs($0.width - target.width) > 1 || abs($0.height - target.height) > 1
      } ?? true
      if drifted { AXWindowGeometry.setFrame(element, to: target) }
    }
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
  }

  /// A mouse-down landed outside every suppressed floating window — focus
  /// is about to move to whatever was clicked. Put the mirrors back up
  /// ahead of the raise; the didActivate notification settles final state.
  private func handleOutsideClick() {
    guard !suppressed.isEmpty else { return }
    focusedFloatPid = nil
    for key in Array(panels.keys) {
      guard windowExists(key) else {
        removeWindow(key)
        continue
      }
      restoreMirror(key)
      showPanel(key)
    }
    applyStackOrder()
  }

  /// The mirrored window is still on screen (cheap single-window
  /// CGWindowList lookup).
  private func windowExists(_ key: WindowKey) -> Bool {
    let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.windowID)
      as? [[String: Any]]
    return !(list ?? []).isEmpty
  }

  /// Publish the suppressed windows' frames (CG coordinates) for the
  /// mouse-down tap, which runs off the main thread.
  private func syncSuppressedFrames() {
    var frames: [CGWindowID: CGRect] = [:]
    for key in suppressed {
      if let cocoa = lastFrame[key] { frames[key.windowID] = AXWindowGeometry.flipToCG(cocoa) }
    }
    MirrorWindowRegistry.shared.setSuppressedFrames(frames)
  }

  // MARK: - Frame sync

  /// Full pass: resolve elements, (re)subscribe AX geometry notifications,
  /// then position every mirror. Called on target changes; the per-window AX
  /// observer drives every reposition in between.
  private func syncFrames() {
    ensureAXCacheCoversPanels()
    ensureSubscriptions()
    for key in Array(panels.keys) { refresh(key) }
  }

  /// Position + (re)size one mirror from the live AX frame of its window.
  private func refresh(_ key: WindowKey) {
    guard let panel = panels[key], let element = axWindowCache[key] else { return }
    guard let cg = AXWindowGeometry.frame(of: element) else { return }
    let cocoa = AXWindowGeometry.flipToCocoa(cg)
    if lastFrame[key] != cocoa {
      let previous = lastFrame[key]
      let sizeChanged = previous == nil
        || abs(previous!.width - cocoa.width) > 0.5
        || abs(previous!.height - cocoa.height) > 0.5
      panel.setFrame(cocoa, display: true, animate: false)
      lastFrame[key] = cocoa
      if suppressed.contains(key) { syncSuppressedFrames() }
      // Keep the capture surface in sync even while suppressed, so the
      // mirror is pixel-correct the moment it comes back.
      if sizeChanged, let capture = captures[key] {
        capture.updateSize(
          width: cg.width, height: cg.height,
          scale: panel.backingScaleFactor, maxFPS: maxFPS
        )
      }
    }
    applyOrdering(key)
    // Window number is only valid once ordered in; (re)registering is
    // idempotent. Focus-follows-mouse uses this to focus the mirrored
    // window when the cursor sits on the mirror.
    MirrorWindowRegistry.shared.set(
      mirror: CGWindowID(panel.windowNumber),
      target: .init(pid: key.pid, windowID: key.windowID)
    )
  }

  fileprivate func handleGeometryChange(windowID: CGWindowID) {
    guard let key = panels.keys.first(where: { $0.windowID == windowID }) else { return }
    refresh(key)
  }

  // MARK: - AX subscriptions

  private func ensureSubscriptions() {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for (key, element) in axWindowCache where panels[key] != nil && !subscribed.contains(key) {
      guard let observer = observer(for: key.pid) else { continue }
      AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, refcon)
      AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, refcon)
      subscribed.insert(key)
    }
  }

  private func observer(for pid: pid_t) -> AXObserver? {
    if let existing = axObservers[pid] { return existing }
    var observer: AXObserver?
    guard AXObserverCreate(pid, floatingOverlayAXCallback, &observer) == .success,
          let observer
    else { return nil }
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .defaultMode
    )
    axObservers[pid] = observer
    return observer
  }

  /// Resolve every still-unresolved mirrored window to its `AXUIElement` in
  /// one `kAXWindowsAttribute` enumeration per owning app.
  private func ensureAXCacheCoversPanels() {
    let missing = panels.keys.filter { axWindowCache[$0] == nil }
    guard !missing.isEmpty else { return }
    let byPid = Dictionary(grouping: missing, by: { $0.pid })
    for (pid, keys) in byPid {
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(app, 0.25)
      var raw: CFTypeRef?
      guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
            let windows = raw as? [AXUIElement]
      else { continue }
      var widToElement: [CGWindowID: AXUIElement] = [:]
      for window in windows {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
          widToElement[wid] = window
        }
      }
      for key in keys where widToElement[key.windowID] != nil {
        axWindowCache[key] = widToElement[key.windowID]
      }
    }
  }

}

/// `AXObserver` C callback for floating-mirror geometry. The run-loop source
/// is on the main run loop, so this already runs on the main thread and hops
/// straight onto the MainActor-isolated controller. Only the window id (a
/// Sendable scalar) is read from the non-Sendable element before the hop.
private func floatingOverlayAXCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  var windowID: CGWindowID = 0
  guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return }
  let controller = Unmanaged<FloatingOverlayController>.fromOpaque(refcon).takeUnretainedValue()
  MainActor.assumeIsolated {
    controller.handleGeometryChange(windowID: windowID)
  }
}
