import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import SwiftUI

/// Draws a tiny colored dot on a configurable corner of selected windows
/// (zoomed + floating) as a passive identifier. Fades out while the
/// cursor hovers over it so it never blocks clicks.
@DependencyClient
public struct MarkerClient: Sendable {
  /// Replace the set of marked windows, one hex color per window.
  /// Pass `[:]` to clear all.
  public var setTargets: @Sendable (
    _ targets: [WindowKey: String],
    _ size: Double,
    _ corner: MarkerCorner,
    _ hideOnHover: Bool
  ) -> Void
}

extension MarkerClient: DependencyKey {
  public static let liveValue: MarkerClient = MainActor.assumeIsolated {
    let controller = MarkerController()
    return MarkerClient(
      setTargets: { targets, size, corner, hideOnHover in
        Task { @MainActor in
          controller.setTargets(targets, size: size, corner: corner, hideOnHover: hideOnHover)
        }
      }
    )
  }
}

extension DependencyValues {
  public var marker: MarkerClient {
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
  private var lastFrame: [WindowKey: NSRect] = [:]
  private var timer: Timer?
  /// Polling cadence: enough to track window drags smoothly and to
  /// react to the cursor moving over a dot.
  private let interval: TimeInterval = 0.05
  private var hideOnHover = true
  private var corner: MarkerCorner = .bottomTrailing
  /// Distance from the chosen window corner to the dot's edge.
  private let inset: CGFloat = 10
  /// Small panel padding so the dot's faint drop shadow isn't clipped
  /// at the panel edge.
  private let glowPadding: CGFloat = 2

  func setTargets(
    _ targets: [WindowKey: String],
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
    // Tear down panels for windows no longer marked.
    for (key, panel) in panels where targets[key] == nil {
      panel.orderOut(nil)
      panels.removeValue(forKey: key)
      styles.removeValue(forKey: key)
      lastFrame.removeValue(forKey: key)
    }
    // Add or update panels for each target.
    for (key, hex) in targets {
      let style = Style(hex: hex, size: size)
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
    setTimer(active: !targets.isEmpty)
  }

  private func setTimer(active: Bool) {
    if active, timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.syncFrames() }
      }
    } else if !active, let t = timer {
      t.invalidate()
      timer = nil
    }
  }

  /// Move each panel onto its window's configured corner. While the
  /// cursor is over a dot, fade it out so it doesn't block the window.
  private func syncFrames() {
    var lost: [WindowKey] = []
    let cursor = NSEvent.mouseLocation  // Cocoa coordinates (bottom-left)
    for (key, panel) in panels {
      guard let style = styles[key],
            let windowFrame = windowFrame(pid: key.pid, windowID: key.windowID)
      else {
        lost.append(key)
        continue
      }
      let size = CGFloat(style.size)
      let dotCG = dotRect(in: windowFrame, size: size, corner: corner)
      let cocoa = flipToCocoa(dotCG)
      if lastFrame[key] != cocoa {
        panel.setFrame(cocoa, display: true, animate: false)
        lastFrame[key] = cocoa
      }
      if !panel.isVisible { panel.orderFrontRegardless() }
      // Hover fade: only react when the cursor sits over the dot's
      // visible circle, not the surrounding glow padding.
      let hoverRect = cocoa.insetBy(dx: glowPadding, dy: glowPadding)
      let hovering = hideOnHover && hoverRect.contains(cursor)
      let target: CGFloat = hovering ? 0 : 1
      if abs(panel.alphaValue - target) > 0.01 {
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.15
          panel.animator().alphaValue = target
        }
      }
    }
    for key in lost {
      panels[key]?.orderOut(nil)
      panels.removeValue(forKey: key)
      styles.removeValue(forKey: key)
      lastFrame.removeValue(forKey: key)
    }
    if panels.isEmpty { setTimer(active: false) }
  }

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
    panel.level = .floating
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

  /// Resolve the AX `kAXPosition` / `kAXSize` for a window owned by `pid`
  /// matching `windowID`. Returns nil if the window has gone away.
  private func windowFrame(pid: pid_t, windowID: CGWindowID) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      app, kAXWindowsAttribute as CFString, &raw
    ) == .success,
      let windows = raw as? [AXUIElement]
    else { return nil }
    for window in windows {
      var wid: CGWindowID = 0
      guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else {
        continue
      }
      return axFrame(of: window)
    }
    return nil
  }

  private func axFrame(of window: AXUIElement) -> CGRect? {
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
    guard size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: pos, size: size)
  }

  /// AX/CG frames use top-left origin against the primary screen.
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
