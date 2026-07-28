import CoreGraphics
import Dependencies
import Testing
@testable import TatamiKit

@Suite("Window observer event sequence")
struct WindowEventSequenceTests {

  // MARK: Internal

  @Test
  func `state backlog coalesces until downstream asks for a value`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    for x in 0 ..< 1_000 {
      buffer.yield(
        .windowMoved(
          key: key,
          frame: CGRect(x: x, y: 20, width: 800, height: 600),
        )
      )
    }
    buffer.finish()

    let events = await collect(sequence)

    #expect(events == [
      .windowMoved(
        key: key,
        frame: CGRect(x: 999, y: 20, width: 800, height: 600),
      )
    ])
  }

  @Test
  func `drag end freezes preceding geometry before the next drag`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let first = CGRect(x: 10, y: 20, width: 800, height: 600)
    let second = CGRect(x: 30, y: 40, width: 900, height: 700)
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    buffer.yield(.windowResized(key: key, frame: first))
    buffer.yield(.windowDragEnded)
    buffer.yield(.windowResized(key: key, frame: second))
    buffer.yield(.windowDragEnded)
    buffer.finish()

    let events = await collect(sequence)

    #expect(events == [
      .windowResized(key: key, frame: first),
      .windowDragEnded,
      .windowResized(key: key, frame: second),
      .windowDragEnded,
    ])
  }

  @Test
  func `focus coalescing preserves final MRU order and nil reconcile`() async {
    let first = WindowKey(pid: 1, windowID: 101, bundleId: "app.first")
    let second = WindowKey(pid: 2, windowID: 202, bundleId: "app.second")
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    buffer.yield(.windowFocused(bundleId: first.bundleId, key: first))
    buffer.yield(.windowFocused(bundleId: second.bundleId, key: second))
    buffer.yield(.windowFocused(bundleId: first.bundleId, key: first))
    buffer.yield(.windowFocused(bundleId: first.bundleId, key: nil))
    buffer.finish()

    let events = await collect(sequence)

    #expect(events == [
      .windowFocused(bundleId: second.bundleId, key: second),
      .windowFocused(bundleId: first.bundleId, key: first),
      .windowFocused(bundleId: first.bundleId, key: nil),
    ])
  }

  @Test
  func `observer install discarded when a newer snapshot reports its pid dead`() async {
    let pid = pid_t(4242)
    let bundleId = "app.install-race"
    let eventSink = CoalescingWindowEventBuffer()
    let creationCount = LockIsolated(0)
    let tearDownCount = LockIsolated(0)
    let (installStarted, installStartedContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let (installRelease, installReleaseContinuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    let registry = WindowObserverRegistry(
      eventSink: eventSink,
      makeObservedApp: { pid, bundleId, _ in
        let ordinal = creationCount.withValue {
          $0 += 1
          return $0
        }
        return WindowObservedAppHandle(
          pid: pid,
          bundleId: bundleId,
          install: {
            if ordinal == 1 {
              installStartedContinuation.yield(())
              installStartedContinuation.finish()
              for await _ in installRelease { break }
            }
            return 1
          },
          tearDown: {
            tearDownCount.withValue { $0 += 1 }
          },
          stopThread: { },
        )
      },
    )
    let candidate = RunningAppSnapshot(pid: pid, bundleId: bundleId)

    let firstInstall = Task {
      await registry.installOrUpdate(
        snapshotGeneration: 1,
        bundleIds: [bundleId],
        candidates: [candidate],
        livePids: [pid],
      )
    }
    for await _ in installStarted { break }

    // Re-enter the registry while the first install is suspended. The observer
    // is not in `observed` yet, so only the latest liveness generation can stop
    // the stale caller from publishing it after the await.
    await registry.installOrUpdate(
      snapshotGeneration: 2,
      bundleIds: [],
      candidates: [],
      livePids: [],
    )
    // A capture taken before the termination snapshot may reach the actor
    // afterward. Its lower generation must not restore stale liveness.
    await registry.installOrUpdate(
      snapshotGeneration: 1,
      bundleIds: [bundleId],
      candidates: [candidate],
      livePids: [pid],
    )
    installReleaseContinuation.yield(())
    installReleaseContinuation.finish()
    await firstInstall.value

    #expect(tearDownCount.value == 1)

    // A later live snapshot must create a fresh observer. If the stale handle
    // leaked into `observed`, this call would be incorrectly deduplicated.
    await registry.installOrUpdate(
      snapshotGeneration: 3,
      bundleIds: [bundleId],
      candidates: [candidate],
      livePids: [pid],
    )
    #expect(creationCount.value == 2)
  }

  // MARK: Private

  private func collect(
    _ sequence: WindowEventSequence
  ) async -> [WindowChangeEvent] {
    var events = [WindowChangeEvent]()
    for await event in sequence {
      events.append(event)
    }
    return events
  }

}
