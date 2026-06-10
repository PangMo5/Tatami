import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import SwiftUI

/// Draws a tiny colored dot on a configurable corner of selected windows
/// (zoomed + floating) as a passive identifier. Fades out while the
/// cursor hovers over it so it never blocks clicks.
/// What to draw on one marked window: the dot color, plus whether the dot
/// shows regardless of focus. Floating windows keep their dot up always —
/// the mark is what tells a mirrored window apart from a tiled one — while
/// fullscreen-zoom dots only show on the focused window.
struct MarkerTarget: Sendable, Equatable {
  var colorHex: String
  var alwaysVisible: Bool

  init(colorHex: String, alwaysVisible: Bool = false) {
    self.colorHex = colorHex
    self.alwaysVisible = alwaysVisible
  }
}

@DependencyClient
struct MarkerClient: Sendable {
  /// Replace the set of marked windows. Pass `[:]` to clear all.
  var setTargets: @Sendable (
    _ targets: [WindowKey: MarkerTarget],
    _ size: Double,
    _ corner: MarkerCorner,
    _ hideOnHover: Bool
  ) -> Void
  /// Tell the marker controller which window is currently frontmost so
  /// it can render a dot only on that window. Pushed from the AX
  /// observer's `windowFocused` events + the workspace app-activation
  /// flow — cheaper and more responsive than polling AX every 50 ms.
  /// Pass `nil` to clear (no focused window).
  var setFocused: @Sendable (_ key: WindowKey?) -> Void
}

extension MarkerClient: DependencyKey {
  static let liveValue: MarkerClient = MainActor.assumeIsolated {
    let controller = MarkerController()
    return MarkerClient(
      setTargets: { targets, size, corner, hideOnHover in
        Task { @MainActor in
          controller.setTargets(targets, size: size, corner: corner, hideOnHover: hideOnHover)
        }
      },
      setFocused: { key in
        Task { @MainActor in controller.setFocused(key) }
      }
    )
  }

  /// Without this, a `TestStore` that forgets to override `\.marker`
  /// constructs the real `MarkerController` (NSPanels) on the test host.
  static let testValue = MarkerClient(
    setTargets: { _, _, _, _ in },
    setFocused: { _ in }
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var marker: MarkerClient {
    get { self[MarkerClient.self] }
    set { self[MarkerClient.self] = newValue }
  }
}

@MainActor
private final class MarkerController {
  private struct Style: Equatable {
    var hex: String
    var size: Double
  }

  private var panels: [WindowKey: NSPanel] = [:]
  private var styles: [WindowKey: Style] = [:]
  /// Windows whose dot ignores the focus gate (floating windows).
  private var alwaysVisible: Set<WindowKey> = []
  private var lastFrame: [WindowKey: NSRect] = [:]
  /// Resolved `AXUIElement` per marked window — the element we read the
  /// frame from and subscribe geometry notifications on. AX calls are
  /// synchronous cross-process IPC and must stay on the main thread, so we
  /// resolve each window's element once and reuse it.
  private var axWindowCache: [WindowKey: AXUIElement] = [:]
  /// One `AXObserver` per owning pid. The marker subscribes
  /// `kAXWindowMoved` / `kAXWindowResized` on each marked window so dots
  /// follow the window event-driven — there is no polling timer. Unlike the
  /// BSP `WindowObserver` these are deliberately *not* mouse-gated, so they
  /// also track programmatic re-tiles (fullscreen-zoom toggle, layout
  /// snap-back), which is what the old design needed a deferred sync for.
  private var axObservers: [pid_t: AXObserver] = [:]
  private var subscribed: Set<WindowKey> = []
  /// Global mouse-moved monitor, installed only while a dot can be visible,
  /// so the hover-fade reacts without a polling timer. Hover needs the
  /// cursor position — a mouse event — which SwiftUI `.onHover` can't give
  /// us here: the panels are `ignoresMouseEvents` (click-through), so they
  /// receive no tracking events at all. A global monitor sees movement in
  /// *other* apps, which is exactly where the dots live.
  private var hoverMonitor: Any?

  private var hideOnHover = true
  private var corner: MarkerCorner = .bottomTrailing
  /// Last focused window pushed in via `setFocused`. nil = no focus
  /// (or unknown — markers stay hidden, which is the safe default).
  private var focused: (pid: pid_t, windowID: CGWindowID)?
  /// Distance from the chosen window corner to the dot's edge.
  private let inset: CGFloat = 10
  /// Small panel padding so the dot's faint drop shadow isn't clipped
  /// at the panel edge.
  private let glowPadding: CGFloat = 2

  func setTargets(
    _ targets: [WindowKey: MarkerTarget],
    size: Double,
    corner: MarkerCorner,
    hideOnHover: Bool
  ) {
    self.hideOnHover = hideOnHover
    if self.corner != corner {
      self.corner = corner
      // Force every panel to reposition on the next sync — the dot's anchor
      // changed, so cached frames are stale.
      lastFrame.removeAll()
    }
    // Tear down panels (+ AX subscriptions) for windows no longer marked.
    // The reducer owns the target set, so this is the authoritative point
    // at which a dot's lifecycle ends.
    for key in panels.keys.filter({ targets[$0] == nil }) {
      removeWindow(key)
    }
    alwaysVisible = Set(targets.filter(\.value.alwaysVisible).keys)
    // Add or update panels for each target.
    for (key, target) in targets {
      let style = Style(hex: target.colorHex, size: size)
      if panels[key] == nil {
        panels[key] = makePanel(style: style)
      } else if styles[key] != style,
                let hosting = panels[key]?.contentView as? NSHostingView<MarkerView>
      {
        hosting.rootView = makeView(style: style)
        lastFrame.removeValue(forKey: key)
      }
      styles[key] = style
    }
    syncFrames()
  }

  /// Record the currently-frontmost window. `nil` means "no focused
  /// window", which keeps every marker hidden.
  func setFocused(_ key: WindowKey?) {
    let next: (pid: pid_t, windowID: CGWindowID)? = key.map { ($0.pid, $0.windowID) }
    if let new = next, let old = focused, new == old { return }
    if next == nil && focused == nil { return }
    focused = next
    syncFrames()
  }

  // MARK: - Sync (one-shot; no timer)

  /// Full pass: resolve elements, (re)subscribe AX geometry notifications,
  /// then position every dot and update its visibility. Called only on
  /// target / focus changes — the per-window AX observer drives every
  /// reposition in between, and the hover monitor drives the fade.
  private func syncFrames() {
    ensureAXCacheCoversPanels()
    ensureSubscriptions()
    let cursor = NSEvent.mouseLocation  // Cocoa coordinates (bottom-left)
    for key in Array(panels.keys) {
      refresh(key, cursor: cursor)
    }
    refreshHoverMonitor()
  }

  /// Position + visibility for one dot from the live AX frame. On a frame
  /// read failure (transient AX timeout, or window not yet ready) the dot is
  /// hidden but kept — the next geometry event or `syncFrames` retries; the
  /// reducer drops it via `setTargets` once it's truly gone.
  private func refresh(_ key: WindowKey, cursor: NSPoint) {
    guard let style = styles[key], let panel = panels[key] else { return }
    guard let windowFrame = frame(for: key) else {
      if panel.alphaValue > 0.01 { panel.alphaValue = 0 }
      return
    }
    let cocoa = AXWindowGeometry.flipToCocoa(dotRect(in: windowFrame, size: CGFloat(style.size), corner: corner))
    if lastFrame[key] != cocoa {
      if lastFrame[key] == nil {
        // First placement: land directly, no glide in from nowhere.
        panel.setFrame(cocoa, display: true, animate: false)
      } else {
        // AX geometry events arrive sparsely during a drag; a short
        // ease-out glide between them reads as the dot following the
        // window instead of teleporting event-to-event.
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.12
          ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
          panel.animator().setFrame(cocoa, display: true)
        }
      }
      lastFrame[key] = cocoa
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
    updateAlpha(for: key, cursor: cursor)
  }

  /// Visibility only, from the *cached* dot rect — no AX round trip. Used by
  /// the hover monitor so moving the cursor never triggers AX IPC.
  private func updateAlpha(for key: WindowKey, cursor: NSPoint) {
    guard let panel = panels[key], let cocoa = lastFrame[key] else { return }
    // Focus gate: hide when this window isn't the user's current window —
    // except always-visible marks (floating windows), which stay up so the
    // mark identifies the mirror at a glance. Matched on (pid, wid) so two
    // windows of the same app don't share a dot.
    let isFocused = focused.map { $0.pid == key.pid && $0.windowID == key.windowID } ?? false
    let shown = isFocused || alwaysVisible.contains(key)
    // Hover fade: only react when the cursor sits over the dot's visible
    // circle, not the surrounding glow padding.
    let hovering = hideOnHover && cocoa.insetBy(dx: glowPadding, dy: glowPadding).contains(cursor)
    let target: CGFloat = (shown && !hovering) ? 1 : 0
    if abs(panel.alphaValue - target) > 0.01 {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.15
        panel.animator().alphaValue = target
      }
    }
  }

  /// `kAXWindowMoved` / `kAXWindowResized` arrived for `windowID` (delivered
  /// on the main run loop). Reposition just that dot.
  fileprivate func handleGeometryChange(windowID: CGWindowID) {
    guard let key = panels.keys.first(where: { $0.windowID == windowID }) else { return }
    refresh(key, cursor: NSEvent.mouseLocation)
  }

  // MARK: - AX geometry subscriptions

  /// Subscribe `kAXWindowMoved` / `kAXWindowResized` on every marked window
  /// we haven't subscribed yet (one `AXObserver` per owning pid).
  private func ensureSubscriptions() {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for (key, element) in axWindowCache where panels[key] != nil && !subscribed.contains(key) {
      guard let observer = observer(for: key.pid) else { continue }
      // AlreadyRegistered is fine — these calls are idempotent.
      AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, refcon)
      AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, refcon)
      subscribed.insert(key)
    }
  }

  private func observer(for pid: pid_t) -> AXObserver? {
    if let existing = axObservers[pid] { return existing }
    var observer: AXObserver?
    guard AXObserverCreate(pid, markerAXGeometryCallback, &observer) == .success,
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

  /// Drop a window's panel + AX subscription. Tears the pid's observer down
  /// once it no longer owns any marked window.
  private func removeWindow(_ key: WindowKey) {
    if subscribed.remove(key) != nil,
       let element = axWindowCache[key],
       let observer = axObservers[key.pid]
    {
      AXObserverRemoveNotification(observer, element, kAXWindowMovedNotification as CFString)
      AXObserverRemoveNotification(observer, element, kAXWindowResizedNotification as CFString)
    }
    panels[key]?.orderOut(nil)
    panels.removeValue(forKey: key)
    styles.removeValue(forKey: key)
    lastFrame.removeValue(forKey: key)
    axWindowCache.removeValue(forKey: key)
    if !panels.keys.contains(where: { $0.pid == key.pid }),
       let observer = axObservers.removeValue(forKey: key.pid)
    {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .defaultMode
      )
    }
  }

  // MARK: - Hover monitor

  /// Install the global mouse-moved monitor only while at least one dot can
  /// be visible; remove it otherwise so an idle marker set costs nothing.
  private func refreshHoverMonitor() {
    let needed = hideOnHover && !panels.isEmpty
      && (focused != nil || !alwaysVisible.isEmpty)
    if needed, hoverMonitor == nil {
      hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.handleHover(cursor: NSEvent.mouseLocation)
        }
      }
    } else if !needed, let monitor = hoverMonitor {
      NSEvent.removeMonitor(monitor)
      hoverMonitor = nil
    }
  }

  private func handleHover(cursor: NSPoint) {
    for key in panels.keys { updateAlpha(for: key, cursor: cursor) }
  }

  // MARK: - AX frame resolution

  /// Resolve every still-unresolved marked window to its `AXUIElement` in
  /// one `kAXWindowsAttribute` enumeration per owning app. After a window is
  /// first cached this no-ops for it, so the cost is paid once per marked
  /// window, not on every event.
  private func ensureAXCacheCoversPanels() {
    let missing = panels.keys.filter { axWindowCache[$0] == nil }
    guard !missing.isEmpty else { return }
    let byPid = Dictionary(grouping: missing, by: { $0.pid })
    for (pid, keys) in byPid {
      let app = AXUIElementCreateApplication(pid)
      // Bound the per-message wait so a hung target app can't stall the
      // main thread for the default ceiling.
      AXUIElementSetMessagingTimeout(app, 0.25)
      var raw: CFTypeRef?
      guard AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute as CFString, &raw
      ) == .success,
        let windows = raw as? [AXUIElement]
      else { continue }
      var widToElement: [CGWindowID: AXUIElement] = [:]
      for window in windows {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(window, &wid) == .success, wid != 0 {
          widToElement[wid] = window
        }
      }
      for key in keys {
        if let element = widToElement[key.windowID] { axWindowCache[key] = element }
      }
    }
  }

  /// Current AX frame for a marked window via its cached element. Returns nil
  /// on a transient failure without dropping the element — the live window
  /// keeps its subscription and re-resolves on the next event.
  private func frame(for key: WindowKey) -> CGRect? {
    guard let element = axWindowCache[key] else { return nil }
    return AXWindowGeometry.frame(of: element)
  }

  /// Read `kAXPosition` + `kAXSize` in a single multi-attribute IPC round
  /// trip instead of two separate `AXUIElementCopyAttributeValue` calls.

  // MARK: - Geometry helpers

  /// Place the panel near the chosen window corner in top-left CG coords.
  /// The panel is sized to include `glowPadding` so the colored shadow
  /// can bloom outside the dot without being clipped.
  private func dotRect(in windowFrame: CGRect, size: CGFloat, corner: MarkerCorner) -> CGRect {
    let pad = glowPadding
    let panelSize = size + pad * 2
    let x: CGFloat
    let y: CGFloat
    switch corner {
    case .topLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.minY + inset - pad
    case .topTrailing:
      x = windowFrame.maxX - inset - size - pad
      y = windowFrame.minY + inset - pad
    case .bottomLeading:
      x = windowFrame.minX + inset - pad
      y = windowFrame.maxY - inset - size - pad
    case .bottomTrailing:
      x = windowFrame.maxX - inset - size - pad
      y = windowFrame.maxY - inset - size - pad
    }
    return CGRect(x: x, y: y, width: panelSize, height: panelSize)
  }

  private func makePanel(style: Style) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    // One notch above the floating-mirror panels (also `.floating`), so a
    // floating window's dot draws on top of its mirror instead of under it.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    // `.transient` makes macOS hide the panel during Exposé / Mission
    // Control / App Switcher overlays automatically — without it the
    // dots float on top of the scaled window thumbnails.
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    panel.contentView = NSHostingView(rootView: makeView(style: style))
    return panel
  }

  private func makeView(style: Style) -> MarkerView {
    MarkerView(
      color: Color(hex: style.hex) ?? .blue,
      size: CGFloat(style.size),
      padding: glowPadding
    )
  }

  /// AX/CG frames use top-left origin against the primary screen.
  /// `NSWindow.setFrame` wants bottom-left Cocoa coordinates.
}

/// `AXObserver` C callback for marker geometry. The run-loop source is added
/// to the main run loop, so this already runs on the main thread and hops
/// straight onto the MainActor-isolated controller. Only the window id (a
/// Sendable scalar) is read from the non-Sendable element before the hop, so
/// nothing non-Sendable crosses the boundary.
private func markerAXGeometryCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  guard let refcon else { return }
  var windowID: CGWindowID = 0
  guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else { return }
  let controller = Unmanaged<MarkerController>.fromOpaque(refcon).takeUnretainedValue()
  MainActor.assumeIsolated {
    controller.handleGeometryChange(windowID: windowID)
  }
}

private struct MarkerView: View {
  let color: Color
  let size: CGFloat
  let padding: CGFloat

  var body: some View {
    Circle()
      .fill(color)
      .overlay(
        Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
      .padding(padding)
  }
}

extension Color {
  /// Parse `#RRGGBB` or `#RRGGBBAA`. Returns nil on malformed input.
  public init?(hex: String) {
    var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard raw.count == 6 || raw.count == 8 else { return nil }
    var value: UInt64 = 0
    guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
    let r: Double, g: Double, b: Double, a: Double
    if raw.count == 6 {
      r = Double((value >> 16) & 0xFF) / 255
      g = Double((value >> 8) & 0xFF) / 255
      b = Double(value & 0xFF) / 255
      a = 1
    } else {
      r = Double((value >> 24) & 0xFF) / 255
      g = Double((value >> 16) & 0xFF) / 255
      b = Double((value >> 8) & 0xFF) / 255
      a = Double(value & 0xFF) / 255
    }
    self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  /// Serialize back to `#RRGGBB`. Returns nil if the color isn't in an
  /// RGB-convertible color space (e.g. dynamic system colors).
  public func toHex() -> String? {
    guard let cg = NSColor(self).usingColorSpace(.sRGB)?.cgColor,
          let components = cg.components, components.count >= 3
    else { return nil }
    let r = Int((components[0] * 255).rounded())
    let g = Int((components[1] * 255).rounded())
    let b = Int((components[2] * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}
