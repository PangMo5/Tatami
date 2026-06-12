import AppKit
import Dependencies
import DependenciesMacros
import SwiftUI

/// Shows a brief, centered overlay with a title and icon — visual feedback
/// for hotkey/menu actions. An optional subtitle carries a follow-up hint
/// (e.g. the shortcut that removes a just-unfloated app from Shared Apps);
/// HUDs with a subtitle linger a little longer so the hint is readable.
/// Auto-dismisses; re-showing resets the timer.
@DependencyClient
struct WorkspaceHUDClient: Sendable {
  var show: @Sendable (
    _ name: String, _ symbolIconName: String?, _ subtitle: String?, _ durationMs: Int
  ) async -> Void
}

extension WorkspaceHUDClient: DependencyKey {
  static let liveValue: WorkspaceHUDClient = {
    @Dependency(\.debugLog) var debugLog
    let controller = WorkspaceHUDController(debugLog: debugLog)
    return WorkspaceHUDClient { name, icon, subtitle, durationMs in
      await controller.show(
        name: name, symbolIconName: icon, subtitle: subtitle, durationMs: durationMs
      )
    }
  }()

  static let testValue = WorkspaceHUDClient { _, _, _, _ in }
  static let previewValue = testValue
}

extension DependencyValues {
  var workspaceHUD: WorkspaceHUDClient {
    get { self[WorkspaceHUDClient.self] }
    set { self[WorkspaceHUDClient.self] = newValue }
  }
}

@MainActor
private final class WorkspaceHUDController {
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?
  private let debugLog: DebugLogClient

  init(debugLog: DebugLogClient) {
    self.debugLog = debugLog
  }

  func show(name: String, symbolIconName: String?, subtitle: String?, durationMs: Int) {
    debugLog.log(
      "HUDDiag", "show title=\(name) hint=\(subtitle != nil) durationMs=\(durationMs)"
    )
    // Every HUD gets a *fresh* panel: once a panel has been ordered out, a
    // later window-alpha animation on it completes instantly (no fade) —
    // observed as some HUDs vanishing without animation. Retiring the old
    // panel and never reusing it keeps each fade on first-show state. This
    // also removes the show/fade races a shared panel needed guards for.
    hideTask?.cancel()
    panel?.orderOut(nil)

    let panel = makePanel()
    self.panel = panel
    panel.contentView = NSHostingView(
      rootView: WorkspaceHUDView(name: name, symbolIconName: symbolIconName, subtitle: subtitle)
    )
    layout(panel, hasSubtitle: subtitle != nil)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    hideTask = Task { [weak self] in
      // A hint line takes longer to read than a glanceable title.
      let duration = max(100, subtitle == nil ? durationMs : durationMs * 2)
      try? await Task.sleep(for: .milliseconds(duration))
      guard !Task.isCancelled else { return }
      self?.fadeOut(panel)
    }
  }

  private func fadeOut(_ panel: NSPanel) {
    // Fade the content *view*, not the window: NSWindow's alpha animator
    // proved unreliable for this panel configuration — after the first
    // fade of the process, later animations completed instantly (no fade),
    // fresh panel or not. The view animator is plain Core Animation and
    // behaves every time.
    guard let view = panel.contentView else {
      panel.orderOut(nil)
      return
    }
    debugLog.log("HUDDiag", "fadeOut start alpha=\(view.alphaValue)")
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.allowsImplicitAnimation = true
      view.animator().alphaValue = 0
    } completionHandler: { [weak self, weak panel] in
      self?.debugLog.log("HUDDiag", "fadeOut done")
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

  private func layout(_ panel: NSPanel, hasSubtitle: Bool) {
    let size = NSSize(width: hasSubtitle ? 340 : 280, height: hasSubtitle ? 174 : 150)
    panel.setContentSize(size)
    // The screen the cursor is on — `NSScreen.main` follows the key
    // window, which after a workspace switch can be a different display
    // than the one the user is looking at.
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main
    guard let screen else { return }
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
  let subtitle: String?

  var body: some View {
    let content = VStack(spacing: 12) {
      Image(systemName: symbolIconName ?? "square.stack.3d.up.fill")
        .font(.system(size: 40, weight: .medium))
        .foregroundStyle(.tint)
      Text(name)
        .font(.title2.weight(.semibold))
        .lineLimit(1)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
    }
    .frame(width: subtitle == nil ? 240 : 300, height: subtitle == nil ? 110 : 134)
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
