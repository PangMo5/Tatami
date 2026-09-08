// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct BlockingWorkQueueTests {
  @Test @MainActor
  func `blocking work leaves the main actor available`() async {
    let worker = BlockingWorkQueue(label: "test.blocking-work")
    let release = DispatchSemaphore(value: 0)
    let (started, continuation) = AsyncStream<Bool>.makeStream()
    let task = Task {
      await worker.run {
        continuation.yield(Thread.isMainThread)
        return release.wait(timeout: .now() + 2) == .success
      }
    }
    var iterator = started.makeAsyncIterator()
    let ranOnMain = await iterator.next()
    #expect(ranOnMain == false)
    MainActor.assertIsolated()
    release.signal()
    #expect(await task.value)
    continuation.finish()
  }

  @Test
  func `worker errors reach the caller without being replaced`() async {
    enum Failure: Error, Equatable { case expected }
    let worker = BlockingWorkQueue(label: "test.throwing-work")
    await #expect(throws: Failure.expected) {
      try await worker.runThrowing { throw Failure.expected }
    }
  }
}
