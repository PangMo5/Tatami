// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import Dependencies
import OSLog

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "FloatingOverlay")

/// Observing mouse-down tap. A click outside every suppressed floating
/// window is about to move focus away from the floating app; restoring the
/// mirrors at mouse-down time beats the clicked app's raise, which the
/// didActivate notification only reports after the fact. Modeled on the
/// focus-follows-mouse tap (same `EventTapThread`, same re-enable dance).
final class MirrorClickTap: @unchecked Sendable {
  @Dependency(\.debugLog) private var debugLog

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let onOutsideClick: @Sendable () -> Void

  init(onOutsideClick: @escaping @Sendable () -> Void) {
    self.onOutsideClick = onOutsideClick
  }

  func setEnabled(_ enabled: Bool) {
    EventTapThread.shared.perform { [self] in
      if enabled, eventTap == nil {
        install()
      } else if !enabled, eventTap != nil {
        teardown()
      }
    }
  }

  /// Runs on the event-tap thread.
  private func install() {
    let mask =
      (1 << CGEventType.leftMouseDown.rawValue) |
      (1 << CGEventType.rightMouseDown.rawValue) |
      (1 << CGEventType.tapDisabledByTimeout.rawValue) |
      (1 << CGEventType.tapDisabledByUserInput.rawValue)
    let info = Unmanaged.passUnretained(self).toOpaque()
    // `.defaultTap`, not `.listenOnly` — listen-only taps are gated on
    // Input Monitoring and pop the keystroke warning; active taps ride
    // the Accessibility grant (see FocusFollowsMouseClient).
    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: CGEventMask(mask),
      callback: mirrorClickTapCallback,
      userInfo: info
    ) else {
      logger.error("mirror click tap: CGEvent.tapCreate failed")
      debugLog.log("Mirror", "click tap create FAILED (accessibility?)")
      return
    }
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      logger.error("mirror click tap: failed to create run loop source")
      debugLog.log("Mirror", "click tap: run loop source FAILED")
      return
    }
    EventTapThread.shared.addSource(source)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    runLoopSource = source
    debugLog.log("Mirror", "click tap installed")
  }

  private func teardown() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let source = runLoopSource { EventTapThread.shared.removeSource(source) }
    eventTap = nil
    runLoopSource = nil
    debugLog.log("Mirror", "click tap removed")
  }

  fileprivate func reEnable() {
    if let tap = eventTap {
      debugLog.log("Mirror", "click tap disabled by system — re-enabling")
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }

  /// Runs on the event-tap thread; reads only the lock-protected registry.
  fileprivate func handle(location: CGPoint) {
    let frames = MirrorWindowRegistry.shared.suppressedWindowFrames()
    guard !frames.isEmpty else { return }
    guard !frames.contains(where: { $0.contains(location) }) else { return }
    onOutsideClick()
  }
}

/// CGEventTap C callback for the mirror click tap — observes only,
/// returns the event unmodified.
private func mirrorClickTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MirrorClickTap>.fromOpaque(refcon).takeUnretainedValue()
  switch type {
  case .leftMouseDown, .rightMouseDown:
    tap.handle(location: event.location)
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    tap.reEnable()
  default:
    break
  }
  return Unmanaged.passUnretained(event)
}
