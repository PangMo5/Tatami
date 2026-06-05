import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import OSLog
import ScreenCaptureKit

/// Keeps "floating" windows visually on top of the tiled layout without
/// SIP, by mirroring each one into an always-on-top panel of our own
/// (the Topit / Floaty technique — see `WindowMirrorCapture`).
///
/// The reducer resolves the floating apps to live `WindowKey`s and pushes
/// the set here after every activation / sync.
///
/// Visibility model — driven by ONE signal, app activation:
///
///   * floating app NOT active → its real window sits behind the tiles,
///     so the mirror is shown (and receives hover/click, which activates
///     the real app).
///   * floating app active → macOS has its real windows on top anyway,
///     so the mirror hides and goes click-through; the user interacts
///     with the real window directly (move, resize, type, drag).
///
/// Cursor position deliberately plays no part in hiding/showing: a fully
/// transparent panel stops receiving tracking events, so any cursor-based
/// scheme oscillates (hide → spurious mouseExited → show → mouseEntered →
/// hide …) — that was the "blinking" bug.
@DependencyClient
public struct FloatingOverlayClient: Sendable {
  /// Replace the set of windows mirrored on top. Pass `[]` to tear every
  /// mirror down (e.g. a workspace with no floating apps).
  public var setFloating: @Sendable (_ windows: Set<WindowKey>) -> Void
  /// Immediately tear down every mirror whose app is not in `bundleIds`.
  /// Called at the *start* of a workspace switch, in the same beat as the
  /// hide pass, so the outgoing workspace's mirrors don't linger through
  /// the tile pass and vanish noticeably later than the windows they
  /// mirror (`setFloating` reconciles the full set afterwards).
  public var retainOnly: @Sendable (_ bundleIds: Set<String>) -> Void
}

extension FloatingOverlayClient: DependencyKey {
  public static let liveValue: FloatingOverlayClient = MainActor.assumeIsolated {
    let controller = FloatingOverlayController()
    // Pre-focus hook: `focusWindow` (always main-actor) announces the pid
    // it is about to focus, so mirrors restore *before* the z-order change
    // instead of one notification later. Returns whether anything was
    // restored, so the caller can let it commit before activating.
    MirrorWindowRegistry.shared.setWillFocusHandler { pid in
      MainActor.assumeIsolated { controller.handleWillFocus(pid) }
    }
    return FloatingOverlayClient(
      setFloating: { windows in
        Task { @MainActor in controller.setFloating(windows) }
      },
      retainOnly: { bundleIds in
        Task { @MainActor in controller.retainOnly(bundleIds) }
      }
    )
  }

  public static let testValue = FloatingOverlayClient()
  public static let previewValue = testValue
}

extension DependencyValues {
  public var floatingOverlay: FloatingOverlayClient {
    get { self[FloatingOverlayClient.self] }
    set { self[FloatingOverlayClient.self] = newValue }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

@MainActor
private final class FloatingOverlayController {
  private var panels: [WindowKey: NSPanel] = [:]
  private var captures: [WindowKey: WindowMirrorCapture] = [:]
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
  /// Mirrors whose app is the active one. Hard-suppressed mirrors are
  /// hidden (stream stopped); soft-suppressed ones stay visible but
  /// click-through — see `suppressMirror`.
  private var suppressed: Set<WindowKey> = []
  /// The subset of `suppressed` kept visible: when another floating
  /// mirror overlaps this window, hiding ours would force ordering the
  /// `.normal`-level demotion dance against real-window z-changes, which
  /// is unwinnable (raises composite later than every signal we get).
  /// Keeping the focused float's live mirror on top of OUR floating band
  /// solves the stacking entirely within windows we control.
  private var softSuppressed: Set<WindowKey> = []
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

  init() {
    clickTap = MirrorClickTap { [weak self] in
      Task { @MainActor [weak self] in self?.handleOutsideClick() }
    }
  }

  private var maxFPS: Int { NSScreen.main?.maximumFramesPerSecond ?? 60 }

  // MARK: - Lifecycle

  func setFloating(_ windows: Set<WindowKey>) {
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
    for key in panels.keys where !bundleIds.contains(key.bundleId) {
      removeWindow(key)
    }
  }

  private func addMirrors(for keys: Set<WindowKey>) async {
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.current
    } catch {
      logger.error(
        "SCShareableContent failed (screen-recording permission?): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    var byID: [CGWindowID: SCWindow] = [:]
    for window in content.windows { byID[window.windowID] = window }

    for key in keys {
      guard panels[key] == nil else { continue }  // re-check across the await gap
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
    view.onHoverChange = { [weak self] hovering in
      if hovering { self?.activateRealWindow(key) }
    }
    view.onClick = { [weak self] in self?.activateRealWindow(key) }
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
    softSuppressed.remove(key)
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    removeCursorMonitorIfIdle()
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

  /// The active app changed — mirrors of the now-active app hide, every
  /// other mirror comes back (its real window just dropped behind whatever
  /// was focused).
  private func handleAppActivated(_ pid: pid_t) {
    noteFocus(pid)
    for key in panels.keys {
      if key.pid == pid {
        suppressMirror(key)
      } else {
        restoreMirror(key)
        // Focus has moved — force the panel opaque even if a cursor-exit
        // restore is still waiting on its first frame.
        showPanel(key)
      }
    }
    applyStackOrder()
  }

  /// Tatami is about to move focus to `pid`'s window (`focusWindow` hook).
  /// Restore the other mirrors *now*, before the activation, so they're
  /// already painted when the floating window drops behind the new focus —
  /// the didActivate notification alone arrives one beat too late. Returns
  /// whether any mirror was actually restored: the caller then delays the
  /// activation a beat so the restore commits first.
  fileprivate func handleWillFocus(_ pid: pid_t) -> Bool {
    noteFocus(pid)
    var needsCommit = false
    for key in panels.keys where key.pid != pid {
      // "Needs a commit beat" = this turn is flipping the panel visible.
      // Checking `suppressed` here is NOT equivalent: the cursor-exit
      // restore un-suppresses first and then waits for a fresh frame with
      // the panel still transparent — exactly the window in which the
      // focus change races us.
      if let panel = panels[key], panel.alphaValue < 1 { needsCommit = true }
      restoreMirror(key)
      showPanel(key)
    }
    applyStackOrder()
    return needsCommit
  }

  /// Record `pid` as the focus target: bump it in the floating recency
  /// order (no-op for non-floating apps).
  private func noteFocus(_ pid: pid_t) {
    guard panels.keys.contains(where: { $0.pid == pid }) else { return }
    floatingMRU.removeAll { $0 == pid }
    floatingMRU.insert(pid, at: 0)
  }

  /// Stack the floating band by focus recency — most recently focused on
  /// top (the focused float's own mirror, when soft-suppressed, included).
  /// Mirrors never leave the `.floating` level: every attempt to express
  /// "focused float above the others" through `.normal`-level demotion
  /// raced real-window raises (which composite later than every signal we
  /// get) and blinked.
  private func applyStackOrder() {
    let ordered = panels.keys.sorted { mruIndex($0.pid) < mruIndex($1.pid) }
    var previousNumber: Int?
    for key in ordered {
      guard let panel = panels[key],
            !suppressed.contains(key) || softSuppressed.contains(key)
      else { continue }
      panel.level = .floating
      if let previousNumber {
        panel.order(.below, relativeTo: previousNumber)
      } else if !panel.isVisible {
        panel.orderFrontRegardless()
      }
      previousNumber = panel.windowNumber
    }
  }

  private func mruIndex(_ pid: pid_t) -> Int {
    floatingMRU.firstIndex(of: pid) ?? .max
  }

  /// Per-window maintenance used by geometry refreshes and the cursor-exit
  /// restore; full recency stacking happens in `applyStackOrder`.
  private func applyOrdering(_ key: WindowKey) {
    guard let panel = panels[key] else { return }
    panel.level = .floating
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  /// `key`'s app just became active. Always goes click-through so the
  /// user interacts with the real window; whether the mirror also *hides*
  /// depends on what hiding would cost:
  ///
  ///   * Soft — another visible floating mirror overlaps this window:
  ///     keep the live mirror up, stacked on top of the floating band.
  ///     Hiding it would force expressing "focused float above the other
  ///     mirrors" against real-window z-order, which is unwinnable.
  ///   * Hard — sole / non-overlapping float: fade out and stop the
  ///     stream (clears the recording indicator), but only after the real
  ///     window is *verifiably* above everything that could show through.
  ///     There is no notification for "raise composited" — a blind timer
  ///     raced slow apps' raises (Xcode) and let the tile underneath
  ///     flash through; the bounded per-frame z-order check is the only
  ///     reliable gate.
  private func suppressMirror(_ key: WindowKey) {
    guard !suppressed.contains(key), let panel = panels[key] else { return }
    suppressed.insert(key)
    cursorInside[key] = panel.frame.contains(NSEvent.mouseLocation)
    syncSuppressedFrames()
    panel.ignoresMouseEvents = true
    ensureCursorMonitor()
    hideTasks.removeValue(forKey: key)?.cancel()
    if overlapsOtherVisibleMirror(key) {
      softSuppressed.insert(key)
      applyStackOrder()
      return
    }
    hideTasks[key] = Task { @MainActor [weak self] in
      // Wait for the raise to land (≤ ~600 ms, one display frame per
      // step; almost always 0–2 iterations). Bail out — mirror stays up,
      // truthfully — if it never does.
      var raised = false
      for _ in 0..<40 {
        guard let self, !Task.isCancelled, self.suppressed.contains(key) else { return }
        if self.isVisuallyOnTop(key) {
          raised = true
          break
        }
        try? await Task.sleep(for: .milliseconds(16))
      }
      guard raised, let self, !Task.isCancelled, self.suppressed.contains(key) else { return }
      await NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.08
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

  /// Another floating app's mirror is visible and overlaps `key`'s window.
  private func overlapsOtherVisibleMirror(_ key: WindowKey) -> Bool {
    guard let frame = lastFrame[key] else { return false }
    return panels.contains { other, panel in
      other.pid != key.pid
        && (!suppressed.contains(other) || softSuppressed.contains(other))
        && panel.alphaValue > 0
        && panel.frame.intersects(frame)
    }
  }

  /// No other app's normal-level window overlaps `key` above it — i.e.
  /// hiding the mirror would reveal the real window, not something else.
  private func isVisuallyOnTop(_ key: WindowKey) -> Bool {
    guard let above = CGWindowListCopyWindowInfo(
      .optionOnScreenAboveWindow, key.windowID
    ) as? [[String: Any]] else { return true }
    guard let frame = lastFrame[key].map(flipToCG) else { return true }
    for entry in above {
      guard (entry[kCGWindowLayer as String] as? Int) == 0,
            (entry[kCGWindowOwnerPID as String] as? pid_t) != key.pid,
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
  private func restoreMirror(_ key: WindowKey, waitForFrame: Bool = false) {
    guard suppressed.remove(key) != nil else { return }
    let wasSoft = softSuppressed.remove(key) != nil
    cursorInside.removeValue(forKey: key)
    syncSuppressedFrames()
    hideTasks.removeValue(forKey: key)?.cancel()
    removeCursorMonitorIfIdle()
    guard let panel = panels[key] else { return }
    panel.ignoresMouseEvents = false
    // A soft-suppressed mirror never hid and its stream never stopped —
    // flipping the events back on is the whole restore.
    if wasSoft { return }
    let capture = captures[key]
    if waitForFrame, let capture, !capture.isRunning {
      Task {
        await capture.resume(maxFPS: maxFPS) { [weak self] in
          self?.showPanel(key)
        }
      }
    } else {
      showPanel(key)
      if let capture, !capture.isRunning {
        Task { await capture.resume(maxFPS: maxFPS) }
      }
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
      // Soft-suppressed mirrors are already visible — nothing to restore.
      guard !softSuppressed.contains(key), let panel = panels[key] else { continue }
      let inside = panel.frame.contains(cursor)
      let wasInside = cursorInside[key] ?? true
      cursorInside[key] = inside
      if wasInside, !inside {
        restoreMirror(key, waitForFrame: true)
        applyOrdering(key)
      }
    }
  }

  /// Bring the mirrored window's real counterpart to the front and focus it.
  /// In no-park mode the real window already sits at the mirror's frame, so
  /// the snap only writes when the two have actually drifted — a redundant
  /// AX move/resize makes some apps redraw, which reads as a flicker.
  private func activateRealWindow(_ key: WindowKey) {
    ensureAXCacheCoversPanels()
    if let element = axWindowCache[key] {
      if let cocoa = lastFrame[key] {
        let target = flipToCG(cocoa)
        let current = axFrame(of: element)
        let drifted = current.map {
          abs($0.minX - target.minX) > 1 || abs($0.minY - target.minY) > 1
            || abs($0.width - target.width) > 1 || abs($0.height - target.height) > 1
        } ?? true
        if drifted { setAXFrame(element, frame: target) }
      }
      AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
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

  /// A mouse-down landed outside every suppressed floating window — focus
  /// is about to move to whatever was clicked. Put the mirrors back up
  /// ahead of the raise; the didActivate notification settles final state.
  private func handleOutsideClick() {
    guard !suppressed.isEmpty else { return }
    for key in panels.keys {
      restoreMirror(key)
      showPanel(key)
    }
    applyStackOrder()
  }

  /// Publish the suppressed windows' frames (CG coordinates) for the
  /// mouse-down tap, which runs off the main thread.
  private func syncSuppressedFrames() {
    var frames: [CGWindowID: CGRect] = [:]
    for key in suppressed {
      if let cocoa = lastFrame[key] { frames[key.windowID] = flipToCG(cocoa) }
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
    guard let cg = axFrame(of: element) else { return }
    let cocoa = flipToCocoa(cg)
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

  // MARK: - AX frame helpers

  private func axFrame(of window: AXUIElement) -> CGRect? {
    let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
    var valuesRef: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(
      window, attrs, AXCopyMultipleAttributeOptions(), &valuesRef
    ) == .success,
      let values = valuesRef as? [CFTypeRef], values.count == 2,
      CFGetTypeID(values[0]) == AXValueGetTypeID(),
      CFGetTypeID(values[1]) == AXValueGetTypeID()
    else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(values[0] as! AXValue, .cgPoint, &pos)
    AXValueGetValue(values[1] as! AXValue, .cgSize, &size)
    guard size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: pos, size: size)
  }

  private func setAXFrame(_ window: AXUIElement, frame: CGRect) {
    var position = CGPoint(x: frame.minX, y: frame.minY)
    var size = CGSize(width: frame.width, height: frame.height)
    if let value = AXValueCreate(.cgPoint, &position) {
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
    if let value = AXValueCreate(.cgSize, &size) {
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
  }

  /// AX/CG frames are top-left origin against the primary screen;
  /// `NSWindow.setFrame` wants bottom-left Cocoa coordinates.
  private func flipToCocoa(_ frame: CGRect) -> NSRect {
    guard let primary = NSScreen.screens.first else { return frame }
    let totalHeight = primary.frame.height
    return NSRect(
      x: frame.origin.x,
      y: totalHeight - frame.origin.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }

  private func flipToCG(_ frame: NSRect) -> CGRect {
    guard let primary = NSScreen.screens.first else { return frame }
    let totalHeight = primary.frame.height
    return CGRect(
      x: frame.origin.x,
      y: totalHeight - frame.origin.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }
}

/// Listen-only mouse-down tap. A click outside every suppressed floating
/// window is about to move focus away from the floating app; restoring the
/// mirrors at mouse-down time beats the clicked app's raise, which the
/// didActivate notification only reports after the fact. Modeled on the
/// focus-follows-mouse tap (same `EventTapThread`, same re-enable dance).
private final class MirrorClickTap: @unchecked Sendable {
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let onOutsideClick: @Sendable () -> Void

  init(onOutsideClick: @escaping @Sendable () -> Void) {
    self.onOutsideClick = onOutsideClick
  }

  func setEnabled(_ enabled: Bool) {
    EventTapThread.shared.perform { [self] in
      if enabled, eventTap == nil {
        install()
      } else if !enabled, eventTap != nil {
        teardown()
      }
    }
  }

  /// Runs on the event-tap thread.
  private func install() {
    let mask =
      (1 << CGEventType.leftMouseDown.rawValue) |
      (1 << CGEventType.rightMouseDown.rawValue) |
      (1 << CGEventType.tapDisabledByTimeout.rawValue) |
      (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let info = Unmanaged.passUnretained(self).toOpaque()
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: CGEventMask(mask),
      callback: mirrorClickTapCallback,
      userInfo: info
    ) else {
      logger.error("mirror click tap: CGEvent.tapCreate failed")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      logger.error("mirror click tap: failed to create run loop source")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
  }

  private func teardown() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source = runLoopSource { EventTapThread.shared.removeSource(source) }
    eventTap = nil
    runLoopSource = nil
  }

  fileprivate func reEnable() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
  }

  /// Runs on the event-tap thread; reads only the lock-protected registry.
  fileprivate func handle(location: CGPoint) {
    let frames = MirrorWindowRegistry.shared.suppressedWindowFrames()
    guard !frames.isEmpty else { return }
    guard !frames.contains(where: { $0.contains(location) }) else { return }
    onOutsideClick()
  }
}

/// CGEventTap C callback for the mirror click tap — listen-only, returns
/// the event unmodified.
private func mirrorClickTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MirrorClickTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .leftMouseDown, .rightMouseDown:
    tap.handle(location: event.location)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    tap.reEnable()
  default:
    break
  }
  return Unmanaged.passUnretained(event)
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
