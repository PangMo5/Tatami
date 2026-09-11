// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Dependencies
import Foundation
import ScreenCaptureKit
import Testing
@testable import TatamiKit

struct ScreenRecordingAccessTests {
  @Test @MainActor
  func `capture permission denial updates Settings without revoking Accessibility`() async {
    let notifications = NotificationCenter()
    let access = ScreenRecordingAccess(preflight: { true }, notificationCenter: notifications)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.accessibility.isTrusted = { true }
      $0.screenRecording = .live(access: access, notificationCenter: notifications)
    }
    store.exhaustivity = .off
    let task = await store.send(.task)
    await store.receive(\.screenRecordingChanged)
    #expect(store.state.hasScreenRecordingPermission)
    access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
    await store.receive(\.screenRecordingChanged) {
      $0.hasScreenRecordingPermission = false
    }
    #expect(store.state.hasAXPermission)
    await task.cancel()
    await store.finish()
  }

  @Test
  func `a revoked preflight stays closed even if the process later reports allowed`() async {
    let granted = LockIsolated(true)
    let notifications = NotificationCenter()
    let access = ScreenRecordingAccess(preflight: { granted.value }, notificationCenter: notifications)
    let client = ScreenRecordingClient.live(access: access, notificationCenter: notifications)
    var changes = client.changes().makeAsyncIterator()
    #expect(await changes.next() != nil)
    #expect(client.isGranted())
    granted.setValue(false)
    #expect(await !access.prepare())
    #expect(await changes.next() != nil)
    granted.setValue(true)
    #expect(!client.isGranted())
  }

  @Test
  func `operational errors and stopping sharing do not imply revoked permission`() async {
    let access = ScreenRecordingAccess(preflight: { true }, notificationCenter: NotificationCenter())
    access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
    #expect(await access.prepare())
    access.captureFailed(NSError(domain: "Unrelated", code: SCStreamError.Code.userDeclined.rawValue))
    #expect(await access.prepare())
    access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue))
    #expect(await access.prepare())
    #expect(!access.isClosed)
  }

  @Test
  func `a stale successful preflight cannot reopen a denied capture session`() async {
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let access = ScreenRecordingAccess(preflight: {
      continuation.yield()
      _ = release.wait(timeout: .now() + 5)
      return true
    }, notificationCenter: NotificationCenter())
    let pending = Task { await access.prepare() }
    var iterator = started.makeAsyncIterator()
    await iterator.next()
    access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
    release.signal()
    #expect(await !pending.value)
    #expect(access.isClosed)
    continuation.finish()
  }

  @Test @MainActor
  func `capture preflight runs outside the main actor`() async {
    let onMain = LockIsolated<Bool?>(nil)
    let access = ScreenRecordingAccess(preflight: {
      onMain.setValue(Thread.isMainThread)
      return true
    }, notificationCenter: NotificationCenter())
    #expect(await access.prepare())
    #expect(onMain.value == false)
  }
}
