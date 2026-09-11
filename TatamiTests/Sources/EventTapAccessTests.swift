// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Dependencies
import Foundation
import Testing
@testable import TatamiKit

// MARK: - EventTapAccessTests

struct EventTapAccessTests {
  @Test @MainActor
  func `settings refreshes a deleted grant without an OS permission notification`() async {
    let captureAllowed = LockIsolated(true)
    let monitor = EventTapAccessTestMonitor()
    let notifications = NotificationCenter()
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { captureAllowed.value },
      startMonitoring: monitor.start,
      notificationCenter: notifications,
    )
    #expect(access.register { } != nil)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.accessibility = .live(access: access, notificationCenter: notifications)
      $0.screenRecording.isGranted = { true }
    }
    store.exhaustivity = .off
    let task = await store.send(.task)
    // The initial stream tick establishes a live subscription before deletion.
    await store.receive(\.accessibilityChanged)
    #expect(store.state.hasAXPermission)
    captureAllowed.setValue(false)
    monitor.checks.value[0]()
    await store.receive(\.accessibilityChanged) {
      $0.hasAXPermission = false
    }
    #expect(store.state.hasScreenRecordingPermission)
    await task.cancel()
    await store.finish()
  }

  @Test
  func `a permission subscriber catches closure between its initial read and subscription`() async {
    let captureAllowed = LockIsolated(true)
    let monitor = EventTapAccessTestMonitor()
    let notifications = NotificationCenter()
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { captureAllowed.value },
      startMonitoring: monitor.start,
      notificationCenter: notifications,
    )
    let client = AccessibilityClient.live(access: access, notificationCenter: notifications)
    #expect(client.isTrusted())
    #expect(access.register { } != nil)
    captureAllowed.setValue(false)
    monitor.checks.value[0]()
    var changes = client.changes().makeAsyncIterator()
    #expect(await changes.next() != nil)
    #expect(!client.isTrusted())
  }

  @Test
  func `observing permission status does not acquire input capture ownership`() async {
    let monitor = EventTapAccessTestMonitor()
    let notifications = NotificationCenter()
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { true },
      startMonitoring: monitor.start,
      notificationCenter: notifications,
    )
    let client = AccessibilityClient.live(access: access, notificationCenter: notifications)
    var changes = client.changes().makeAsyncIterator()
    #expect(await changes.next() != nil)
    #expect(client.isTrusted())
    #expect(monitor.checks.value.isEmpty)
  }

  @Test
  func `a deleted permission record closes input even when trust remains cached`() {
    let captureAllowed = LockIsolated(true)
    let stopped = LockIsolated(0)
    let monitor = EventTapAccessTestMonitor()
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { captureAllowed.value },
      startMonitoring: monitor.start,
    )
    #expect(access.register { stopped.withValue { $0 += 1 } } != nil)
    #expect(access.register { stopped.withValue { $0 += 1 } } != nil)
    expectNoDifference(monitor.checks.value.count, 1)
    captureAllowed.setValue(false)
    monitor.checks.value[0]()
    #expect(!access.permitsInput())
    expectNoDifference(stopped.value, 2)
    expectNoDifference(monitor.cancellations.value, 1)
    captureAllowed.setValue(true)
    monitor.checks.value[0]()
    #expect(access.register { } == nil)
    expectNoDifference(stopped.value, 2)
  }

  @Test
  func `only live tap owners keep permission monitoring alive`() {
    let queries = LockIsolated(0)
    let monitor = EventTapAccessTestMonitor()
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { queries.withValue { $0 += 1 }
        return true
      },
      startMonitoring: monitor.start,
    )
    let first = access.register { }
    let second = access.register { }
    access.unregister(first)
    expectNoDifference(monitor.cancellations.value, 0)
    monitor.checks.value[0]()
    expectNoDifference(queries.value, 1)
    access.unregister(second)
    expectNoDifference(monitor.cancellations.value, 1)
    #expect(access.register { } != nil)
    monitor.checks.value[0]()
    expectNoDifference(queries.value, 1)
    monitor.checks.value[1]()
    expectNoDifference(queries.value, 2)
  }

  @Test
  func `an in-flight check cannot close a newer tap ownership generation`() async {
    let queries = LockIsolated(0)
    let stopped = LockIsolated(false)
    let monitor = EventTapAccessTestMonitor()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: {
        let count = queries.withValue { $0 += 1
          return $0
        }
        if count == 1 {
          continuation.yield()
          _ = release.wait(timeout: .now() + 5)
          return false
        }
        return true
      },
      startMonitoring: monitor.start,
    )
    let first = access.register { }
    let pending = Task.detached { monitor.checks.value[0]() }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    access.unregister(first)
    #expect(access.register { stopped.setValue(true) } != nil)
    release.signal()
    await pending.value
    #expect(access.permitsInput())
    #expect(!stopped.value)
    monitor.checks.value[1]()
    #expect(access.permitsInput())
    continuation.finish()
  }

  @Test
  func `revocation during monitor startup cancels the returned monitor`() {
    let cancelled = LockIsolated(false)
    let stopped = LockIsolated(false)
    let access = EventTapAccess(
      isTrusted: { true },
      canCaptureInput: { false },
      startMonitoring: { check in
        check()
        return { cancelled.setValue(true) }
      },
    )
    #expect(access.register { stopped.setValue(true) } == nil)
    #expect(stopped.value)
    #expect(cancelled.value)
    #expect(!access.permitsInput())
  }

  @Test
  func `revocation stops every owner once and forbids capture and reinstall`() {
    let trusted = LockIsolated(true)
    let stopped = LockIsolated<[String]>([])
    let access = EventTapAccess(isTrusted: { trusted.value })
    #expect(access.permitsInput())
    let capture = access.register { stopped.withValue { $0.append("capture") } }
    let observer = access.register { stopped.withValue { $0.append("observer") } }
    #expect(capture != nil && observer != nil)
    trusted.setValue(false)
    #expect(!access.permitsInput())
    expectNoDifference(Set(stopped.value), ["capture", "observer"])
    #expect(!access.permitsInput())
    expectNoDifference(stopped.value.count, 2)
    let late = access.register { stopped.withValue { $0.append("late") } }
    #expect(late == nil)
    // A later grant belongs to a fresh process, never a stale input session.
    trusted.setValue(true)
    #expect(!access.permitsInput())
    expectNoDifference(stopped.value.count, 2)
  }

  @Test
  func `normal teardown unregisters its owner without closing other taps`() {
    let trusted = LockIsolated(true)
    let stopped = LockIsolated<[String]>([])
    let access = EventTapAccess(isTrusted: { trusted.value })
    let old = access.register { stopped.withValue { $0.append("old") } }
    access.unregister(old)
    #expect(access.permitsInput())
    _ = access.register { stopped.withValue { $0.append("current") } }
    trusted.setValue(false)
    #expect(!access.permitsInput())
    expectNoDifference(stopped.value, ["current"])
  }

  @Test
  func `revocation callbacks can unregister and check access without a lock cycle`() {
    let trusted = LockIsolated(true)
    let access = EventTapAccess(isTrusted: { trusted.value })
    let registration = LockIsolated<UUID?>(nil)
    let observed = LockIsolated<Bool?>(nil)
    registration.setValue(access.register {
      access.unregister(registration.value)
      observed.setValue(access.permitsInput())
    })
    trusted.setValue(false)
    #expect(!access.permitsInput())
    expectNoDifference(observed.value, false)
  }

  @Test
  func `a stale successful query cannot reopen access after concurrent revocation`() async {
    let calls = LockIsolated(0)
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let access = EventTapAccess {
      let call = calls.withValue { $0 += 1
        return $0
      }
      if call == 1 {
        continuation.yield()
        _ = release.wait(timeout: .now() + 5)
        return true
      }
      return false
    }
    let first = Task.detached { access.permitsInput() }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    #expect(!access.permitsInput())
    release.signal()
    #expect(await !first.value)
    continuation.finish()
  }

  @Test @MainActor
  func `initial permission preparation runs outside the main thread`() async {
    let onMain = LockIsolated<Bool?>(nil)
    let access = EventTapAccess {
      onMain.setValue(Thread.isMainThread)
      return true
    }
    #expect(await access.prepare())
    expectNoDifference(onMain.value, false)
  }
}

/// Existing gate-only tests inject trust without touching WindowServer or timers.
extension EventTapAccess {
  convenience init(isTrusted: @escaping @Sendable () -> Bool) {
    self.init(isTrusted: isTrusted, canCaptureInput: { true }, startMonitoring: { _ in { } })
  }
}

// MARK: - EventTapAccessTestMonitor

private struct EventTapAccessTestMonitor: Sendable {
  let checks = LockIsolated<[@Sendable () -> Void]>([])
  let cancellations = LockIsolated(0)

  func start(_ check: @escaping @Sendable () -> Void) -> EventTapAccess.Cancellation {
    checks.withValue { $0.append(check) }
    return { cancellations.withValue { $0 += 1 } }
  }
}
