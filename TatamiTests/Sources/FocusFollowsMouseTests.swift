import CoreGraphics
import Darwin
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
}
