// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Darwin
import Dispatch
import os
import Testing
@testable import TatamiKit

struct FocusFollowsMouseTests {
  @Test(arguments: [true, false])
  func `fullscreen exclusion is limited to the same display`(ignoreFullscreen: Bool) {
    let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let context = FocusFollowsMouseDisplayContext(origin: CGPoint(x: 100, y: 100))

    #expect(context.allowsFocus(
      on: display,
      at: CGPoint(x: 500, y: 400),
      displays: [display],
      frontBounds: [],
      ignoreFullscreen: ignoreFullscreen,
    ) == !ignoreFullscreen)
  }

  @Test(arguments: [
    CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
    CGRect(x: -1_000, y: 0, width: 1_000, height: 800),
    CGRect(x: 0, y: -800, width: 1_000, height: 800),
  ])
  func `crossing displays admits a fullscreen target with the exclusion on`(target: CGRect) {
    let source = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let point = CGPoint(x: target.midX, y: target.midY)
    var context = FocusFollowsMouseDisplayContext(origin: CGPoint(x: 500, y: 400))

    #expect(context.allowsFocus(
      on: target,
      at: point,
      displays: [target, source],
      frontBounds: [],
      ignoreFullscreen: true,
    ))

    context.origin = point
    #expect(!context.allowsFocus(
      on: target,
      at: CGPoint(x: point.x + 10, y: point.y),
      displays: [source, target],
      frontBounds: [],
      ignoreFullscreen: true,
    ))
  }

  @Test
  func `a display crossing survives a tile gap until its target is admitted`() {
    let source = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let target = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
    let tile = CGRect(x: 1_100, y: 100, width: 400, height: 400)
    let context = FocusFollowsMouseDisplayContext(origin: CGPoint(x: 500, y: 400))

    #expect(!context.allowsFocus(
      on: target,
      at: CGPoint(x: 1_090, y: 200),
      displays: [source, target],
      frontBounds: [tile],
      ignoreFullscreen: true,
    ))
    #expect(context.allowsFocus(
      on: target,
      at: CGPoint(x: 1_800, y: 600),
      displays: [source, target],
      frontBounds: [tile],
      ignoreFullscreen: true,
    ))
  }

  @Test(arguments: [nil, CGPoint(x: -500, y: 100)])
  func `unknown origin does not bypass fullscreen exclusion`(origin: CGPoint?) {
    let display = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let context = FocusFollowsMouseDisplayContext(origin: origin)

    #expect(!context.allowsFocus(
      on: display,
      at: CGPoint(x: 500, y: 400),
      displays: [display],
      frontBounds: [],
      ignoreFullscreen: true,
    ))
    #expect(context.allowsFocus(
      on: CGRect(x: 0, y: 0, width: 500, height: 800),
      at: CGPoint(x: 100, y: 100),
      displays: [display],
      frontBounds: [],
      ignoreFullscreen: true,
    ))
  }

  @Test
  func `first physical move after a warp uses the destination display as its origin`() {
    let gate = ProgrammaticPointerWarpGate()
    let destination = CGPoint(x: 500, y: 400)
    gate.recordWarp(to: destination, timestamp: 200)
    let point = CGPoint(x: 1_500, y: 400)
    let evaluation = gate.evaluateMouseMove(at: point, timestamp: 201)
    let context = FocusFollowsMouseDisplayContext(origin: evaluation.warpDestination)
    let source = CGRect(x: 0, y: 0, width: 1_000, height: 800)
    let target = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)

    #expect(evaluation.allowsFocus)
    #expect(evaluation.warpDestination == destination)
    #expect(gate.evaluateMouseMove(at: point, timestamp: 202).warpDestination == destination)
    #expect(context.allowsFocus(
      on: target,
      at: point,
      displays: [source, target],
      frontBounds: [],
      ignoreFullscreen: true,
    ))
  }

  @Test
  func `the final move is consumed without waiting for another event`() {
    var inputs = LatestFocusInputBuffer<Int>()
    let starts = [inputs.offer(1), inputs.offer(2), inputs.offer(3)]
    let last = inputs.takeLatest()
    let restarts = inputs.offer(4)
    let next = inputs.takeLatest()
    #expect(starts == [true, false, false])
    #expect(last == 3)
    #expect(restarts)
    #expect(next == 4)
  }

  @Test
  func `disable or return to the current window revokes queued input`() {
    var inputs = LatestFocusInputBuffer<Int>()
    let starts = inputs.offer(1)
    inputs.invalidate()
    let cancelled = inputs.takeLatest()
    let restarts = inputs.offer(2)
    inputs.invalidate()
    let overlaps = inputs.offer(3)
    let latest = inputs.takeLatest()
    #expect(starts)
    #expect(cancelled == nil)
    #expect(restarts)
    #expect(!overlaps)
    #expect(latest == 3)
  }

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
  func `overlay evaluation rejects final focus mutation`() {
    let overlay = OverlayAwarenessState()
    let process = OverlayAwareProcess(bundleId: "notion.id", pid: 41)
    overlay.configure([process.bundleId])
    let evaluation = overlay.beginEvaluation([process])
    defer { overlay.endEvaluation(evaluation) }
    let recorded = OSAllocatedUnfairLock(initialState: 0)

    let admitted = beginAXFocusMutationIfCurrent(
      isCancelled: { overlay.isBackgrounded(pid: process.pid) },
      willPerformAXFocus: { recorded.withLock { $0 += 1 } },
    )

    #expect(!admitted)
    #expect(recorded.withLock { $0 } == 0)
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
