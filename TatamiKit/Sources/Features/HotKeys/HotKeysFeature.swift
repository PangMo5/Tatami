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
        if let key = workspace.assignAppShortcut {
          out.append(
            .init(action: .assignFocusedAppToWorkspace(workspace.id), hotKey: key)
          )
        }
      }

      func add(_ action: HotKeyAction, _ key: HotKey?) {
        if let key { out.append(.init(action: action, hotKey: key)) }
      }
      let shortcuts = settings.shortcuts
      add(.switchToNextWorkspace, shortcuts.switchToNextWorkspace)
      add(.switchToPreviousWorkspace, shortcuts.switchToPreviousWorkspace)
      add(.switchToRecentWorkspace, shortcuts.switchToRecentWorkspace)
      add(.moveFocusedAppToNextWorkspace, shortcuts.moveToNextWorkspace)
      add(.moveFocusedAppToPreviousWorkspace, shortcuts.moveToPreviousWorkspace)
      add(.focusNextDisplay, shortcuts.focusNextDisplay)
      add(.focusPreviousDisplay, shortcuts.focusPreviousDisplay)
      add(.focusLeft, shortcuts.focusLeft)
      add(.focusRight, shortcuts.focusRight)
      add(.focusUp, shortcuts.focusUp)
      add(.focusDown, shortcuts.focusDown)
      add(.cycleNextWindow, shortcuts.cycleNextWindow)
      add(.cyclePreviousWindow, shortcuts.cyclePreviousWindow)
      add(.resizeGrow, shortcuts.resizeGrow)
      add(.resizeShrink, shortcuts.resizeShrink)
      add(.swapLeft, shortcuts.swapLeft)
      add(.swapRight, shortcuts.swapRight)
      add(.swapUp, shortcuts.swapUp)
      add(.swapDown, shortcuts.swapDown)
      add(.toggleOrientation, shortcuts.toggleOrientation)
      add(.toggleFullscreen, shortcuts.toggleFullscreen)
      add(.balance, shortcuts.balance)
      add(.toggleFloating, shortcuts.toggleFloating)
      add(.toggleSpaceActivated, shortcuts.toggleSpaceActivated)
      add(.toggleFocusedAppInActiveWorkspace, shortcuts.toggleFocusedAppInActiveWorkspace)
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
