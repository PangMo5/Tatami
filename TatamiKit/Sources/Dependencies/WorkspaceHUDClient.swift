// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import Observation
import SwiftUI

// MARK: - WindowSwitcherInteraction

public enum WindowSwitcherInteraction: Equatable, Sendable {
  case move(CycleDirection)
  case select(WindowKey)
  case commitSelected
  case commit(WindowKey)
  case cancel
}

// MARK: - WindowSwitcherIndicators

public struct WindowSwitcherIndicators: Equatable, Sendable {
  public init(
    isFloating: Bool = false,
    isShared: Bool = false,
    isBorrowed: Bool = false,
    isFocused: Bool = false,
    isFullscreen: Bool = false,
  ) {
    self.isFloating = isFloating
    self.isShared = isShared
    self.isBorrowed = isBorrowed
    self.isFocused = isFocused
    self.isFullscreen = isFullscreen
  }

  public var isFloating: Bool
  public var isShared: Bool
  public var isBorrowed: Bool
  public var isFocused: Bool
  public var isFullscreen: Bool
}

// MARK: - WorkspaceHUDClient

/// Shows a brief, centered overlay with a title and icon — visual feedback
/// for hotkey/menu actions. An optional subtitle carries a follow-up hint
/// (e.g. the shortcut that removes a just-unfloated app from Shared Apps);
/// HUDs with a subtitle linger a little longer so the hint is readable.
/// Auto-dismisses; re-showing resets the timer.
@DependencyClient
struct WorkspaceHUDClient: Sendable {
  /// Arrow/Return/Escape and pointer selections from an active held-modifier
  /// switcher. The activation reducer remains the owner of selection + commit.
  var windowSwitcherEvents: @Sendable () -> AsyncStream<WindowSwitcherInteraction> = {
    .finished
  }

  var show: @Sendable (
    _ name: String,
    _ symbolIconName: String?,
    _ subtitle: String?,
    _ durationMs: Int,
  ) async -> Void
  /// Like `show`, but anchored to a specific display instead of the cursor's
  /// screen (`nil` → cursor's screen, same as `show`). Used to announce a
  /// focus move on the *old* monitor when a switch crosses displays.
  var showOnDisplay: @Sendable (
    _ name: String,
    _ symbolIconName: String?,
    _ subtitle: String?,
    _ durationMs: Int,
    _ display: DisplayName?,
  ) async -> Void
  /// Native Cmd-Tab-style switcher for Tatami's app/window cycle. App-level
  /// mode highlights by bundle id; window-level mode highlights the exact
  /// `WindowKey`, so multiple windows from one app remain distinguishable.
  var showWindowSwitcher: @Sendable (
    _ windows: [WindowKey],
    _ selected: WindowKey,
    _ byWindow: Bool,
    _ indicators: [WindowKey: WindowSwitcherIndicators],
    _ autoDismissAfterMs: Int?,
    _ display: DisplayName?,
  ) async -> Void
  /// Commit a native-style switcher session: begin its fade immediately on
  /// the display it occupied. Other HUD kinds on that screen are untouched.
  var dismissWindowSwitcher: @Sendable (_ display: DisplayName?) async -> Void
  /// Fade out the current HUD immediately (e.g. cancelling borrow mode).
  var dismiss: @Sendable () async -> Void
}

// MARK: DependencyKey

extension WorkspaceHUDClient: DependencyKey {
  static let liveValue: WorkspaceHUDClient = {
    @Dependency(\.debugLog) var debugLog
    let (windowSwitcherEvents, continuation) =
      AsyncStream<WindowSwitcherInteraction>.makeStream()
    let controller = WorkspaceHUDController(
      debugLog: debugLog,
      emitWindowSwitcherInteraction: { continuation.yield($0) },
    )
    return WorkspaceHUDClient(
      windowSwitcherEvents: { windowSwitcherEvents },
      show: { name, icon, subtitle, durationMs in
        await controller.show(
          name: name,
          symbolIconName: icon,
          subtitle: subtitle,
          durationMs: durationMs,
          display: nil,
        )
      },
      showOnDisplay: { name, icon, subtitle, durationMs, display in
        await controller.show(
          name: name,
          symbolIconName: icon,
          subtitle: subtitle,
          durationMs: durationMs,
          display: display,
        )
      },
      showWindowSwitcher: { windows, selected, byWindow, indicators, autoDismissAfterMs, display in
        await controller.showWindowSwitcher(
          windows: windows,
          selected: selected,
          byWindow: byWindow,
          indicators: indicators,
          autoDismissAfterMs: autoDismissAfterMs,
          display: display,
        )
      },
      dismissWindowSwitcher: { display in
        await controller.dismissWindowSwitcher(display: display)
      },
      dismiss: { await controller.dismiss() },
    )
  }()

  static let testValue = WorkspaceHUDClient(
    windowSwitcherEvents: { .finished },
    show: { _, _, _, _ in },
    showOnDisplay: { _, _, _, _, _ in },
    showWindowSwitcher: { _, _, _, _, _, _ in },
    dismissWindowSwitcher: { _ in },
    dismiss: { },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var workspaceHUD: WorkspaceHUDClient {
    get { self[WorkspaceHUDClient.self] }
    set { self[WorkspaceHUDClient.self] = newValue }
  }
}

// MARK: - HUDLayout

private enum HUDLayout {

  // MARK: Internal

  static let actionShadowPadding: CGFloat = 12
  static let windowSwitcherShadowRadius: CGFloat = 8
  static let windowSwitcherShadowYOffset: CGFloat = 4
  static let maximumActionSurfaceSize = NSSize(width: 404, height: 70)

  /// `NSHostingView` clips drawing outside its panel. Keep the transparent
  /// panel outset coupled to the widest shadow extent so a future style tweak
  /// cannot reintroduce a hard rectangular cutoff.
  static var windowSwitcherShadowPadding: CGFloat {
    windowSwitcherShadowRadius + abs(windowSwitcherShadowYOffset)
  }

  static var actionPanelSize: NSSize {
    NSSize(
      width: maximumActionSurfaceSize.width + actionShadowPadding * 2,
      height: maximumActionSurfaceSize.height + actionShadowPadding * 2,
    )
  }

  static func actionSurfaceSize(name: String, subtitle: String?) -> NSSize {
    let titleWidth = textWidth(
      name,
      font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
    )
    let contentSpacing: CGFloat = 28 + 32 + 11
    let width: CGFloat
    if let subtitle {
      let subtitleWidth = textWidth(
        subtitle,
        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
      )
      width = min(max(max(titleWidth, subtitleWidth) + contentSpacing, 240), 404)
    } else {
      width = min(max(titleWidth + contentSpacing, 142), 300)
    }
    return NSSize(
      width: width.rounded(.up),
      height: subtitle == nil ? 52 : 70,
    )
  }

  static func windowSwitcherPanelSize(
    itemCount: Int,
    byWindow: Bool,
    visibleWidth: CGFloat,
  ) -> NSSize {
    let idealSurfaceWidth = CGFloat(itemCount) * 82
      + CGFloat(max(0, itemCount - 1)) * 8
      + 28
    let maximumSurfaceWidth = max(
      280,
      visibleWidth - 96 - windowSwitcherShadowPadding * 2,
    )
    // A two-item cycle is common and should read as one compact island rather
    // than two cards followed by an empty third-card slot.
    let minimumSurfaceWidth: CGFloat = itemCount <= 2 ? 164 : 280
    let surfaceWidth = min(max(minimumSurfaceWidth, idealSurfaceWidth), maximumSurfaceWidth)
    let surfaceHeight: CGFloat = byWindow ? 160 : 140
    return NSSize(
      width: surfaceWidth + windowSwitcherShadowPadding * 2,
      height: surfaceHeight + windowSwitcherShadowPadding * 2,
    )
  }

  // MARK: Private

  private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }

}

// MARK: - ActionHUDContent

private struct ActionHUDContent: Equatable {
  let revision: Int
  let name: String
  let symbolIconName: String?
  let subtitle: String?
}

// MARK: - ActionHUDContentModel

@MainActor
@Observable
private final class ActionHUDContentModel {

  // MARK: Lifecycle

  init(name: String, symbolIconName: String?, subtitle: String?) {
    value = ActionHUDContent(
      revision: 0,
      name: name,
      symbolIconName: symbolIconName,
      subtitle: subtitle,
    )
  }

  // MARK: Internal

  private(set) var value: ActionHUDContent

  func update(name: String, symbolIconName: String?, subtitle: String?) {
    let current = value
    guard
      current.name != name
      || current.symbolIconName != symbolIconName
      || current.subtitle != subtitle
    else { return }
    value = ActionHUDContent(
      revision: current.revision &+ 1,
      name: name,
      symbolIconName: symbolIconName,
      subtitle: subtitle,
    )
  }

}

// MARK: - HUDPresentationModel

@MainActor
@Observable
private final class HUDPresentationModel {

  private(set) var isPresented = false

  func setPresented(_ isPresented: Bool) {
    self.isPresented = isPresented
  }

}

// MARK: - WindowSwitcherContent

private struct WindowSwitcherContent {
  let items: [WindowSwitcherItem]
  let selected: WindowKey
  let byWindow: Bool
  let surfaceSize: NSSize
}

// MARK: - WindowSwitcherContentModel

@MainActor
@Observable
private final class WindowSwitcherContentModel {

  // MARK: Lifecycle

  init(
    items: [WindowSwitcherItem],
    selected: WindowKey,
    byWindow: Bool,
    surfaceSize: NSSize,
  ) {
    value = WindowSwitcherContent(
      items: items,
      selected: selected,
      byWindow: byWindow,
      surfaceSize: surfaceSize,
    )
  }

  // MARK: Internal

  private(set) var value: WindowSwitcherContent

  func update(
    items: [WindowSwitcherItem],
    selected: WindowKey,
    byWindow: Bool,
    surfaceSize: NSSize,
  ) {
    value = WindowSwitcherContent(
      items: items,
      selected: selected,
      byWindow: byWindow,
      surfaceSize: surfaceSize,
    )
  }

}

// MARK: - WorkspaceHUDController

@MainActor
private final class WorkspaceHUDController {

  // MARK: Lifecycle

  init(
    debugLog: DebugLogClient,
    emitWindowSwitcherInteraction: @escaping @Sendable (WindowSwitcherInteraction) -> Void,
  ) {
    self.debugLog = debugLog
    self.emitWindowSwitcherInteraction = emitWindowSwitcherInteraction
    windowSwitcherInputTap = WindowSwitcherInputTap(
      debugLog: debugLog,
      emit: emitWindowSwitcherInteraction,
    )
  }

  // MARK: Internal

  func show(
    name: String,
    symbolIconName: String?,
    subtitle: String?,
    durationMs: Int,
    display: DisplayName?,
  ) {
    debugLog.log(
      "HUDDiag",
      "show title=\(name) hint=\(subtitle != nil) durationMs=\(durationMs) "
        + "display=\(display?.name ?? "cursor")",
    )
    guard let screen = resolveScreen(display), let screenID = screen.displayID else { return }
    let entry: Entry
    if
      let current = entries[screenID],
      current.kind == .action,
      let currentContent = current.actionContent
    {
      current.hideTask?.cancel()
      current.dismissTask?.cancel()
      current.dismissTask = nil
      currentContent.update(name: name, symbolIconName: symbolIconName, subtitle: subtitle)
      entry = current
    } else {
      retireEntry(on: screenID)
      let panel = makePanel(acceptsMouseEvents: false)
      let content = ActionHUDContentModel(
        name: name,
        symbolIconName: symbolIconName,
        subtitle: subtitle,
      )
      let presentation = HUDPresentationModel()
      layoutActionHUD(panel, on: screen)
      let hostingView = makeHostingView(
        rootView: WorkspaceHUDView(
          content: content,
          presentation: presentation,
        )
      )
      panel.contentView = hostingView
      entry = Entry(
        panel: panel,
        kind: .action,
        presentation: presentation,
        actionContent: content,
        windowSwitcherContent: nil,
      )
      entries[screenID] = entry
    }
    layoutActionHUD(entry.panel, on: screen)
    entry.panel.alphaValue = 1
    entry.panel.orderFrontRegardless()
    if !entry.isPresented {
      entry.isPresented = true
      present(entry, on: screenID)
    }

    entry.hideTask = Task { [weak self] in
      // A hint line takes longer to read than a glanceable title.
      let duration = max(100, subtitle == nil ? durationMs : durationMs * 2)
      do {
        try await Task.sleep(for: .milliseconds(duration))
      } catch {
        return
      }
      self?.fadeOut(screenID)
    }
  }

  func showWindowSwitcher(
    windows: [WindowKey],
    selected: WindowKey,
    byWindow: Bool,
    indicators: [WindowKey: WindowSwitcherIndicators],
    autoDismissAfterMs: Int?,
    display: DisplayName?,
  ) {
    guard
      !windows.isEmpty,
      let screen = resolveScreen(display),
      let screenID = screen.displayID
    else { return }
    debugLog.log(
      "HUDDiag",
      "window switcher count=\(windows.count) byWindow=\(byWindow) "
        + "selected=\(selected.bundleId)#\(selected.windowID) "
        + "display=\(display?.name ?? "cursor")",
    )
    let items = windowSwitcherItems(
      windows,
      byWindow: byWindow,
      indicators: indicators,
    )
    let panelSize = HUDLayout.windowSwitcherPanelSize(
      itemCount: items.count,
      byWindow: byWindow,
      visibleWidth: screen.visibleFrame.width,
    )
    let surfaceSize = NSSize(
      width: panelSize.width - HUDLayout.windowSwitcherShadowPadding * 2,
      height: panelSize.height - HUDLayout.windowSwitcherShadowPadding * 2,
    )
    let entry: Entry
    if
      let current = entries[screenID],
      current.kind == .windowSwitcher,
      let content = current.windowSwitcherContent
    {
      current.hideTask?.cancel()
      current.dismissTask?.cancel()
      current.dismissTask = nil
      content.update(
        items: items,
        selected: selected,
        byWindow: byWindow,
        surfaceSize: surfaceSize,
      )
      entry = current
    } else {
      retireEntry(on: screenID)
      let panel = makePanel(acceptsMouseEvents: autoDismissAfterMs == nil)
      let content = WindowSwitcherContentModel(
        items: items,
        selected: selected,
        byWindow: byWindow,
        surfaceSize: surfaceSize,
      )
      let presentation = HUDPresentationModel()
      layoutWindowSwitcher(panel, size: panelSize, on: screen)
      let hostingView = makeHostingView(
        rootView: WindowSwitcherHUDView(
          content: content,
          presentation: presentation,
          onSelect: emitWindowSwitcherInteraction,
        )
      )
      panel.contentView = hostingView
      entry = Entry(
        panel: panel,
        kind: .windowSwitcher,
        presentation: presentation,
        actionContent: nil,
        windowSwitcherContent: content,
      )
      entries[screenID] = entry
    }

    let isInteractive = autoDismissAfterMs == nil
    entry.panel.ignoresMouseEvents = !isInteractive
    entry.panel.acceptsMouseMovedEvents = isInteractive
    setWindowSwitcherInputEnabled(isInteractive, on: screenID)
    layoutWindowSwitcher(entry.panel, size: panelSize, on: screen)
    entry.panel.alphaValue = 1
    entry.panel.orderFrontRegardless()
    if !entry.isPresented {
      entry.isPresented = true
      present(entry, on: screenID)
    }

    entry.hideTask = autoDismissAfterMs.map { durationMs in
      Task { [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(max(300, durationMs)))
        } catch {
          return
        }
        self?.fadeOut(screenID)
      }
    }
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

  // MARK: Private

  /// One live HUD per screen, keyed by display id — a cross-monitor switch
  /// shows two at once (the workspace name on the focused monitor, a
  /// "focus moved" note on the one being left), so a single shared panel
  /// would clobber one of them.
  private final class Entry {

    // MARK: Lifecycle

    init(
      panel: NSPanel,
      kind: Kind,
      presentation: HUDPresentationModel,
      actionContent: ActionHUDContentModel?,
      windowSwitcherContent: WindowSwitcherContentModel?,
    ) {
      self.panel = panel
      self.kind = kind
      self.presentation = presentation
      self.actionContent = actionContent
      self.windowSwitcherContent = windowSwitcherContent
    }

    // MARK: Internal

    enum Kind {
      case action
      case windowSwitcher
    }

    let panel: NSPanel
    var hideTask: Task<Void, Never>?
    var dismissTask: Task<Void, Never>?
    var isPresented = false
    let kind: Kind
    let presentation: HUDPresentationModel
    let actionContent: ActionHUDContentModel?
    let windowSwitcherContent: WindowSwitcherContentModel?

  }

  private var entries = [CGDirectDisplayID: Entry]()
  private var interactiveWindowSwitcherScreenID: CGDirectDisplayID?
  private var appMetadataByBundleID = [String: (name: String, icon: NSImage)]()
  private var windowTitlesByKey = [WindowKey: String]()
  private var resolvedWindowTitleKeys = Set<WindowKey>()
  private var windowTitlesUpdatedAt = Date.distantPast
  private let debugLog: DebugLogClient
  private let emitWindowSwitcherInteraction: @Sendable (WindowSwitcherInteraction) -> Void
  private let windowSwitcherInputTap: WindowSwitcherInputTap

  private func fadeOut(_ screenID: CGDirectDisplayID) {
    guard let entry = entries[screenID], entry.isPresented else { return }
    entry.hideTask?.cancel()
    entry.hideTask = nil
    entry.dismissTask?.cancel()
    if entry.kind == .windowSwitcher {
      setWindowSwitcherInputEnabled(false, on: screenID)
    }
    debugLog.log("HUDDiag", "dismiss animation start")
    entry.isPresented = false
    entry.presentation.setPresented(false)
    entry.dismissTask = Task { @MainActor [weak self, weak entry] in
      do {
        let delayMs = entry?.kind == .windowSwitcher ? 180 : 320
        try await Task.sleep(for: .milliseconds(delayMs))
      } catch {
        return
      }
      guard
        let self,
        let entry,
        entries[screenID] === entry
      else { return }
      debugLog.log("HUDDiag", "dismiss animation done")
      entry.panel.orderOut(nil)
      entry.dismissTask = nil
      if entry.kind == .windowSwitcher {
        entries.removeValue(forKey: screenID)
      }
    }
  }

  private func retireEntry(on screenID: CGDirectDisplayID) {
    guard let entry = entries.removeValue(forKey: screenID) else { return }
    entry.hideTask?.cancel()
    entry.dismissTask?.cancel()
    if entry.kind == .windowSwitcher {
      setWindowSwitcherInputEnabled(false, on: screenID)
    }
    entry.panel.orderOut(nil)
  }

  private func present(_ entry: Entry, on screenID: CGDirectDisplayID) {
    // Let the hosting view commit its initial hidden state before toggling the
    // observable presentation flag. Updating it in the construction pass can
    // make SwiftUI render only the final state, which drops the entrance
    // spring entirely.
    entry.panel.contentView?.layoutSubtreeIfNeeded()
    Task { @MainActor [weak self, weak entry] in
      await Task.yield()
      guard
        let self,
        let entry,
        entries[screenID] === entry,
        entry.isPresented
      else { return }
      entry.presentation.setPresented(true)
    }
  }

  private func setWindowSwitcherInputEnabled(
    _ enabled: Bool,
    on screenID: CGDirectDisplayID,
  ) {
    if enabled {
      interactiveWindowSwitcherScreenID = screenID
      windowSwitcherInputTap.setEnabled(true)
    } else if interactiveWindowSwitcherScreenID == screenID {
      interactiveWindowSwitcherScreenID = nil
      windowSwitcherInputTap.setEnabled(false)
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

  private func makePanel(acceptsMouseEvents: Bool) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false,
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.ignoresMouseEvents = !acceptsMouseEvents
    panel.acceptsMouseMovedEvents = acceptsMouseEvents
    panel.becomesKeyOnlyIfNeeded = true
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
    return panel
  }

  private func makeHostingView<Content: View>(rootView: Content) -> NSHostingView<Content> {
    NSHostingView(rootView: rootView)
  }

  private func layoutActionHUD(_ panel: NSPanel, on screen: NSScreen) {
    let size = HUDLayout.actionPanelSize
    let visible = screen.visibleFrame
    // The compact island drops from the top edge, close to where macOS places
    // transient system feedback without covering the user's working content.
    let origin = NSPoint(
      x: visible.midX - size.width / 2,
      y: visible.maxY - size.height - 22,
    )
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
  }

  private func layoutWindowSwitcher(
    _ panel: NSPanel,
    size: NSSize,
    on screen: NSScreen,
  ) {
    let visible = screen.visibleFrame
    // A switcher is an expanded selection island and follows native Cmd-Tab
    // at screen center rather than competing with the glanceable top HUD.
    panel.setFrame(
      NSRect(
        origin: NSPoint(
          x: visible.midX - size.width / 2,
          y: visible.midY - size.height / 2,
        ),
        size: size,
      ),
      display: false,
    )
  }

  private func windowSwitcherItems(
    _ windows: [WindowKey],
    byWindow: Bool,
    indicators: [WindowKey: WindowSwitcherIndicators],
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
            ?? NSImage(),
        )
        appMetadataByBundleID[key.bundleId] = appMetadata
      }
      return WindowSwitcherItem(
        key: key,
        appName: appMetadata.name,
        windowTitle: windowTitlesByKey[key],
        icon: appMetadata.icon,
        indicators: indicators[key] ?? WindowSwitcherIndicators(),
      )
    }
  }

  /// One WindowServer snapshot for the whole strip. This stays presentation-
  /// only and avoids serial AX title calls on the latency-sensitive focus path.
  private func windowTitles(_ windows: [WindowKey]) -> [WindowKey: String] {
    let wanted = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID,
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

// MARK: - WindowSwitcherInputTap

/// Active only while a held-modifier switcher session is visible. Recognized
/// navigation keys are consumed so they do not leak into the focused app.
private final class WindowSwitcherInputTap: @unchecked Sendable {

  // MARK: Lifecycle

  init(
    debugLog: DebugLogClient,
    emit: @escaping @Sendable (WindowSwitcherInteraction) -> Void,
  ) {
    self.debugLog = debugLog
    self.emit = emit
  }

  // MARK: Internal

  func setEnabled(_ enabled: Bool) {
    EventTapThread.shared.perform { [self] in
      if enabled, eventTap == nil {
        install()
      } else if !enabled, eventTap != nil {
        teardown()
      }
    }
  }

  // MARK: Fileprivate

  fileprivate func reEnable() {
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: true)
    }
  }

  /// Returns `true` when the keystroke belongs to the switcher and must not
  /// reach the previously focused application.
  fileprivate func handle(keyCode: Int) -> Bool {
    switch keyCode {
    case 123,
         126:
      emit(.move(.previous))
    case 124,
         125:
      emit(.move(.next))
    case 36,
         76:
      emit(.commitSelected)
    case 53:
      emit(.cancel)
    default:
      return false
    }
    return true
  }

  // MARK: Private

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let debugLog: DebugLogClient
  private let emit: @Sendable (WindowSwitcherInteraction) -> Void

  /// Runs on the event-tap thread.
  private func install() {
    let mask =
      (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        | (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let info = Unmanaged.passUnretained(self).toOpaque()
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: windowSwitcherInputTapCallback,
        userInfo: info,
      )
    else {
      debugLog.log("HUDDiag", "window switcher input tap create FAILED")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      debugLog.log("HUDDiag", "window switcher input source create FAILED")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    debugLog.log("HUDDiag", "window switcher input armed")
  }

  private func teardown() {
    if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
    if let runLoopSource { EventTapThread.shared.removeSource(runLoopSource) }
    eventTap = nil
    runLoopSource = nil
    debugLog.log("HUDDiag", "window switcher input disarmed")
  }

}

private func windowSwitcherInputTapCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?,
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<WindowSwitcherInputTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .keyDown:
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    return tap.handle(keyCode: keyCode) ? nil : Unmanaged.passUnretained(event)

  case .tapDisabledByTimeout,
       .tapDisabledByUserInput:
    tap.reEnable()
    return Unmanaged.passUnretained(event)

  default:
    return Unmanaged.passUnretained(event)
  }
}

// MARK: - WorkspaceHUDView

@MainActor
private struct WorkspaceHUDView: View {

  // MARK: Internal

  let content: ActionHUDContentModel
  let presentation: HUDPresentationModel

  var body: some View {
    let value = content.value
    let surfaceSize = HUDLayout.actionSurfaceSize(
      name: value.name,
      subtitle: value.subtitle,
    )
    ZStack(alignment: .top) {
      HUDGlassSurface(surface: Capsule()) {
        Color.clear
          .frame(width: surfaceSize.width, height: surfaceSize.height)
      }
      .animation(
        reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.78),
        value: surfaceSize,
      )
      .shadow(color: .black.opacity(0.24), radius: 12, y: 6)

      ZStack(alignment: .leading) {
        HStack(spacing: 11) {
          ZStack {
            Circle()
              .fill(Color.accentColor.opacity(0.16))
            Circle()
              .strokeBorder(Color.accentColor.opacity(0.30), lineWidth: 1)
            Image(systemName: value.symbolIconName ?? "square.stack.3d.up.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(.tint)
              .symbolRenderingMode(.hierarchical)
          }
          .frame(width: 32, height: 32)

          VStack(alignment: .leading, spacing: 2) {
            Text(value.name)
              .font(.callout.weight(.semibold))
              .lineLimit(1)
            if let subtitle = value.subtitle {
              Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(value.revision)
        .transition(.opacity)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(
        width: surfaceSize.width,
        height: surfaceSize.height,
        alignment: .leading,
      )
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.14),
        value: value.revision,
      )
    }
    .frame(
      width: HUDLayout.maximumActionSurfaceSize.width,
      height: HUDLayout.maximumActionSurfaceSize.height,
      alignment: .top,
    )
    .padding(HUDLayout.actionShadowPadding)
    .frame(width: HUDLayout.actionPanelSize.width, height: HUDLayout.actionPanelSize.height)
    .modifier(
      ActionHUDPresentationModifier(isPresented: presentation.isPresented)
    )
    .accessibilityElement(children: .combine)
  }

  // MARK: Private

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

}

// MARK: - ActionHUDPresentationModifier

private struct ActionHUDPresentationModifier: ViewModifier {

  // MARK: Internal

  let isPresented: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isPresented ? 1 : 0)
      .offset(y: isPresented ? 0 : -10)
      .scaleEffect(
        x: isPresented ? 1 : 0.97,
        y: isPresented ? 1 : 0.94,
        anchor: .top,
      )
      .animation(
        reduceMotion
          ? nil
          : .spring(
            response: 0.28,
            dampingFraction: 0.78,
          ),
        value: isPresented,
      )
  }

  // MARK: Private

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

}

// MARK: - WindowSwitcherPresentationModifier

private struct WindowSwitcherPresentationModifier: ViewModifier {

  // MARK: Internal

  let isPresented: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isPresented ? 1 : 0)
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.14),
        value: isPresented,
      )
  }

  // MARK: Private

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

}

// MARK: - HUDGlassSurface

private struct HUDGlassSurface<Content: View, Surface: InsettableShape>: View {
  let surface: Surface
  @ViewBuilder let content: Content

  var body: some View {
    if #available(macOS 26.0, *) {
      content
        .glassEffect(.regular, in: surface)
    } else {
      content
        .background(.regularMaterial, in: surface)
        .overlay(
          surface
            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
    }
  }
}

// MARK: - WindowSwitcherItem

private struct WindowSwitcherItem: Identifiable {
  let key: WindowKey
  let appName: String
  let windowTitle: String?
  let icon: NSImage
  let indicators: WindowSwitcherIndicators

  var id: WindowKey {
    key
  }
}

// MARK: - WindowSwitcherHUDView

@MainActor
private struct WindowSwitcherHUDView: View {
  let content: WindowSwitcherContentModel
  let presentation: HUDPresentationModel
  let onSelect: @Sendable (WindowSwitcherInteraction) -> Void

  var body: some View {
    let value = content.value
    let selectedItem = value.items.first {
      value.byWindow
        ? $0.key == value.selected
        : $0.key.bundleId == value.selected.bundleId
    }?.key

    HUDGlassSurface(surface: RoundedRectangle(cornerRadius: 24, style: .continuous)) {
      VStack(spacing: 0) {
        WindowSwitcherHeader(
          byWindow: value.byWindow,
          isCompact: value.surfaceSize.width < 240,
        )

        ScrollViewReader { proxy in
          ScrollView(.horizontal) {
            HStack(spacing: 6) {
              ForEach(value.items) { item in
                WindowSwitcherItemView(
                  item: item,
                  isSelected: item.key == selectedItem,
                  showsWindowTitle: value.byWindow,
                  onHighlight: { onSelect(.select(item.key)) },
                  onSelect: { onSelect(.commit(item.key)) },
                )
              }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
          }
          .scrollIndicators(.hidden)
          .onAppear {
            if let selectedItem { proxy.scrollTo(selectedItem, anchor: .center) }
          }
          .onChange(of: selectedItem) { _, item in
            if let item { proxy.scrollTo(item, anchor: .center) }
          }
        }
      }
      .frame(width: value.surfaceSize.width, height: value.surfaceSize.height)
    }
    .shadow(
      color: .black.opacity(0.32),
      radius: HUDLayout.windowSwitcherShadowRadius,
      y: HUDLayout.windowSwitcherShadowYOffset,
    )
    .padding(HUDLayout.windowSwitcherShadowPadding)
    .modifier(
      WindowSwitcherPresentationModifier(isPresented: presentation.isPresented)
    )
  }
}

// MARK: - WindowSwitcherHeader

@MainActor
private struct WindowSwitcherHeader: View {
  let byWindow: Bool
  let isCompact: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(
        systemName: byWindow
          ? "macwindow.on.rectangle"
          : "square.stack.3d.up"
      )
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.tint)
      .symbolRenderingMode(.hierarchical)
      .accessibilityHidden(true)

      Text(byWindow ? "Window cycle" : "App cycle")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      Spacer(minLength: 12)

      HStack(spacing: 5) {
        if !isCompact {
          WindowSwitcherKeyCap("←  →")
        }
        WindowSwitcherKeyCap("↩")
      }
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 14)
    .frame(height: 32)
  }
}

// MARK: - WindowSwitcherKeyCap

@MainActor
private struct WindowSwitcherKeyCap: View {
  init(_ label: String) {
    self.label = label
  }

  let label: String

  var body: some View {
    Text(label)
      .font(.caption2.monospaced().weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .frame(height: 18)
      .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
      }
  }
}

// MARK: - WindowSwitcherItemView

@MainActor
private struct WindowSwitcherItemView: View {

  // MARK: Internal

  let item: WindowSwitcherItem
  let isSelected: Bool
  let showsWindowTitle: Bool
  let onHighlight: @MainActor () -> Void
  let onSelect: @MainActor () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(spacing: 5) {
        WindowSwitcherAppIcon(
          icon: item.icon,
          indicators: item.indicators,
        )
        Text(item.appName)
          .font(.caption.weight(.medium))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .lineLimit(1)
        if showsWindowTitle {
          Text(item.windowTitle ?? "Window")
            .font(.caption2)
            .foregroundStyle(isSelected ? .secondary : .tertiary)
            .lineLimit(1)
        }
      }
      .frame(width: 84, height: showsWindowTitle ? 110 : 90)
      .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(backgroundStyle)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            borderStyle,
            lineWidth: 1,
          )
      )
      .shadow(
        color: isSelected ? Color.accentColor.opacity(0.2) : .clear,
        radius: 10,
        y: 3,
      )
      .scaleEffect(isSelected ? 1.025 : (isHovering ? 1.012 : 1))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      isHovering = hovering
      if hovering {
        onHighlight()
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovering)
    .animation(
      reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.86),
      value: isSelected,
    )
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityLabel(item.appName)
    .accessibilityValue(indicatorAccessibilityValue)
    .accessibilityHint("Select")
  }

  // MARK: Private

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  private var backgroundStyle: Color {
    if isSelected { return Color.accentColor.opacity(0.13) }
    if isHovering { return Color.white.opacity(0.06) }
    return .clear
  }

  private var borderStyle: Color {
    if isSelected { return Color.accentColor.opacity(0.48) }
    if isHovering { return Color.white.opacity(0.16) }
    return .clear
  }

  private var indicatorAccessibilityValue: String {
    var values = [String]()
    if item.indicators.isFloating { values.append(String(localized: "Floating")) }
    if item.indicators.isShared { values.append(String(localized: "Shared Apps")) }
    if item.indicators.isBorrowed { values.append(String(localized: "Borrow")) }
    if item.indicators.isFocused { values.append(String(localized: "Focused")) }
    if item.indicators.isFullscreen { values.append(String(localized: "Fullscreen")) }
    return values.formatted()
  }

}

// MARK: - WindowSwitcherAppIcon

@MainActor
private struct WindowSwitcherAppIcon: View {
  let icon: NSImage
  let indicators: WindowSwitcherIndicators

  var body: some View {
    Image(nsImage: icon)
      .resizable()
      .scaledToFit()
      .frame(width: 54, height: 54)
      .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
      .overlay(alignment: .topTrailing) {
        if indicators.isFocused {
          Circle()
            .fill(Color.accentColor)
            .stroke(.white.opacity(0.9), lineWidth: 1.5)
            .frame(width: 8, height: 8)
            .shadow(color: Color.accentColor.opacity(0.55), radius: 3)
            .offset(x: 2, y: -2)
            .accessibilityHidden(true)
        }
      }
      .overlay(alignment: .bottomLeading) {
        if indicators.isShared || indicators.isBorrowed {
          WindowSwitcherIndicatorGroup {
            if indicators.isShared {
              WindowSwitcherIndicatorSymbol(
                symbol: "person.2.fill",
                color: .blue,
              )
            }
            if indicators.isBorrowed {
              WindowSwitcherIndicatorSymbol(
                symbol: "rectangle.righthalf.inset.filled",
                color: .purple,
              )
            }
          }
          .offset(x: -3, y: 2)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if indicators.isFloating || indicators.isFullscreen {
          WindowSwitcherIndicatorGroup {
            if indicators.isFloating {
              WindowSwitcherIndicatorSymbol(
                symbol: "rectangle.on.rectangle",
                color: .orange,
              )
            }
            if indicators.isFullscreen {
              WindowSwitcherIndicatorSymbol(
                symbol: "arrow.up.left.and.arrow.down.right",
                color: .cyan,
              )
            }
          }
          .offset(x: 3, y: 2)
        }
      }
  }
}

// MARK: - WindowSwitcherIndicatorGroup

@MainActor
private struct WindowSwitcherIndicatorGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 2) {
      content
    }
    .padding(.horizontal, 3)
    .frame(height: 14)
    .background(.black.opacity(0.68), in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
    .accessibilityHidden(true)
  }
}

// MARK: - WindowSwitcherIndicatorSymbol

@MainActor
private struct WindowSwitcherIndicatorSymbol: View {
  let symbol: String
  let color: Color

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 7.5, weight: .bold))
      .foregroundStyle(color)
      .frame(width: 8, height: 8)
  }
}
