import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display and dispatches activation
/// requests to `WorkspaceManagerClient`. The map is in-memory only —
/// per-launch fresh state, matching FlashSpace's behavior.
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    /// Which workspace is active on each display.
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    public var isActivating = false

    public init() {}

    /// Convenience: workspace currently active on the main display.
    public var primaryActiveWorkspaceID: Workspace.ID? {
      activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.displays) var displays

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .activate(let workspaceId, let setFocus):
        guard let profile = state.config.activeProfile,
              let workspace = profile.workspaces.first(where: { $0.id == workspaceId })
        else { return .none }
        guard !state.isActivating else { return .none }
        state.isActivating = true

        let targetDisplay = workspace.displayHint ?? displays.current()
        let peerBundleIds = Self.peerBundleIds(
          for: workspace,
          on: targetDisplay,
          in: profile
        )

        let request = ActivationRequest(
          workspace: workspace,
          floatingApps: state.config.floatingApps,
          targetDisplay: targetDisplay,
          displayPeerBundleIds: peerBundleIds,
          setFocus: setFocus,
          mouseFollowsFocus: setFocus && state.config.settings.mouseFollowsFocus,
          mouseHidesOnFocus: setFocus && state.config.settings.mouseHidesOnFocus
        )
        return .run { [client = workspaceManager] send in
          await client.activate(request)
          await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
        }

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        return .none
      }
    }
  }

  /// Bundle IDs assigned to *other* workspaces that target the same
  /// display. Those are the ones we should hide on activation; everything
  /// else (unassigned apps, apps on other displays) is left alone.
  private static func peerBundleIds(
    for workspace: Workspace,
    on display: DisplayName?,
    in profile: Profile
  ) -> Set<String> {
    profile.workspaces
      .filter { peer in
        peer.id != workspace.id && (display == nil || peer.displayHint == display)
      }
      .flatMap { $0.apps.map(\.bundleIdentifier) }
      .reduce(into: Set<String>()) { $0.insert($1) }
  }
}
