import Testing
@testable import TatamiKit

struct WorkspaceManagerClientTests {
  @Test
  func `auto open skips visible and reusable hidden windows`() {
    #expect(
      !WorkspaceManagerClient.shouldAutoOpen(
        hasVisibleWindow: true,
        hasHiddenKnownWindow: false,
      )
    )
    #expect(
      !WorkspaceManagerClient.shouldAutoOpen(
        hasVisibleWindow: false,
        hasHiddenKnownWindow: true,
      )
    )
    #expect(
      WorkspaceManagerClient.shouldAutoOpen(
        hasVisibleWindow: false,
        hasHiddenKnownWindow: false,
      )
    )
  }
}
