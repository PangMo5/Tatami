import CoreGraphics
import Dependencies
import Foundation
import Testing
@testable import TatamiKit

// MARK: - WindowTilerClientTests

struct WindowTilerClientTests {
  @Test
  func `one capability result derives movable and resizable discoveries`() {
    let fixedSize = WindowKey(pid: 1, windowID: 10, bundleId: "app.fixed")
    let flexible = WindowKey(pid: 2, windowID: 20, bundleId: "app.flexible")
    let capabilities = WindowCapabilityDiscovery(
      movableKeys: [fixedSize, flexible],
      resizableKeys: [flexible],
      unreachable: ["app.busy"],
      retained: [30],
    )

    let movable = capabilities.discovery(requireResizable: false)
    let resizable = capabilities.discovery(requireResizable: true)

    #expect(movable.keys == [fixedSize, flexible])
    #expect(resizable.keys == [flexible])
    #expect(movable.unreachable == resizable.unreachable)
    #expect(movable.retained == resizable.retained)
  }

  @Test
  func `frame writes use the smallest safe AX mutation`() {
    let current = CGRect(x: 8, y: 41, width: 800, height: 600)

    #expect(
      WindowTilerClient.frameWritePlan(current: current, target: current) == .none
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 8, y: 41, width: 600, height: 600),
      ) == .resizeOnly
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 800, height: 600),
      ) == .moveOnly
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 600, height: 600),
        crossesDisplays: false,
      ) == .moveAndResizeOnce
    )
    #expect(
      WindowTilerClient.frameWritePlan(
        current: current,
        target: CGRect(x: 400, y: 41, width: 600, height: 600),
        crossesDisplays: true,
      ) == .moveAndResizeTwice
    )
    #expect(
      WindowTilerClient.frameWritePlan(current: nil, target: current)
        == .moveAndResizeTwice
    )
  }

  @Test
  func `fresh window server frames skip only current targets`() {
    let current = WindowKey(pid: 1, windowID: 10, bundleId: "app.current")
    let withinTolerance = WindowKey(pid: 2, windowID: 20, bundleId: "app.tolerance")
    let drifted = WindowKey(pid: 3, windowID: 30, bundleId: "app.drifted")
    let offscreen = WindowKey(pid: 4, windowID: 40, bundleId: "app.offscreen")
    let target = CGRect(x: 8, y: 41, width: 800, height: 600)

    let pending = WindowTilerClient.framesNeedingApply(
      targets: [
        current: target,
        withinTolerance: target,
        drifted: target,
        offscreen: target,
      ],
      visibleFrames: [
        current.windowID: target,
        withinTolerance.windowID: target.offsetBy(dx: 0.5, dy: -0.5),
        drifted.windowID: target.offsetBy(dx: 3, dy: 0),
      ],
    )

    #expect(pending == [drifted: target, offscreen: target])

    let forced = WindowTilerClient.framesNeedingApply(
      targets: [
        current: target,
        withinTolerance: target,
        drifted: target,
        offscreen: target,
      ],
      visibleFrames: [
        current.windowID: target,
        withinTolerance.windowID: target,
        drifted.windowID: target,
        offscreen.windowID: target,
      ],
      forceAllFrames: true,
    )

    #expect(Set(forced.keys) == [current, withinTolerance, drifted, offscreen])
  }

  @Test
  func `current frames finish from fast preflight without entering a PID lane`() async {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.current")
    let target = CGRect(x: 8, y: 41, width: 800, height: 600)
    let snapshotCount = LockIsolated(0)
    let appliedPIDs = LockIsolated<[pid_t]>([])
    let skipped = LockIsolated<[WindowFrameApplyCoordinator.Skip]>([])
    let coordinator = WindowFrameApplyCoordinator(
      currentFrames: {
        snapshotCount.withValue { $0 += 1 }
        return [key.windowID: target]
      },
      applyForPID: { pid, _, _, _, _ in
        appliedPIDs.withValue { $0.append(pid) }
      },
      didSkip: { value in
        skipped.withValue { $0.append(value) }
      },
    )

    await coordinator.apply(FrameApplication(windowFrames: [key: target]))

    #expect(snapshotCount.value == 1)
    #expect(appliedPIDs.value.isEmpty)
    #expect(skipped.value == [.request(frameCount: 1)])
  }

  @Test
  func `idle PID lane reuses the fast preflight snapshot`() async {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.revalidate")
    let target = CGRect(x: 8, y: 41, width: 800, height: 600)
    let snapshotCount = LockIsolated(0)
    let appliedPIDs = LockIsolated<[pid_t]>([])
    let skipped = LockIsolated<[WindowFrameApplyCoordinator.Skip]>([])
    let coordinator = WindowFrameApplyCoordinator(
      currentFrames: {
        snapshotCount.withValue { count in
          count += 1
          return count == 1 ? [:] : [key.windowID: target]
        }
      },
      applyForPID: { pid, _, _, _, _ in
        appliedPIDs.withValue { $0.append(pid) }
      },
      didSkip: { value in
        skipped.withValue { $0.append(value) }
      },
    )

    await coordinator.apply(FrameApplication(windowFrames: [key: target]))

    #expect(snapshotCount.value == 1)
    #expect(appliedPIDs.value == [key.pid])
    #expect(skipped.value.isEmpty)
  }

  @Test
  func `blocked PID does not hold up another PID lane`() async {
    let blocked = WindowKey(pid: 1, windowID: 10, bundleId: "app.blocked")
    let independent = WindowKey(pid: 2, windowID: 20, bundleId: "app.independent")
    let target = CGRect(x: 8, y: 41, width: 800, height: 600)
    let releaseBlockedPID = DispatchSemaphore(value: 0)
    let (startedPIDs, startedPIDsContinuation) = AsyncStream<pid_t>.makeStream(
      bufferingPolicy: .unbounded
    )
    let coordinator = WindowFrameApplyCoordinator(
      currentFrames: { [:] },
      applyForPID: { pid, _, _, _, _ in
        startedPIDsContinuation.yield(pid)
        if pid == blocked.pid {
          releaseBlockedPID.wait()
        }
      },
    )

    let application = Task {
      await coordinator.apply(FrameApplication(windowFrames: [
        blocked: target,
        independent: target,
      ]))
    }
    let bothStarted = await receives(
      [blocked.pid, independent.pid],
      from: startedPIDs,
    )
    releaseBlockedPID.signal()
    startedPIDsContinuation.finish()
    await application.value

    #expect(bothStarted)
  }

  @Test
  func `busy PID revalidates a current preflight after an older write`() async {
    let key = WindowKey(pid: 1, windowID: 10, bundleId: "app.latest")
    let staleTarget = CGRect(x: 8, y: 41, width: 800, height: 600)
    let latestTarget = CGRect(x: 8, y: 41, width: 600, height: 600)
    let visibleFrames = LockIsolated<[CGWindowID: CGRect]>([:])
    let snapshotCount = LockIsolated(0)
    let writes = LockIsolated<[CGRect]>([])
    let releaseStaleWrite = DispatchSemaphore(value: 0)
    let (events, eventsContinuation) = AsyncStream<String>.makeStream(
      bufferingPolicy: .unbounded
    )
    let coordinator = WindowFrameApplyCoordinator(
      currentFrames: {
        let count = snapshotCount.withValue {
          $0 += 1
          return $0
        }
        if count == 2 {
          eventsContinuation.yield("latest-preflight")
        }
        return visibleFrames.value
      },
      applyForPID: { _, frames, _, _, isCancelled in
        guard let target = frames[key] else { return }
        if target == staleTarget {
          eventsContinuation.yield("stale-started")
          releaseStaleWrite.wait()
        }
        guard !isCancelled() else { return }
        visibleFrames.withValue { $0[key.windowID] = target }
        writes.withValue { $0.append(target) }
      },
    )

    let staleApplication = Task {
      await coordinator.apply(FrameApplication(windowFrames: [key: staleTarget]))
    }
    let staleStarted = await receives(["stale-started"], from: events)
    visibleFrames.withValue { $0[key.windowID] = latestTarget }
    let latestApplication = Task {
      await coordinator.apply(FrameApplication(windowFrames: [key: latestTarget]))
    }
    let latestPreflightFinished = await receives(["latest-preflight"], from: events)
    releaseStaleWrite.signal()
    await staleApplication.value
    await latestApplication.value
    eventsContinuation.finish()

    #expect(staleStarted)
    #expect(latestPreflightFinished)
    #expect(snapshotCount.value == 3)
    #expect(writes.value == [staleTarget, latestTarget])
    #expect(visibleFrames.value[key.windowID] == latestTarget)
  }
}

private func receives<Value: Hashable & Sendable>(
  _ expected: Set<Value>,
  from stream: AsyncStream<Value>,
) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      var remaining = expected
      for await value in stream {
        remaining.remove(value)
        if remaining.isEmpty { return true }
      }
      return false
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(2))
      return false
    }
    let result = await group.next() ?? false
    group.cancelAll()
    return result
  }
}
