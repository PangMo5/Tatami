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
  /// Like `show`, but anchored to a specific display instead of the cursor's
  /// screen (`nil` → cursor's screen, same as `show`). Used to announce a
  /// focus move on the *old* monitor when a switch crosses displays.
  var showOnDisplay: @Sendable (
    _ name: String, _ symbolIconName: String?, _ subtitle: String?,
    _ durationMs: Int, _ display: DisplayName?
  ) async -> Void
  /// Fade out the current HUD immediately (e.g. cancelling borrow mode).
  var dismiss: @Sendable () async -> Void
}

extension WorkspaceHUDClient: DependencyKey {
  static let liveValue: WorkspaceHUDClient = {
    @Dependency(\.debugLog) var debugLog
    let controller = WorkspaceHUDController(debugLog: debugLog)
    return WorkspaceHUDClient(
      show: { name, icon, subtitle, durationMs in
        await controller.show(
          name: name, symbolIconName: icon, subtitle: subtitle,
          durationMs: durationMs, display: nil
        )
      },
      showOnDisplay: { name, icon, subtitle, durationMs, display in
        await controller.show(
          name: name, symbolIconName: icon, subtitle: subtitle,
          durationMs: durationMs, display: display
        )
      },
      dismiss: { await controller.dismiss() }
    )
  }()

  static let testValue = WorkspaceHUDClient(
    show: { _, _, _, _ in }, showOnDisplay: { _, _, _, _, _ in }, dismiss: {}
  )
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
  /// One live HUD per screen, keyed by display id — a cross-monitor switch
  /// shows two at once (the workspace name on the focused monitor, a
  /// "focus moved" note on the one being left), so a single shared panel
  /// would clobber one of them.
  private struct Entry {
    let panel: NSPanel
    var hideTask: Task<Void, Never>?
  }
  private var entries: [CGDirectDisplayID: Entry] = [:]
  private let debugLog: DebugLogClient

  init(debugLog: DebugLogClient) {
    self.debugLog = debugLog
  }

  func show(
    name: String, symbolIconName: String?, subtitle: String?,
    durationMs: Int, display: DisplayName?
  ) {
    debugLog.log(
      "HUDDiag",
      "show title=\(name) hint=\(subtitle != nil) durationMs=\(durationMs) "
        + "display=\(display?.name ?? "cursor")"
    )
    guard let screen = resolveScreen(display), let screenID = screen.displayID else { return }
    // Every HUD gets a *fresh* panel (per screen): once a panel has been
    // ordered out, a later window-alpha animation on it completes instantly
    // (no fade). Retiring the old panel *for this screen* and never reusing it
    // keeps each fade on first-show state; panels on other screens are left
    // alone so simultaneous HUDs coexist.
    entries[screenID]?.hideTask?.cancel()
    entries[screenID]?.panel.orderOut(nil)

    let panel = makePanel()
    panel.contentView = NSHostingView(
      rootView: WorkspaceHUDView(name: name, symbolIconName: symbolIconName, subtitle: subtitle)
    )
    layout(panel, hasSubtitle: subtitle != nil, on: screen)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    let hideTask = Task { [weak self] in
      // A hint line takes longer to read than a glanceable title.
      let duration = max(100, subtitle == nil ? durationMs : durationMs * 2)
      try? await Task.sleep(for: .milliseconds(duration))
      guard !Task.isCancelled else { return }
      self?.fadeOut(screenID)
    }
    entries[screenID] = Entry(panel: panel, hideTask: hideTask)
  }

  func dismiss() {
    for screenID in Array(entries.keys) { fadeOut(screenID) }
  }

  private func fadeOut(_ screenID: CGDirectDisplayID) {
    guard let entry = entries.removeValue(forKey: screenID) else { return }
    entry.hideTask?.cancel()
    let panel = entry.panel
    // Fade the content *view*, not the window: NSWindow's alpha animator
    // proved unreliable for this panel configuration — after the first fade of
    // the process, later animations completed instantly (no fade), fresh panel
    // or not. The view animator is plain Core Animation and behaves every time.
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
      // CA completion handlers fire on the main thread; assert it so the
      // main-actor `orderOut` is well-typed under strict concurrency.
      MainActor.assumeIsolated { panel?.orderOut(nil) }
    }
  }

  /// The screen a HUD targets: a named display (pinned), else the screen the
  /// cursor is on — `NSScreen.main` follows the key window, which after a
  /// workspace switch can be a different display than the user is looking at.
  private func resolveScreen(_ display: DisplayName?) -> NSScreen? {
    if let display {
      return DisplayResolver.screenOrPrimary(for: display)
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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

  private func layout(_ panel: NSPanel, hasSubtitle: Bool, on screen: NSScreen) {
    let size = NSSize(width: hasSubtitle ? 340 : 280, height: hasSubtitle ? 174 : 150)
    panel.setContentSize(size)
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
