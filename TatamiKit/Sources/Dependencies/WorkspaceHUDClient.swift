import AppKit
import Dependencies
import SwiftUI

/// Shows a brief, centered overlay with the activated workspace's name
/// and icon — visual feedback for hotkey/menu switches. Auto-dismisses;
/// re-showing resets the timer.
public struct WorkspaceHUDClient: Sendable {
  public var show: @Sendable (_ name: String, _ symbolIconName: String?) async -> Void

  public init(show: @escaping @Sendable (_ name: String, _ symbolIconName: String?) async -> Void) {
    self.show = show
  }
}

extension WorkspaceHUDClient: DependencyKey {
  public static let liveValue: WorkspaceHUDClient = {
    let controller = WorkspaceHUDController()
    return WorkspaceHUDClient { name, icon in
      await controller.show(name: name, symbolIconName: icon)
    }
  }()

  public static let testValue = WorkspaceHUDClient { _, _ in }
  public static let previewValue = testValue
}

extension DependencyValues {
  public var workspaceHUD: WorkspaceHUDClient {
    get { self[WorkspaceHUDClient.self] }
    set { self[WorkspaceHUDClient.self] = newValue }
  }
}

@MainActor
private final class WorkspaceHUDController {
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?

  func show(name: String, symbolIconName: String?) {
    let panel = panel ?? makePanel()
    self.panel = panel

    panel.contentView = NSHostingView(
      rootView: WorkspaceHUDView(name: name, symbolIconName: symbolIconName)
    )
    layout(panel)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTask?.cancel()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      self?.fadeOut()
    }
  }

  private func fadeOut() {
    guard let panel else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      panel.animator().alphaValue = 0
    } completionHandler: { [weak panel] in
      panel?.orderOut(nil)
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
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
    return panel
  }

  private func layout(_ panel: NSPanel) {
    let size = NSSize(width: 280, height: 150)
    panel.setContentSize(size)
    guard let screen = NSScreen.main else { return }
    let visible = screen.visibleFrame
    // Centered horizontally, near the bottom of the usable area.
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.minY + 96
    )
    panel.setFrameOrigin(origin)
  }
}

private struct WorkspaceHUDView: View {
  let name: String
  let symbolIconName: String?

  var body: some View {
    let content = VStack(spacing: 12) {
      Image(systemName: symbolIconName ?? "square.stack.3d.up.fill")
        .font(.system(size: 40, weight: .medium))
        .foregroundStyle(.tint)
      Text(name)
        .font(.title2.weight(.semibold))
        .lineLimit(1)
    }
    .frame(width: 240, height: 110)
    .padding(8)

    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: 28))
    } else {
      content
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
          RoundedRectangle(cornerRadius: 24)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
  }
}
