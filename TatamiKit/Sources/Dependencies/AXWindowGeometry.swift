import AppKit
import ApplicationServices

/// Shared AX window-frame primitives. Marker dots, floating mirrors, the
/// drag preview, and the window observer all need the same three things —
/// read a window's frame, write one, and flip between coordinate spaces —
/// and each used to carry its own copy (two of them with diverging
/// implementations). Coordinate-flip math is exactly where a future
/// copy-paste error hides, so it lives here once.
@MainActor
enum AXWindowGeometry {
  /// The window's frame in AX coordinates (top-left origin, anchored to
  /// the primary screen). One `CopyMultipleAttributeValues` IPC round
  /// trip. Returns nil for degenerate (≤ 1 pt) sizes — those are
  /// placeholder windows mid-creation, not real geometry.
  static func frame(of window: AXUIElement) -> CGRect? {
    let attrs = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
    var valuesRef: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(
      window, attrs, AXCopyMultipleAttributeOptions(), &valuesRef
    ) == .success,
      let values = valuesRef as? [CFTypeRef], values.count == 2,
      CFGetTypeID(values[0]) == AXValueGetTypeID(),
      CFGetTypeID(values[1]) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(values[0] as! AXValue, .cgPoint, &position)
    AXValueGetValue(values[1] as! AXValue, .cgSize, &size)
    guard size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: position, size: size)
  }

  /// Write the window's position + size (AX coordinates).
  static func setFrame(_ window: AXUIElement, to frame: CGRect) {
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
  static func flipToCocoa(_ frame: CGRect) -> NSRect { flip(frame) }

  /// Cocoa bottom-left → AX/CG top-left.
  static func flipToCG(_ frame: NSRect) -> CGRect { flip(frame) }

  /// The flip is an involution — the same formula maps both directions.
  private static func flip(_ frame: CGRect) -> CGRect {
    // Anchor to the primary display (CGMainDisplayID), not `screens.first`
    // (the origin-(0,0) screen) — the two can differ, which offset flipped
    // geometry. `primaryScreen()` falls back to `screens.first` anyway.
    guard let primary = DisplayResolver.primaryScreen() else { return frame }
    let totalHeight = primary.frame.height
    return CGRect(
      x: frame.origin.x,
      y: totalHeight - frame.origin.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }
}
