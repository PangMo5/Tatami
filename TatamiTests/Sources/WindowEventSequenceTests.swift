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
  func `app-owned frame backlog coalesces to the latest geometry`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    for height in 400 ... 800 {
      buffer.yield(
        .windowFrameChanged(
          key: key,
          frame: CGRect(x: 10, y: 20, width: 900, height: height),
        )
      )
    }
    buffer.finish()

    let events = await collect(sequence)

    #expect(events == [
      .windowFrameChanged(
        key: key,
        frame: CGRect(x: 10, y: 20, width: 900, height: 800),
      )
    ])
  }

  @Test
  func `geometry reads only serve pointer, monitored, or pending write keys`() {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let tracker = WindowFrameWriteTracker()

    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: false)
        == .ignore
    )
    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: true)
        == .read
    )

    tracker.setMonitoredKeys([key])
    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: false)
        == .read
    )
    tracker.setMonitoredKeys([])
    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: false)
        == .ignore
    )

    let generation = tracker.begin(key, target: .zero)
    tracker.finish(key, generation: generation)
    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: false)
        == .read
    )
  }

  @Test
  func `frame write tracker suppresses own echoes before pointer routing`() {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let target = CGRect(x: 10, y: 20, width: 900, height: 800)
    let restored = CGRect(x: 10, y: 20, width: 700, height: 500)
    let tracker = WindowFrameWriteTracker()
    tracker.setMonitoredKeys([key])

    let first = tracker.begin(key, target: target)
    #expect(
      tracker.geometryReadDisposition(for: key, pointerDriven: true)
        == .suppressOwnWrite
    )
    tracker.finish(key, generation: first)
    #expect(
      tracker.routeGeometryEvent(
        for: key,
        frame: target,
        pointerDriven: true,
      ) == .ignore
    )

    let second = tracker.begin(key, target: target)
    tracker.finish(key, generation: second)
    #expect(
      tracker.routeGeometryEvent(
        for: key,
        frame: restored,
        pointerDriven: false,
      ) == .presentationChange
    )
    #expect(
      tracker.routeGeometryEvent(
        for: key,
        frame: restored,
        pointerDriven: true,
      ) == .pointerDriven
    )
  }

  @Test
  func `drag end freezes preceding geometry before the next drag`() async {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let first = CGRect(x: 10, y: 20, width: 800, height: 600)
    let second = CGRect(x: 30, y: 40, width: 900, height: 700)
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    buffer.yield(.windowResized(key: key, frame: first))
    buffer.yield(
      .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      )
    )
    buffer.yield(.windowResized(key: key, frame: second))
    buffer.yield(
      .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      )
    )
    buffer.finish()

    let events = await collect(sequence)

    #expect(events == [
      .windowResized(key: key, frame: first),
      .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      ),
      .windowResized(key: key, frame: second),
      .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      ),
    ])
  }

  @Test
  func `pointer drag completion always emits its mouse-up barrier`() {
    let key = WindowKey(pid: 1, windowID: 101, bundleId: "app.geometry")
    let frame = CGRect(x: 10, y: 20, width: 800, height: 600)

    #expect(
      WindowPointerDragCompletion(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      ).event == .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      )
    )
    #expect(
      WindowPointerDragCompletion(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: true,
      ).event == .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: true,
      )
    )
    #expect(
      WindowPointerDragCompletion(
        trackedWindowID: key.windowID,
        key: key,
        frame: frame,
        pointerMoved: true,
      ).event == .windowDragEnded(
        trackedWindowID: key.windowID,
        key: key,
        frame: frame,
        pointerMoved: true,
      )
    )
  }

  @Test
  func `new pointer generation rejects an older mouse-up barrier`() async throws {
    let oldKey = WindowKey(pid: 1, windowID: 101, bundleId: "app.old")
    let tracker = WindowPointerDragTracker()
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    tracker.pointerDown(
      windowID: oldKey.windowID,
      location: CGPoint(x: 10, y: 10),
    )
    let oldSession = try #require(
      tracker.pointerUp(location: CGPoint(x: 20, y: 20))
    )
    tracker.pointerDown(
      windowID: 202,
      location: CGPoint(x: 30, y: 30),
    )

    let accepted = tracker.yieldIfCurrent(
      WindowPointerDragCompletion(
        trackedWindowID: oldKey.windowID,
        key: oldKey,
        frame: CGRect(x: 10, y: 10, width: 800, height: 600),
        pointerMoved: true,
      ),
      for: oldSession,
      to: buffer,
    )
    buffer.yield(.windowTitleChanged(bundleId: "app.current"))
    buffer.finish()

    #expect(!accepted)
    #expect(await collect(sequence) == [
      .windowTitleChanged(bundleId: "app.current")
    ])
  }

  @Test
  func `large keyed backlog drains latest values across barrier segments`() async {
    let keyCount = 10_000
    let keys = (0 ..< keyCount).map {
      WindowKey(
        pid: 1,
        windowID: CGWindowID($0 + 1),
        bundleId: "app.stress",
      )
    }
    let frame: (Int, CGFloat) -> CGRect = { index, phase in
      CGRect(
        x: CGFloat(index),
        y: phase,
        width: 800,
        height: 600,
      )
    }
    let buffer = CoalescingWindowEventBuffer()
    let sequence = buffer.makeSequence()

    for index in 0 ..< keyCount {
      buffer.yield(.windowMoved(key: keys[index], frame: frame(index, 0)))
    }
    for index in stride(from: keyCount - 1, through: 0, by: -1) {
      buffer.yield(.windowMoved(key: keys[index], frame: frame(index, 1)))
    }
    buffer.yield(
      .windowDragEnded(
        trackedWindowID: nil,
        key: nil,
        frame: nil,
        pointerMoved: false,
      )
    )
    for index in stride(from: keyCount - 1, through: 0, by: -1) {
      buffer.yield(.windowMoved(key: keys[index], frame: frame(index, 2)))
    }
    for index in 0 ..< keyCount {
      buffer.yield(.windowMoved(key: keys[index], frame: frame(index, 3)))
    }
    buffer.finish()

    let events = await collect(sequence)

    #expect(events.count == keyCount * 2 + 1)
    for offset in 0 ..< keyCount {
      let index = keyCount - offset - 1
      #expect(
        events[offset]
          == .windowMoved(key: keys[index], frame: frame(index, 1))
      )
    }
    #expect(
      events[keyCount]
        == .windowDragEnded(
          trackedWindowID: nil,
          key: nil,
          frame: nil,
          pointerMoved: false,
        )
    )
    for index in 0 ..< keyCount {
      #expect(
        events[keyCount + 1 + index]
          == .windowMoved(key: keys[index], frame: frame(index, 3))
      )
    }
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

  @Test
  func `stale observer request keeps additive interest without rewinding liveness`() async {
    let first = RunningAppSnapshot(pid: 101, bundleId: "app.first")
    let second = RunningAppSnapshot(pid: 202, bundleId: "app.second")
    let eventSink = CoalescingWindowEventBuffer()
    let installed = LockIsolated<[String]>([])
    let tornDown = LockIsolated<[String]>([])
    let registry = WindowObserverRegistry(
      eventSink: eventSink,
      makeObservedApp: { pid, bundleId, _ in
        WindowObservedAppHandle(
          pid: pid,
          bundleId: bundleId,
          install: {
            installed.withValue { $0.append(bundleId) }
            return 1
          },
          tearDown: {
            tornDown.withValue { $0.append(bundleId) }
          },
          stopThread: { },
        )
      },
    )

    await registry.installOrUpdate(
      snapshotGeneration: 2,
      bundleIds: [second.bundleId],
      candidates: [second],
      livePids: [first.pid, second.pid],
    )
    // A task that captured first can reach the actor second. Its candidate is
    // still alive according to generation 2, so preserve that additive
    // observer interest without applying its older liveness set.
    await registry.installOrUpdate(
      snapshotGeneration: 1,
      bundleIds: [first.bundleId],
      candidates: [first],
      livePids: [first.pid],
    )

    #expect(installed.value == [second.bundleId, first.bundleId])
    #expect(tornDown.value.isEmpty)

    // The stale call above must not have replaced generation 2's liveness.
    // A genuinely newer snapshot is still authoritative and tears down only
    // the process it now reports dead.
    await registry.installOrUpdate(
      snapshotGeneration: 3,
      bundleIds: [],
      candidates: [],
      livePids: [first.pid],
    )
    #expect(tornDown.value == [second.bundleId])
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
