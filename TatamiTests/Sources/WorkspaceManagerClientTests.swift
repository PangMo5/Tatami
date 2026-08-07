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

  @Test
  func `a background activation never reopens a running app`() {
    // The vacated-display refill runs with setFocus == false. Reopening a
    // running app there lets it activate itself, which steals keyboard focus
    // (and drags the cursor along under mouse-follows-focus) onto the display
    // the user just switched away from.
    #expect(
      !WorkspaceManagerClient.shouldReopenRunningApp(
        summoned: false,
        setFocus: false,
        isRunning: true,
      )
    )
    // Not running: nothing to unhide, so launching it is the only way to
    // populate the display, and a fresh launch has no focus to steal yet.
    #expect(
      WorkspaceManagerClient.shouldReopenRunningApp(
        summoned: false,
        setFocus: false,
        isRunning: false,
      )
    )
    // A deliberate switch is allowed to bring an app forward — the focus block
    // still owns where focus lands.
    #expect(
      WorkspaceManagerClient.shouldReopenRunningApp(
        summoned: false,
        setFocus: true,
        isRunning: true,
      )
    )
  }

  @Test
  func `a summoned borrow reopens its apps even without focus`() {
    // A Borrow passes setFocus == false because it focuses the borrowed block
    // itself, not because it is a background restore. A scratchpad forces
    // auto-open on every one of its apps precisely so they come up when
    // summoned, so the background gate must not apply to them.
    #expect(
      WorkspaceManagerClient.shouldReopenRunningApp(
        summoned: true,
        setFocus: false,
        isRunning: true,
      )
    )
  }
}
