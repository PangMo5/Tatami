import CoreGraphics
import Darwin
import Dispatch
import os
import Testing
@testable import TatamiKit

struct FocusFollowsMouseTests {
  @Test(arguments: [
    (frontmostPID: pid_t(41), targetPID: pid_t(41), expected: false),
    (frontmostPID: pid_t(41), targetPID: pid_t(42), expected: true),
  ])
  func `frontmost transfer is required only across apps`(
    frontmostPID: pid_t,
    targetPID: pid_t,
    expected: Bool,
  ) {
    #expect(
      focusFollowsMouseNeedsFrontmostTransfer(
        frontmostPID: frontmostPID,
        targetPID: targetPID,
      ) == expected
    )
  }

  @Test
  func `unknown frontmost app requires transfer`() {
    #expect(
      focusFollowsMouseNeedsFrontmostTransfer(
        frontmostPID: nil,
        targetPID: 42,
      )
    )
  }

  @Test
  func `mouse move captured before MFF warp cannot restore stale focus`() {
    let gate = ProgrammaticPointerWarpGate()
    gate.recordWarp(to: CGPoint(x: 900, y: 400), timestamp: 200)

    let evaluation = gate.evaluateMouseMove(
      at: CGPoint(x: 120, y: 80),
      timestamp: 199,
    )

    #expect(!evaluation.allowsFocus)
    #expect(evaluation.generation == 1)
  }

  @Test
  func `synthetic move at MFF destination does not trigger FFM`() {
    let gate = ProgrammaticPointerWarpGate()
    gate.recordWarp(to: CGPoint(x: 900, y: 400), timestamp: 200)

    let evaluation = gate.evaluateMouseMove(
      at: CGPoint(x: 901, y: 399),
      timestamp: 201,
    )

    #expect(!evaluation.allowsFocus)
    #expect(evaluation.generation == 1)
  }

  @Test
  func `first physical move after MFF warp immediately resumes FFM`() {
    let gate = ProgrammaticPointerWarpGate()
    gate.recordWarp(to: CGPoint(x: 900, y: 400), timestamp: 200)

    let physicalMove = gate.evaluateMouseMove(
      at: CGPoint(x: 880, y: 400),
      timestamp: 201,
    )
    let followingMove = gate.evaluateMouseMove(
      at: CGPoint(x: 870, y: 400),
      timestamp: 202,
    )

    #expect(physicalMove.allowsFocus)
    #expect(followingMove.allowsFocus)
  }

  @Test
  func `newer MFF warp invalidates an already queued FFM generation`() {
    let gate = ProgrammaticPointerWarpGate()
    gate.recordWarp(to: CGPoint(x: 900, y: 400), timestamp: 200)
    let firstGeneration = gate.evaluateMouseMove(
      at: CGPoint(x: 880, y: 400),
      timestamp: 201,
    ).generation

    gate.recordWarp(to: CGPoint(x: 1_200, y: 500), timestamp: 300)

    #expect(!gate.isCurrent(generation: firstGeneration))
  }

  @Test
  func `pointer driven focus intents survive out of order AX echoes`() {
    let queue = PointerDrivenFocusQueue()
    queue.record(101)
    queue.record(202)

    #expect(queue.consume(202))
    #expect(queue.consume(101))
    #expect(!queue.consume(202))
  }

  @Test
  func `cancelled queued focus does not record a pointer origin`() {
    let recorded = OSAllocatedUnfairLock(initialState: 0)

    let admitted = beginAXFocusMutationIfCurrent(
      isCancelled: { true },
      willPerformAXFocus: { recorded.withLock { $0 += 1 } },
    )

    #expect(!admitted)
    #expect(recorded.withLock { $0 } == 0)
  }

  @Test
  func `admitted focus records its pointer origin exactly once`() {
    let recorded = OSAllocatedUnfairLock(initialState: 0)

    let admitted = beginAXFocusMutationIfCurrent(
      isCancelled: { false },
      willPerformAXFocus: { recorded.withLock { $0 += 1 } },
    )

    #expect(admitted)
    #expect(recorded.withLock { $0 } == 1)
  }

  @Test
  func `AX lanes preserve same PID order without blocking another PID`() {
    let lanes = AXPIDSerialQueueRegistry(
      label: "dev.PangMo5.TatamiTests.ax-pid-lane"
    )
    let firstPID: pid_t = 41
    let secondPID: pid_t = 42
    let firstLane = lanes.queue(for: firstPID)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstStarted = DispatchSemaphore(value: 0)
    let samePIDFinished = DispatchSemaphore(value: 0)
    let otherPIDFinished = DispatchSemaphore(value: 0)

    #expect(firstLane === lanes.queue(for: firstPID))
    #expect(firstLane !== lanes.queue(for: secondPID))

    firstLane.async {
      firstStarted.signal()
      releaseFirst.wait()
    }
    guard firstStarted.wait(timeout: .now() + 1) == .success else {
      releaseFirst.signal()
      Issue.record("The first PID lane did not start")
      return
    }

    lanes.queue(for: firstPID).async {
      samePIDFinished.signal()
    }
    lanes.queue(for: secondPID).async {
      otherPIDFinished.signal()
    }

    let otherPIDCompleted =
      otherPIDFinished.wait(timeout: .now() + 1) == .success
    let samePIDRanWhileBlocked =
      samePIDFinished.wait(timeout: .now() + 0.02) == .success
    releaseFirst.signal()
    let samePIDCompleted =
      samePIDRanWhileBlocked
        || samePIDFinished.wait(timeout: .now() + 1) == .success

    #expect(otherPIDCompleted)
    #expect(!samePIDRanWhileBlocked)
    #expect(samePIDCompleted)
  }

  @Test
  func `new AX focus request invalidates an older PID lane`() {
    let latest = FocusAXLatestRequest()

    let oldRequest = latest.begin()
    let newRequest = latest.begin()

    #expect(!latest.isCurrent(oldRequest))
    #expect(latest.isCurrent(newRequest))
  }

  @Test
  func `superseded AX fallback cannot reactivate an old app`() {
    let latest = FocusAXLatestRequest()

    let oldRequest = latest.begin()
    let newRequest = latest.begin()

    #expect(
      focusAXFallbackResult(
        forceFront: true,
        isCancelled: { !latest.isCurrent(oldRequest) },
      ) == .cancelled
    )
    #expect(
      focusAXFallbackResult(
        forceFront: true,
        isCancelled: { !latest.isCurrent(newRequest) },
      ) == .activateApp
    )
  }
}
