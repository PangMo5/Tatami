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
}
