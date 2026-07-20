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
  /// Native Cmd-Tab-style switcher for Tatami's app/window cycle. App-level
  /// mode highlights by bundle id; window-level mode highlights the exact
  /// `WindowKey`, so multiple windows from one app remain distinguishable.
  var showWindowSwitcher: @Sendable (
    _ windows: [WindowKey], _ selected: WindowKey, _ byWindow: Bool,
    _ autoDismissAfterMs: Int?, _ display: DisplayName?
  ) async -> Void
  /// Commit a native-style switcher session: begin its fade immediately on
  /// the display it occupied. Other HUD kinds on that screen are untouched.
  var dismissWindowSwitcher: @Sendable (_ display: DisplayName?) async -> Void
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
      showWindowSwitcher: { windows, selected, byWindow, autoDismissAfterMs, display in
        await controller.showWindowSwitcher(
          windows: windows,
          selected: selected,
          byWindow: byWindow,
          autoDismissAfterMs: autoDismissAfterMs,
          display: display
        )
      },
      dismissWindowSwitcher: { display in
        await controller.dismissWindowSwitcher(display: display)
      },
      dismiss: { await controller.dismiss() }
    )
  }()

  static let testValue = WorkspaceHUDClient(
    show: { _, _, _, _ in },
    showOnDisplay: { _, _, _, _, _ in },
    showWindowSwitcher: { _, _, _, _, _ in },
    dismissWindowSwitcher: { _ in },
    dismiss: {}
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
    enum Kind {
      case action
      case windowSwitcher
    }

    let panel: NSPanel
    var hideTask: Task<Void, Never>?
    let kind: Kind
  }
  private var entries: [CGDirectDisplayID: Entry] = [:]
  private var appMetadataByBundleID: [String: (name: String, icon: NSImage)] = [:]
  private var windowTitlesByKey: [WindowKey: String] = [:]
  private var resolvedWindowTitleKeys = Set<WindowKey>()
  private var windowTitlesUpdatedAt = Date.distantPast
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
    entries[screenID] = Entry(panel: panel, hideTask: hideTask, kind: .action)
  }

  func showWindowSwitcher(
    windows: [WindowKey],
    selected: WindowKey,
    byWindow: Bool,
    autoDismissAfterMs: Int?,
    display: DisplayName?
  ) {
    guard !windows.isEmpty,
          let screen = resolveScreen(display),
          let screenID = screen.displayID
    else { return }
    debugLog.log(
      "HUDDiag",
      "window switcher count=\(windows.count) byWindow=\(byWindow) "
        + "selected=\(selected.bundleId)#\(selected.windowID) "
        + "display=\(display?.name ?? "cursor")"
    )
    let panel: NSPanel
    if let current = entries[screenID], current.kind == .windowSwitcher {
      // Key repeat updates the existing visible switcher and replaces only its
      // hide task. Creating and ordering a new panel for every repeat makes
      // fast cycling feel laggy even when focus itself is instantaneous.
      current.hideTask?.cancel()
      panel = current.panel
    } else {
      entries[screenID]?.hideTask?.cancel()
      entries[screenID]?.panel.orderOut(nil)
      panel = makePanel()
    }

    let items = windowSwitcherItems(windows, byWindow: byWindow)
    panel.contentView = NSHostingView(
      rootView: WindowSwitcherHUDView(
        items: items,
        selected: selected,
        byWindow: byWindow
      )
    )
    layoutWindowSwitcher(panel, itemCount: items.count, byWindow: byWindow, on: screen)
    panel.alphaValue = 1
    panel.orderFrontRegardless()

    let hideTask = autoDismissAfterMs.map { durationMs in
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(max(300, durationMs)))
        guard !Task.isCancelled else { return }
        self?.fadeOut(screenID)
      }
    }
    entries[screenID] = Entry(
      panel: panel,
      hideTask: hideTask,
      kind: .windowSwitcher
    )
  }

  func dismissWindowSwitcher(display: DisplayName?) {
    guard
      let screenID = resolveScreen(display)?.displayID,
      entries[screenID]?.kind == .windowSwitcher
    else { return }
    fadeOut(screenID)
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

  private func layoutWindowSwitcher(
    _ panel: NSPanel,
    itemCount: Int,
    byWindow: Bool,
    on screen: NSScreen
  ) {
    let visible = screen.visibleFrame
    // Keep the panel exactly aligned with the SwiftUI strip: 80-point items,
    // 8-point inter-item spacing, and 14-point padding on both sides. The old
    // estimate added 8 points per item plus another 16, which accumulated as
    // a conspicuous empty area on the trailing edge.
    let idealWidth = CGFloat(itemCount) * 80
      + CGFloat(max(0, itemCount - 1)) * 8
      + 28
    let size = NSSize(
      width: min(idealWidth, max(1, visible.width - 96)),
      height: byWindow ? 168 : 148
    )
    panel.setContentSize(size)
    // Unlike Tatami's glanceable action HUD near the bottom, a switcher is a
    // temporary selection surface and follows native Cmd-Tab at screen center.
    panel.setFrameOrigin(
      NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    )
  }

  private func windowSwitcherItems(
    _ windows: [WindowKey],
    byWindow: Bool
  ) -> [WindowSwitcherItem] {
    if byWindow {
      let now = Date()
      let hasNewWindow = windows.contains { !resolvedWindowTitleKeys.contains($0) }
      if hasNewWindow || now.timeIntervalSince(windowTitlesUpdatedAt) >= 0.5 {
        // Reuse one snapshot during rapid key repeat, but refresh on the next
        // cycle sequence so document/tab title changes never stay stale for
        // the lifetime of the process.
        windowTitlesByKey = windowTitles(windows)
        resolvedWindowTitleKeys = Set(windows)
        windowTitlesUpdatedAt = now
      }
    }
    return windows.map { key in
      let appMetadata: (name: String, icon: NSImage)
      if let cached = appMetadataByBundleID[key.bundleId] {
        appMetadata = cached
      } else {
        let app = NSRunningApplication(processIdentifier: key.pid)
        let name = app?.localizedName
          ?? key.bundleId.split(separator: ".").last.map(String.init)
          ?? key.bundleId
        appMetadata = (
          name,
          app?.icon
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: name)
            ?? NSImage()
        )
        appMetadataByBundleID[key.bundleId] = appMetadata
      }
      return WindowSwitcherItem(
        key: key,
        appName: appMetadata.name,
        windowTitle: windowTitlesByKey[key],
        icon: appMetadata.icon
      )
    }
  }

  /// One WindowServer snapshot for the whole strip. This stays presentation-
  /// only and avoids serial AX title calls on the latency-sensitive focus path.
  private func windowTitles(_ windows: [WindowKey]) -> [WindowKey: String] {
    let wanted = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] ?? []
    var result = [WindowKey: String]()
    for entry in info {
      guard
        let id = entry[kCGWindowNumber as String] as? CGWindowID,
        let key = wanted[id],
        let title = entry[kCGWindowName as String] as? String,
        !title.isEmpty
      else { continue }
      result[key] = title
    }
    return result
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

private struct WindowSwitcherItem: Identifiable {
  let key: WindowKey
  let appName: String
  let windowTitle: String?
  let icon: NSImage

  var id: WindowKey { key }
}

@MainActor
private struct WindowSwitcherHUDView: View {
  let items: [WindowSwitcherItem]
  let selected: WindowKey
  let byWindow: Bool

  var body: some View {
    let selectedItem = items.first {
      byWindow ? $0.key == selected : $0.key.bundleId == selected.bundleId
    }?.key
    let content = ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 8) {
          ForEach(items) { item in
            WindowSwitcherItemView(
              item: item,
              isSelected: item.key == selectedItem,
              showsWindowTitle: byWindow
            )
          }
        }
        .padding(14)
      }
      .scrollIndicators(.hidden)
      .onAppear {
        if let selectedItem { proxy.scrollTo(selectedItem, anchor: .center) }
      }
    }

    if #available(macOS 26.0, *) {
      content.glassEffect(.regular, in: .rect(cornerRadius: 26))
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

@MainActor
private struct WindowSwitcherItemView: View {
  let item: WindowSwitcherItem
  let isSelected: Bool
  let showsWindowTitle: Bool

  var body: some View {
    VStack(spacing: 7) {
      Image(nsImage: item.icon)
        .resizable()
        .scaledToFit()
        .frame(width: 58, height: 58)
      Text(item.appName)
        .font(.caption.weight(.medium))
        .lineLimit(1)
      if showsWindowTitle {
        Text(item.windowTitle ?? "Window")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(width: 80, height: showsWindowTitle ? 126 : 106)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(isSelected ? Color.accentColor.opacity(0.28) : .clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 2)
    )
  }
}
