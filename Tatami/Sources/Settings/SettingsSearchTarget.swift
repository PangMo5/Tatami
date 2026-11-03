// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import os
import SwiftUI

extension EnvironmentValues {
  @Entry var settingsSearchSelection: String?
  @Entry var settingsSearchNavigator: SettingsSearchNavigator?
}

extension View {
  func settingsSearchTarget(_ id: String) -> some View {
    modifier(SettingsSearchTarget(id: id))
  }
}

// MARK: - SettingsSearchTarget

private struct SettingsSearchTarget: ViewModifier {

  // MARK: Internal

  let id: String

  func body(content: Content) -> some View {
    let target = content
      .background {
        if selection == id, let navigator {
          SettingsSearchScrollAnchor(id: id, navigator: navigator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    // Section identifiers propagate to every descendant control in a macOS
    // Form, replacing the controls' own identities. Only rows expose an AX id.
    if id.hasPrefix("section.") {
      target
    } else {
      target.accessibilityIdentifier("setting-\(id)")
    }
  }

  // MARK: Private

  @Environment(\.settingsSearchSelection) private var selection
  @Environment(\.settingsSearchNavigator) private var navigator

}

// MARK: - SettingsSearchNavigator

/// Grouped macOS Form rows do not consistently expose their nested IDs to
/// ScrollViewProxy. Scroll their actual AppKit anchors after layout instead.
@MainActor
final class SettingsSearchNavigator {

  // MARK: Internal

  func select(_ id: String, request: UInt64, reduceMotion: Bool) {
    cancel()
    selection = (id, request, reduceMotion)
    pendingRequest = request
    logger.debug("select id=\(id, privacy: .public) request=\(request)")
    schedule()
  }

  func cancel() {
    selection = nil
    pendingRequest = nil
    fadeWork?.cancel()
    fadeWork = nil
    flashView?.removeFromSuperview()
    flashView = nil
  }

  func register(_ view: NSView, id: String) {
    entries[ObjectIdentifier(view)] = Entry(id: id, view: view)
    schedule()
  }

  func unregister(_ view: NSView) {
    entries[ObjectIdentifier(view)] = nil
  }

  func geometryChanged() {
    schedule()
  }

  // MARK: Private

  private struct Entry {
    var id: String
    weak var view: NSView?
  }

  private var entries = [ObjectIdentifier: Entry]()
  private var selection: (id: String, request: UInt64, reduceMotion: Bool)?
  private var pendingRequest: UInt64?
  private var isScheduled = false
  private var flashView: NSView?
  private var fadeWork: DispatchWorkItem?
  private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "SettingsSearch")

  private func schedule() {
    guard pendingRequest != nil, !isScheduled else { return }
    isScheduled = true
    // Coalesce the anchors produced by one Form layout. No timing estimate or
    // retry loop: attachment/layout callbacks resume a not-yet-ready request.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isScheduled = false
      scrollIfReady()
    }
  }

  private func scrollIfReady() {
    guard let selection, pendingRequest == selection.request else { return }
    let views = entries.values.compactMap { entry -> NSView? in
      guard entry.id == selection.id, let view = entry.view, view.window != nil, !view.bounds.isEmpty else { return nil }
      return view
    }
    guard let reference = views.first, let scroll = scrollView(for: reference), let document = scroll.documentView else {
      logger.debug("waiting for target layout; anchors=\(views.count)")
      return
    }
    document.layoutSubtreeIfNeeded()
    guard pendingRequest == selection.request else { return }
    let target = views.filter { $0.window === scroll.window }.reduce(CGRect.null) {
      $0.union($1.convert($1.bounds, to: document))
    }
    guard !target.isEmpty, !target.isInfinite, document.bounds.height > 0 else { return }
    let clip = scroll.contentView
    let y = target.height > clip.bounds.height
      ? (document.isFlipped ? target.minY : target.maxY - clip.bounds.height)
      : target.midY - clip.bounds.height / 2
    var proposed = clip.bounds
    proposed.origin.y = y
    pendingRequest = nil
    clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
    scroll.reflectScrolledClipView(clip)
    logger.debug("scrolled id=\(selection.id, privacy: .public) anchors=\(views.count)")
    showFlash(document.convert(target, to: clip), in: clip, request: selection.request, reduceMotion: selection.reduceMotion)
  }

  private func scrollView(for view: NSView) -> NSScrollView? {
    if let scroll = view.enclosingScrollView {
      return scroll
    }
    // SwiftUI can host representables beside the native scrolling hierarchy.
    // Locate the vertical scroll viewport in the same containing view, using
    // the target's horizontal position to distinguish it from the sidebar.
    let x = view.convert(view.bounds, to: nil).midX
    var parent = view.superview
    while let container = parent {
      if let scroll = findScrollView(in: container, at: x) {
        return scroll
      }
      parent = container.superview
    }
    return nil
  }

  private func findScrollView(in view: NSView, at x: CGFloat) -> NSScrollView? {
    if let scroll = view as? NSScrollView {
      let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
      guard
        scroll.documentView != nil,
        viewport.minX <= x,
        x <= viewport.maxX,
        scroll.hasVerticalScroller || (scroll.documentView?.bounds.height ?? 0) > viewport.height
      else { return nil }
      return scroll
    }
    for child in view.subviews {
      if let scroll = findScrollView(in: child, at: x) {
        return scroll
      }
    }
    return nil
  }

  private func showFlash(_ rect: CGRect, in clip: NSClipView, request: UInt64, reduceMotion: Bool) {
    let flash = SettingsSearchAnchorView(frame: rect.insetBy(dx: -6, dy: -4))
    flash.setAccessibilityElement(false)
    flash.wantsLayer = true
    flash.layer?.cornerRadius = 10
    clip.effectiveAppearance.performAsCurrentDrawingAppearance {
      flash.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }
    clip.addSubview(flash, positioned: .above, relativeTo: nil)
    flashView = flash
    let work = DispatchWorkItem { [weak self, weak flash] in
      Task { @MainActor in
        guard let self, let flash, self.selection?.request == request, self.flashView === flash else { return }
        if reduceMotion {
          flash.removeFromSuperview()
          self.flashView = nil
        } else {
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            flash.animator().alphaValue = 0
          } completionHandler: { [weak self, weak flash] in
            Task { @MainActor in
              flash?.removeFromSuperview()
              if self?.flashView === flash {
                self?.flashView = nil
              }
            }
          }
        }
      }
    }
    fadeWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.75 : 0.2), execute: work)
  }

}

// MARK: - SettingsSearchScrollAnchor

private struct SettingsSearchScrollAnchor: NSViewRepresentable {
  let id: String
  let navigator: SettingsSearchNavigator

  static func dismantleNSView(_ view: SettingsSearchAnchorView, coordinator _: ()) {
    view.navigator?.unregister(view)
  }

  func makeNSView(context _: Context) -> SettingsSearchAnchorView {
    let view = SettingsSearchAnchorView()
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ view: SettingsSearchAnchorView, context _: Context) {
    view.navigator = navigator
    navigator.register(view, id: id)
    view.needsLayout = true
  }
}

// MARK: - SettingsSearchAnchorView

private final class SettingsSearchAnchorView: NSView {
  weak var navigator: SettingsSearchNavigator?

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    navigator?.geometryChanged()
  }

  override func layout() {
    super.layout()
    navigator?.geometryChanged()
  }
}
