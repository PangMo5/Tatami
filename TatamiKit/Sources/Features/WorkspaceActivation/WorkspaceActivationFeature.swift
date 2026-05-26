import AppKit
import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display and dispatches activation
/// requests to `WorkspaceManagerClient`. Adds cycle (next/prev/recent)
/// and move-focused-app side effects on top of the basic activate path.
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    public var previousWorkspaceID: Workspace.ID?
    public var isActivating = false

    public init() {}

    public var primaryActiveWorkspaceID: Workspace.ID? {
      activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    case moveFocusedAppTo(workspaceId: Workspace.ID)
    case focusedAppResolved(bundleId: String, workspaceId: Workspace.ID)
    case toggleFloatingOnFocusedApp
    case focusedFloatToggleResolved(bundleId: String, name: String)
    case togglePaused
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.displays) var displays

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .activate(let workspaceId, let setFocus):
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state
        )

      case .activateNext:
        return cycle(by: 1, state: &state)

      case .activatePrevious:
        return cycle(by: -1, state: &state)

      case .activateRecent:
        guard let id = state.previousWorkspaceID else { return .none }
        return .send(.activate(workspaceId: id, setFocus: true))

      case .moveFocusedAppTo(let workspaceId):
        return .run { send in
          let bundleId = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
          }
          guard let bundleId else { return }
          await send(.focusedAppResolved(bundleId: bundleId, workspaceId: workspaceId))
        }

      case .focusedAppResolved(let bundleId, let workspaceId):
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            for i in profile.workspaces.indices {
              profile.workspaces[i].apps.removeAll { $0.bundleIdentifier == bundleId }
            }
            if let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId }) {
              profile.workspaces[idx].apps.append(
                AppAssignment(bundleIdentifier: bundleId, name: bundleId)
              )
            }
          }
        }
        return .send(.activate(workspaceId: workspaceId, setFocus: true))

      case .toggleFloatingOnFocusedApp:
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .focusedFloatToggleResolved(bundleId: resolved.bundleId, name: resolved.name)
          )
        }

      case .focusedFloatToggleResolved(let bundleId, let name):
        state.$config.withLock { config in
          if config.floatingApps.contains(where: { $0.bundleIdentifier == bundleId }) {
            config.floatingApps.removeAll { $0.bundleIdentifier == bundleId }
          } else {
            config.floatingApps.append(
              FloatingApp(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
            )
          }
        }
        return .none

      case .togglePaused:
        state.$config.withLock { config in
          config.settings.isPaused.toggle()
        }
        return .none

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspaceID = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        return .none
      }
    }
  }

  private func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard !state.config.settings.isPaused else { return .none }
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
  }

  private func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let workspaces = state.config.activeProfile?.workspaces, !workspaces.isEmpty
    else { return .none }
    let currentID = state.activeWorkspacesByDisplay.values.first
      ?? state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count
    let nextIndex = (currentIndex + direction + count) % count
    return .send(.activate(workspaceId: workspaces[nextIndex].id, setFocus: true))
  }

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
