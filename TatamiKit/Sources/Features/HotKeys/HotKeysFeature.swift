import ComposableArchitecture
import Foundation
import Sharing

/// Builds the active set of hotkey bindings from the config and pipes
/// fire events back as actions.
@Reducer
public struct HotKeysFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public init() {}

    public var bindings: [HotKeyBinding] {
      var out: [HotKeyBinding] = []
      let settings = config.settings
      let workspaces = config.activeProfile?.workspaces ?? []

      for workspace in workspaces {
        if let key = workspace.activateShortcut {
          out.append(.init(action: .activateWorkspace(workspace.id), hotKey: key))
        }
        if let key = workspace.moveWindowShortcut {
          out.append(
            .init(action: .moveFocusedWindowToWorkspace(workspace.id), hotKey: key)
          )
        }
      }

      func add(_ action: HotKeyAction, _ key: HotKey?) {
        if let key { out.append(.init(action: action, hotKey: key)) }
      }
      add(.switchToNextWorkspace, settings.switchToNextWorkspace)
      add(.switchToPreviousWorkspace, settings.switchToPreviousWorkspace)
      add(.switchToRecentWorkspace, settings.switchToRecentWorkspace)
      add(.focusLeft, settings.focusLeft)
      add(.focusRight, settings.focusRight)
      add(.focusUp, settings.focusUp)
      add(.focusDown, settings.focusDown)
      add(.cycleNextWindow, settings.cycleNextWindow)
      add(.cyclePreviousWindow, settings.cyclePreviousWindow)
      add(.resizeGrow, settings.resizeGrow)
      add(.resizeShrink, settings.resizeShrink)
      add(.swapLeft, settings.swapLeft)
      add(.swapRight, settings.swapRight)
      add(.swapUp, settings.swapUp)
      add(.swapDown, settings.swapDown)
      add(.toggleOrientation, settings.toggleOrientation)
      add(.toggleFullscreen, settings.toggleFullscreen)
      add(.toggleFloating, settings.toggleFloating)
      add(.toggleSpaceActivated, settings.toggleSpaceActivated)
      return out
    }
  }

  public enum Action {
    case onAppear
    case refreshBindings
    case actionTriggered(HotKeyAction)
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
              await send(.actionTriggered(event))
            }
          }
        )

      case .refreshBindings:
        let bindings = state.bindings
        return .run { [client = hotKeys] _ in
          await client.register(bindings)
        }

      case .actionTriggered:
        return .none
      }
    }
  }
}
