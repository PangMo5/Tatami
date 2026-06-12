import AppKit
import Dependencies
import DependenciesMacros
import SwiftUI

/// Where a dragged window will land relative to the tile under the cursor.
/// `swap` exchanges the two windows in place; the others insert the dragged
/// window on that side of the target.
public enum DropZone: Sendable, Hashable {
  case swap, left, right, top, bottom
}

/// Translucent overlay that previews the drop target while the user drags a
/// window. Driven live by the activation reducer (one update per AX
/// `windowMoved`); hidden on drag-end. Purely visual — it never intercepts
/// mouse events, so it can't interfere with the drag.
@DependencyClient
struct DragPreviewClient: Sendable {
  /// Highlight `zone` of `targetRect` (AX top-left, primary-anchored coords).
  var show: @Sendable (_ targetRect: CGRect, _ zone: DropZone) -> Void
  /// Remove the overlay.
  var hide: @Sendable () -> Void
}

extension DragPreviewClient: DependencyKey {
  static let liveValue: DragPreviewClient = MainActor.assumeIsolated {
    let controller = DragPreviewController()
    return DragPreviewClient(
      show: { rect, zone in
        Task { @MainActor in controller.show(targetRect: rect, zone: zone) }
      },
      hide: { Task { @MainActor in controller.hide() } }
    )
  }

  // Macro-synthesized unimplemented endpoints: a test that reaches the
  // drag preview without stubbing it should fail, not silently no-op.
  static let testValue = DragPreviewClient()
  static let previewValue = DragPreviewClient(show: { _, _ in }, hide: {})
}

extension DependencyValues {
  var dragPreview: DragPreviewClient {
    get { self[DragPreviewClient.self] }
    set { self[DragPreviewClient.self] = newValue }
  }
}

@MainActor
private final class DragPreviewController {
  private var panel: NSPanel?
  private var lastZone: DropZone?

  func show(targetRect: CGRect, zone: DropZone) {
    let panel = panel ?? makePanel()
    self.panel = panel
    if lastZone != zone {
      lastZone = zone
      if let hosting = panel.contentView as? NSHostingView<DragPreviewView> {
        hosting.rootView = DragPreviewView(isSwap: zone == .swap)
      }
    }
    let cocoa = AXWindowGeometry.flipToCocoa(Self.highlightRect(in: targetRect, zone: zone))
    panel.setFrame(cocoa, display: true, animate: false)
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  func hide() {
    panel?.orderOut(nil)
    lastZone = nil
  }

  /// Sub-rect of the target tile to highlight: the whole tile for a swap,
  /// or the half the dragged window would occupy after a directional insert.
  /// Coordinates are AX top-left, so `top` is the smaller-Y half.
  private static func highlightRect(in rect: CGRect, zone: DropZone) -> CGRect {
    switch zone {
    case .swap:
      return rect
    case .left:
      return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .right:
      return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .top:
      return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    case .bottom:
      return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
  }

  private func makePanel() -> NSPanel {
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
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    panel.contentView = NSHostingView(rootView: DragPreviewView(isSwap: true))
    return panel
  }

  /// AX/CG frames use top-left origin against the primary screen;
  /// `NSWindow.setFrame` wants bottom-left Cocoa coordinates.
}

private struct DragPreviewView: View {
  /// Swap drops use one accent (blue); directional inserts another (green),
  /// so the action reads at a glance.
  let isSwap: Bool

  var body: some View {
    let tint: Color = isSwap ? .blue : .green
    RoundedRectangle(cornerRadius: 8)
      .fill(tint.opacity(0.22))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(tint.opacity(0.7), lineWidth: 2)
      )
      .padding(2)
  }
}
