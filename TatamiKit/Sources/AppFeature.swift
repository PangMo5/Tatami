import ComposableArchitecture
import Foundation

/// Top-level reducer. Composes the feature reducers that make up the
/// Tatami app and routes global hotkey events to the right child.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    public var workspaceList = WorkspaceListFeature.State()
    public var activation = WorkspaceActivationFeature.State()
    public var hotKeys = HotKeysFeature.State()
    public var cli = CLIServerFeature.State()
    public init() {}
  }

  public enum Action {
    case task
    case swiped(SwipeDirection)
    case workspaceList(WorkspaceListFeature.Action)
    case activation(WorkspaceActivationFeature.Action)
    case hotKeys(HotKeysFeature.Action)
    case cli(CLIServerFeature.Action)
  }

  @Dependency(\.focusManager) var focusManager
  @Dependency(\.focusFollowsMouse) var focusFollowsMouse
  @Dependency(\.gestures) var gestures

  public init() {}

  public var body: some ReducerOf<Self> {
    Scope(state: \.workspaceList, action: \.workspaceList) {
      WorkspaceListFeature()
    }
    Scope(state: \.activation, action: \.activation) {
      WorkspaceActivationFeature()
    }
    Scope(state: \.hotKeys, action: \.hotKeys) {
      HotKeysFeature()
    }
    Scope(state: \.cli, action: \.cli) {
      CLIServerFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        let config = FocusFollowsMouseConfig(
          enabled: state.workspaceList.config.settings.focusFollowsMouse,
          disableModifier: state.workspaceList.config.settings.focusFollowsMouseDisableHotkey
        )
        // Normalize the config on disk: re-save so any legacy carbon
        // hotkey tables migrate to the skhd-style string form.
        state.workspaceList.$config.withLock { $0 = $0 }
        let gesturesEnabled = state.workspaceList.config.settings.swipeGesturesEnabled
        let swipeFingers = state.workspaceList.config.settings.swipeFingerCount
        let swipeThreshold = state.workspaceList.config.settings.swipeThreshold
        return .merge(
          .send(.hotKeys(.onAppear)),
          .send(.cli(.start)),
          .send(.activation(.startObservingWindowEvents)),
          .send(.activation(.startObservingAppLaunches)),
          .send(.activation(.activateInitial)),
          .run { [client = focusFollowsMouse] _ in
            await client.configure(config)
          },
          .run { _ in
            await MainActor.run { _ = ensureAccessibilityTrust() }
          },
          .run { [client = gestures] send in
            guard gesturesEnabled else { return }
            await client.start(swipeFingers, swipeThreshold)
            for await direction in client.events() {
              await send(.swiped(direction))
            }
          }
        )

      case .swiped(let direction):
        // Right swipe → previous workspace, left swipe → next (natural
        // trackpad direction: content follows fingers).
        return .send(.activation(direction == .right ? .activatePrevious : .activateNext))

      case .hotKeys(.actionTriggered(let hotKeyAction)):
        return route(hotKeyAction, state: state)

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.workspaceDeleteRequested),
           .workspaceList(.detail(.activateShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      default:
        return .none
      }
    }
  }

  private func route(_ action: HotKeyAction, state: State) -> Effect<Action> {
    switch action {
    case .activateWorkspace(let id):
      return .send(.activation(.activate(workspaceId: id, setFocus: true)))
    case .moveFocusedWindowToWorkspace(let id):
      return .send(.activation(.moveFocusedAppTo(workspaceId: id)))
    case .switchToNextWorkspace:
      return .send(.activation(.activateNext))
    case .switchToPreviousWorkspace:
      return .send(.activation(.activatePrevious))
    case .switchToRecentWorkspace:
      return .send(.activation(.activateRecent))

    case .focusLeft:
      return .send(.activation(.bspFocus(.west)))
    case .focusRight:
      return .send(.activation(.bspFocus(.east)))
    case .focusUp:
      return .send(.activation(.bspFocus(.north)))
    case .focusDown:
      return .send(.activation(.bspFocus(.south)))

    case .cycleNextWindow:
      let bundleIds = cycleBundleIds(state)
      return .run { [client = focusManager] _ in
        await client.cycleApp(.next, bundleIds)
      }
    case .cyclePreviousWindow:
      let bundleIds = cycleBundleIds(state)
      return .run { [client = focusManager] _ in
        await client.cycleApp(.previous, bundleIds)
      }

    case .toggleFloating:
      return .send(.activation(.toggleFloatingOnFocusedApp))
    case .toggleSpaceActivated:
      return .send(.activation(.togglePaused))

    case .resizeGrow:
      return .send(.activation(.bspResize(direction: .east, delta: 0.05)))
    case .resizeShrink:
      return .send(.activation(.bspResize(direction: .east, delta: -0.05)))
    case .swapLeft:
      return .send(.activation(.bspSwap(.west)))
    case .swapRight:
      return .send(.activation(.bspSwap(.east)))
    case .swapUp:
      return .send(.activation(.bspSwap(.north)))
    case .swapDown:
      return .send(.activation(.bspSwap(.south)))
    case .toggleOrientation:
      return .send(.activation(.bspToggleOrientation))

    case .toggleFullscreen:
      return .send(.activation(.bspToggleZoom))
    }
  }

  private func currentWorkspaceBundleIds(_ state: State) -> [String] {
    guard let id = state.activation.primaryActiveWorkspaceID,
          let ws = state.workspaceList.config.activeProfile?
            .workspaces.first(where: { $0.id == id })
    else { return [] }
    return ws.apps.map(\.bundleIdentifier)
  }

  /// Cycle targets for opt+tab: the active workspace's apps plus every
  /// floating app, so the loop walks all focusable windows including
  /// floating ones (KeyCastr, Zoom, etc.).
  private func cycleBundleIds(_ state: State) -> [String] {
    let workspace = currentWorkspaceBundleIds(state)
    let floating = state.workspaceList.config.floatingApps.map(\.bundleIdentifier)
    var seen = Set<String>()
    return (workspace + floating).filter { seen.insert($0).inserted }
  }
}
