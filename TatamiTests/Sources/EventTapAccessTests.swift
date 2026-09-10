// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CustomDump
import Dependencies
import Foundation
import Testing
@testable import TatamiKit

struct EventTapAccessTests {
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
