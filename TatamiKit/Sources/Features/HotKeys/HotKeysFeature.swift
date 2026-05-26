import ComposableArchitecture
import Foundation
import Sharing

/// Owns the registration lifecycle of workspace activation hotkeys.
///
/// Reads bindings from `@Shared(.tatamiConfig)`, pushes them to
/// `HotKeysClient.register`, and surfaces fire events back as actions
/// the parent can route into `WorkspaceActivationFeature`.
@Reducer
public struct HotKeysFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public init() {}

    public var bindings: [WorkspaceHotKeyBinding] {
      (config.activeProfile?.workspaces ?? []).compactMap { workspace in
        workspace.activateShortcut.map {
          WorkspaceHotKeyBinding(workspaceId: workspace.id, hotKey: $0)
        }
      }
    }
  }

  public enum Action {
    case onAppear
    case refreshBindings
    case hotKeyTriggered(workspaceId: Workspace.ID)
  }

  @Dependency(\.hotKeys) var hotKeys

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let bindings = state.bindings
        return .merge(
          .run { [client = hotKeys] _ in
            await client.register(bindings)
          },
          .run { [client = hotKeys] send in
            for await event in client.events() {
              await send(.hotKeyTriggered(workspaceId: event.workspaceId))
            }
          }
        )

      case .refreshBindings:
        let bindings = state.bindings
        return .run { [client = hotKeys] _ in
          await client.register(bindings)
        }

      case .hotKeyTriggered:
        return .none
      }
    }
  }
}
