import AppKit
import ApplicationServices
import Dependencies
import DependenciesMacros
import OSLog
import ScreenCaptureKit

/// Keeps "floating" windows visually on top of the tiled layout without
/// SIP, by mirroring each one into an always-on-top panel of our own
/// (the Topit / Floaty technique — see `WindowMirrorCapture`).
///
/// The reducer resolves the floating apps to live `WindowKey`s and pushes
/// the set here after every activation / sync.
///
/// Visibility model — a mirror exists only while the real window would
/// otherwise be covered by a non-floating window:
///
///   * non-floating app focused → every float needs its mirror (shown,
///     streaming; hover/click hands focus to the real window).
///   * floating app focused → its own mirrors hide, and so do sibling
///     floats' that sit unoccluded above the tiles — the real windows
///     show themselves and stack natively by activation recency. Only a
///     sibling genuinely covered by a tile keeps its mirror, demoted
///     below the focused window once its raise is verified.
///
/// Race rules learned the hard way (each violation was a shipped blink):
///
///   * never hide or demote against an *unverified* raise — there is no
///     "raise composited" notification, only the CGWindowList z-check;
///   * restore *before* focus moves (cursor-exit / pre-focus hook /
///     mouse-down tap), never only after didActivate;
///   * hidden panels still get tracking-area events, so hover/click
///     callbacks gate on the suppressed state.
@DependencyClient
struct FloatingOverlayClient: Sendable {
  /// Replace the set of windows mirrored on top. Pass `[]` to tear every
  /// mirror down (e.g. a workspace with no floating apps).
  var setFloating: @Sendable (_ windows: Set<WindowKey>) -> Void
  /// Immediately tear down every mirror whose app is not in `bundleIds`.
  /// Called at the *start* of a workspace switch, in the same beat as the
  /// hide pass, so the outgoing workspace's mirrors don't linger through
  /// the tile pass and vanish noticeably later than the windows they
  /// mirror (`setFloating` reconciles the full set afterwards).
  var retainOnly: @Sendable (_ bundleIds: Set<String>) -> Void
  /// Whether hovering a mirror hands focus to its real window. Mirrored
  /// from the focus-follows-mouse setting: with FFM off, focus must only
  /// move on click — hover-activation would *be* focus-follows-mouse for
  /// floating windows. (The focused app's own mirror still hands back on
  /// hover either way; that moves no focus.)
  var setHoverActivation: @Sendable (_ enabled: Bool) -> Void
}

extension FloatingOverlayClient: DependencyKey {
  static let liveValue: FloatingOverlayClient = MainActor.assumeIsolated {
    @Dependency(\.debugLog) var debugLog
    let controller = FloatingOverlayController(debugLog: debugLog)
    // Pre-focus hook: `focusWindow` (always main-actor) announces the pid
    // it is about to focus, so mirrors restore *before* the z-order change
    // instead of one notification later. Returns whether anything was
    // restored, so the caller can let it commit before activating.
    MirrorWindowRegistry.shared.setWillFocusHandler { pid in
      MainActor.assumeIsolated { controller.handleWillFocus(pid) }
    }
    return FloatingOverlayClient(
      setFloating: { windows in
        Task { @MainActor in controller.setFloating(windows) }
      },
      retainOnly: { bundleIds in
        Task { @MainActor in controller.retainOnly(bundleIds) }
      },
      setHoverActivation: { enabled in
        Task { @MainActor in controller.hoverActivates = enabled }
      }
    )
  }

  static let testValue = FloatingOverlayClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var floatingOverlay: FloatingOverlayClient {
    get { self[FloatingOverlayClient.self] }
    set { self[FloatingOverlayClient.self] = newValue }
  }
}
