// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Dependencies
import Testing
@testable import TatamiKit

struct MirrorInputHandoverTests {

  // MARK: Internal

  @Test
  func `untrusted mirror installation never creates an input source`() async {
    let sourceRequests = LockIsolated(0)
    let failures = LockIsolated<[String]>([])
    let tap = MirrorClickTap(
      hitTestWindow: { _ in nil },
      prepareNativeWindow: { _, _ in false },
      finishNativeInput: { _ in },
      onAccessRevoked: {},
      onFailure: { reason in failures.withValue { $0.append(reason) } },
      onOutsideClick: {},
      makeEventSource: {
        sourceRequests.withValue { $0 += 1 }
        return nil
      },
      access: EventTapAccess(isTrusted: { false }),
    )
    #expect(await !tap.enable())
    #expect(sourceRequests.value == 0)
    #expect(failures.value.count == 1)
  }

  @Test
  func `failed native input installation never reports readiness for a mirror`() async {
    let failures = LockIsolated<[String]>([])
    let tap = MirrorClickTap(
      hitTestWindow: { _ in nil },
      prepareNativeWindow: { _, _ in false },
      finishNativeInput: { _ in },
      onAccessRevoked: { },
      onFailure: { reason in failures.withValue { $0.append(reason) } },
      onOutsideClick: { },
      makeEventSource: { nil },
      access: EventTapAccess(isTrusted: { true }),
    )
    let ready = await tap.enable()
    #expect(!ready)
    #expect(failures.value.count == 1)
  }

  @Test
  func `old acknowledgments cannot complete a new packet after cancellation`() throws {
    var acknowledgments = MirrorInputAcknowledgments()
    let first = try mouse(.leftMouseDown, x: 120, y: 60)
    first.timestamp = 100
    let oldReplay = try #require(nativeMirrorReplayEvent(first, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    acknowledgments.posted(oldReplay)
    acknowledgments.reset()
    // A new click can be waiting for hit testing before anything is posted.
    let accepted1 = acknowledgments.accept(oldReplay)
    #expect(!accepted1)
    let second = try mouse(.leftMouseDown, x: 120, y: 60)
    second.timestamp = 200
    let currentReplay = try #require(nativeMirrorReplayEvent(second, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    acknowledgments.posted(currentReplay)
    let accepted2 = acknowledgments.accept(oldReplay)
    #expect(!accepted2)
    #expect(acknowledgments.hasPending)
    let accepted3 = acknowledgments.accept(currentReplay)
    #expect(accepted3)
    #expect(!acknowledgments.hasPending)
    let accepted4 = acknowledgments.accept(currentReplay)
    #expect(!accepted4)
  }

  @Test
  func `balancing releases and another window cannot acknowledge the current down`() throws {
    var acknowledgments = MirrorInputAcknowledgments()
    let down = try mouse(.leftMouseDown, x: 120, y: 60)
    down.timestamp = 100
    let replay = try #require(nativeMirrorReplayEvent(down, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    acknowledgments.posted(replay)
    let release = try mouse(.leftMouseUp, x: 120, y: 60)
    release.timestamp = down.timestamp
    let balancingUp = try #require(nativeMirrorReplayEvent(release, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    let accepted5 = acknowledgments.accept(balancingUp)
    #expect(!accepted5)
    let otherWindow = try #require(nativeMirrorReplayEvent(down, tag: MirrorInputEventOrigin.tag(windowID: 834)))
    let accepted6 = acknowledgments.accept(otherWindow)
    #expect(!accepted6)
    let accepted7 = acknowledgments.accept(down)
    #expect(!accepted7)
    let accepted8 = acknowledgments.accept(replay)
    #expect(accepted8)
  }

  @Test
  func `a complete click arriving before activation retains both edges`() throws {
    var buffer = MirrorInputBuffer()
    let down = try mouse(.leftMouseDown, x: 120, y: 60)
    let up = try mouse(.leftMouseUp, x: 120, y: 60)
    let acceptedDown = buffer.append(down)
    let acceptedUp = buffer.append(up)
    #expect(acceptedDown && acceptedUp)
    #expect(buffer.pressedButtons.isEmpty) // Physical receipt is not native delivery.
    let firstEvent = buffer.popFirst()
    let first = try #require(firstEvent)
    #expect(first.type == .leftMouseDown)
    buffer.delivered(first)
    #expect(buffer.pressedButtons == [0])
    let secondEvent = buffer.popFirst()
    let second = try #require(secondEvent)
    #expect(second.type == .leftMouseUp)
    buffer.delivered(second)
    #expect(buffer.pressedButtons.isEmpty)
    #expect(buffer.isEmpty)
  }

  @Test
  func `titlebar drag keeps its original down and every movement before release`() throws {
    var buffer = MirrorInputBuffer()
    let points: [(CGEventType, CGPoint)] = [
      (.leftMouseDown, CGPoint(x: 300, y: 80)),
      (.leftMouseDragged, CGPoint(x: 340, y: 90)),
      (.leftMouseDragged, CGPoint(x: 410, y: 120)),
      (.leftMouseUp, CGPoint(x: 410, y: 120)),
    ]
    for (type, point) in points {
      let accepted = buffer.append(try mouse(type, x: point.x, y: point.y))
      #expect(accepted)
    }
    for (type, point) in points {
      let next = buffer.popFirst()
      let event = try #require(next)
      let replay = try #require(nativeMirrorReplayEvent(event, tag: 1234))
      #expect(replay.type == type)
      #expect(replay.location == point)
      buffer.delivered(replay)
      #expect(buffer.pressedButtons.isEmpty == (type == .leftMouseUp))
    }
    #expect(buffer.isEmpty)
  }

  @Test
  func `replay preserves double click modifiers and pressure but removes the mirror route`() throws {
    let event = try mouse(.leftMouseDown, x: 15, y: 25)
    event.flags = [.maskShift, .maskCommand]
    event.timestamp = 12345678
    event.setIntegerValueField(.mouseEventClickState, value: 2)
    event.setDoubleValueField(.mouseEventPressure, value: 0.75)
    event.setIntegerValueField(.eventTargetUnixProcessID, value: 999)
    event.setIntegerValueField(try #require(CGEventField(rawValue: 51)), value: 900)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 900)
    let replay = try #require(nativeMirrorReplayEvent(event, tag: 42))
    #expect(replay.flags == event.flags)
    #expect(replay.timestamp == event.timestamp)
    #expect(replay.getIntegerValueField(.mouseEventClickState) == 2)
    #expect(replay.getDoubleValueField(.mouseEventPressure) == event.getDoubleValueField(.mouseEventPressure))
    #expect(replay.getIntegerValueField(.eventTargetUnixProcessID) == 0)
    #expect(replay.getIntegerValueField(try #require(CGEventField(rawValue: 51))) == 0)
    #expect(replay.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 0)
    #expect(replay.getIntegerValueField(.eventSourceUserData) == 42)
    #expect(event.getIntegerValueField(try #require(CGEventField(rawValue: 51))) == 900)
  }

  @Test
  func `right click retains native context menu button identity`() throws {
    var buffer = MirrorInputBuffer()
    for type: CGEventType in [.rightMouseDown, .rightMouseUp] {
      let accepted = buffer.append(try mouse(type, x: 100, y: 100, button: .right))
      #expect(accepted)
    }
    let originalDown = buffer.popFirst()
    let event = try #require(originalDown)
    let down = try #require(nativeMirrorReplayEvent(event, tag: 1))
    buffer.delivered(down)
    #expect(buffer.pressedButtons == [1])
    #expect(down.getIntegerValueField(.mouseEventButtonNumber) == 1)
    let originalUp = buffer.popFirst()
    let up = try #require(originalUp)
    buffer.delivered(up)
    #expect(buffer.pressedButtons.isEmpty)
  }

  @Test
  func `typing immediately after a click remains ordered behind that click`() throws {
    var buffer = MirrorInputBuffer()
    let down = try mouse(.leftMouseDown, x: 30, y: 30)
    let up = try mouse(.leftMouseUp, x: 30, y: 30)
    let keyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    let keyUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    for event in [down, up, keyDown, keyUp] {
      let accepted = buffer.append(event)
      #expect(accepted)
    }
    let types = (0..<4).compactMap { _ in buffer.popFirst()?.type }
    #expect(types == [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp])
  }

  @Test
  func `cancellation discards pending clicks and clears gesture ownership`() throws {
    var buffer = MirrorInputBuffer()
    let down = try mouse(.leftMouseDown, x: 0, y: 0)
    buffer.delivered(down)
    let accepted = buffer.append(try mouse(.leftMouseUp, x: 10, y: 10))
    #expect(accepted)
    buffer.reset()
    #expect(buffer.pressedButtons.isEmpty)
    let discarded = buffer.popFirst()
    #expect(discarded == nil)
  }

  @Test
  func `unannotated mouse downs are admitted by published mirror geometry`() throws {
    let registry = MirrorWindowRegistry()
    let target = MirrorWindowRegistry.Target(pid: 12, windowID: 34)
    let point = CGPoint(x: 50, y: 50)
    registry.set(mirror: 90, target: target, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let event = try mouse(.leftMouseDown, x: point.x, y: point.y)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 0)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: 0)
    event.setIntegerValueField(try #require(CGEventField(rawValue: 51)), value: 0)
    #expect(registry.mayContainMirror(at: event.location))
    #expect(!registry.mayContainMirror(at: CGPoint(x: 101, y: 50)))
    registry.set(mirror: 90, target: nil)
    #expect(!registry.mayContainMirror(at: event.location))
  }

  @Test
  func `moving a mirror replaces its input admission geometry`() {
    let registry = MirrorWindowRegistry()
    let target = MirrorWindowRegistry.Target(pid: 12, windowID: 34)
    registry.set(mirror: 90, target: target, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    registry.set(mirror: 90, target: target, frame: CGRect(x: 200, y: 0, width: 100, height: 100))
    #expect(!registry.mayContainMirror(at: CGPoint(x: 50, y: 50)))
    #expect(registry.mayContainMirror(at: CGPoint(x: 250, y: 50)))
    #expect(registry.allTargets()[90] == target)
  }

  @Test
  func `cancellation tracks delivered key downs until their release or native ownership`() throws {
    var buffer = MirrorInputBuffer()
    let keyDown = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    let keyUp = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
    buffer.delivered(keyDown)
    #expect(buffer.pressedKeys == [0])
    buffer.delivered(keyUp)
    #expect(buffer.pressedKeys.isEmpty)
    buffer.delivered(keyDown)
    buffer.releaseKeyboardTracking()
    #expect(buffer.pressedKeys.isEmpty)
  }

  @Test
  func `buffered HID gesture retains its original button identity through release`() throws {
    var buffer = MirrorInputBuffer()
    let down = try mouse(.leftMouseDown, x: 100, y: 20)
    let up = try mouse(.leftMouseUp, x: 180, y: 60)
    down.setIntegerValueField(.mouseEventNumber, value: 731)
    up.setIntegerValueField(.mouseEventNumber, value: 731)
    let replay = try #require(nativeMirrorReplayEvent(down, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    #expect(replay.getIntegerValueField(.mouseEventNumber) == 731)
    buffer.delivered(replay)
    let released = try #require(nativeMirrorReplayEvent(up, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    #expect(released.getIntegerValueField(.mouseEventNumber) == 731)
    buffer.delivered(released)
    #expect(buffer.buttonEventNumbers.isEmpty)
  }

  @Test
  func `replayed drag origin survives lease release and a pointer over another app`() throws {
    let down = try mouse(.leftMouseDown, x: 100, y: 20)
    let replay = try #require(nativeMirrorReplayEvent(down, tag: MirrorInputEventOrigin.tag(windowID: 833)))
    replay.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: 131)
    #expect(MirrorInputEventOrigin.isReplay(replay))
    #expect(MirrorInputEventOrigin.windowID(replay) == 833)
    #expect(!MirrorInputEventOrigin.isReplay(down))
    #expect(MirrorInputEventOrigin.windowID(down) == nil)
    let ordinary = try #require(nativeMirrorReplayEvent(down, tag: MirrorInputEventOrigin.tag(windowID: nil)))
    #expect(MirrorInputEventOrigin.isReplay(ordinary))
    #expect(MirrorInputEventOrigin.windowID(ordinary) == nil)
  }

  @Test
  func `relay retains device metadata for both content and titlebar input`() throws {
    let hardwareSource = try #require(CGEventSource(stateID: .hidSystemState))
    for start in [CGPoint(x: 120, y: 20), CGPoint(x: 120, y: 300)] {
      let down = try #require(CGEvent(
        mouseEventSource: hardwareSource,
        mouseType: .leftMouseDown,
        mouseCursorPosition: start,
        mouseButton: .left,
      ))
      down.setIntegerValueField(.mouseEventNumber, value: 731)
      down.setIntegerValueField(.mouseEventInstantMouser, value: 1)
      down.setIntegerValueField(.tabletEventDeviceID, value: 42)
      let relayedDown = try #require(nativeMirrorReplayEvent(down, tag: 1))
      #expect(relayedDown.location == start)
      #expect(relayedDown.getIntegerValueField(.mouseEventNumber) == 731)
      #expect(relayedDown.getIntegerValueField(.mouseEventInstantMouser) == down.getIntegerValueField(.mouseEventInstantMouser))
      #expect(relayedDown.getIntegerValueField(.tabletEventDeviceID) == down.getIntegerValueField(.tabletEventDeviceID))
      #expect(relayedDown.getIntegerValueField(.eventSourceStateID) == down.getIntegerValueField(.eventSourceStateID))
      #expect(relayedDown.getIntegerValueField(.eventSourceUnixProcessID) == down.getIntegerValueField(.eventSourceUnixProcessID))
    }
  }

  // MARK: Private

  private func mouse(_ type: CGEventType, x: CGFloat, y: CGFloat, button: CGMouseButton = .left) throws -> CGEvent {
    try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button))
  }

}
