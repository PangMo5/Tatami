import ComposableArchitecture
import Foundation
import Sharing

/// Top-level reducer. Composes the feature reducers that make up the
/// Tatami app and routes global hotkey events to the right child.
@Reducer
public struct AppFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var workspaceList = WorkspaceListFeature.State()
    public var activation = WorkspaceActivationFeature.State()
    public var hotKeys = HotKeysFeature.State()
    public var cli = CLIServerFeature.State()
    public init() {}
  }

  public enum Action {
    case task
    case swiped(SwipeDirection)
    /// Global settings changed on disk (e.g. via the Settings tab) —
    /// reconfigure the launch-time integrations that don't re-read
    /// config on their own (focus-follows-mouse, gesture tap).
    case settingsChanged(AppSettings)
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
        let settings = state.config.settings
        let sharedConfig = state.$config
        // Normalize the config on disk: re-save so any legacy carbon
        // hotkey tables migrate to the skhd-style string form.
        state.$config.withLock { $0 = $0 }
        return .merge(
          .send(.hotKeys(.onAppear)),
          .send(.cli(.start)),
          .send(.activation(.startObservingWindowEvents)),
          .send(.activation(.startObservingAppLaunches)),
          .send(.activation(.activateInitial)),
          .send(.settingsChanged(settings)),
          .run { _ in
            await MainActor.run { _ = ensureAccessibilityTrust() }
          },
          // Always consume swipe events; the tap itself is toggled on/off
          // in `.settingsChanged`.
          .run { [client = gestures] send in
            for await direction in client.events() {
              await send(.swiped(direction))
            }
          },
          // React to live settings edits (Settings tab writes the shared
          // config) so launch-time integrations reconfigure immediately.
          // (Sharing's `Observations` would be the modern path, but it
          // requires macOS 26; on our 14.0 target we use the publisher.)
          .publisher {
            sharedConfig.publisher
              .map(\.settings)
              .removeDuplicates()
              .map(Action.settingsChanged)
          }
        )

      case .settingsChanged(let settings):
        let ffm = FocusFollowsMouseConfig(
          enabled: settings.focus.focusFollowsMouse,
          disableModifier: settings.focus.focusFollowsMouseDisableHotkey
        )
        return .merge(
          .run { [client = focusFollowsMouse] _ in
            await client.configure(ffm)
          },
          .run { [client = gestures] _ in
            await client.stop()
            if settings.gestures.enabled {
              await client.start(settings.gestures.fingerCount, settings.gestures.threshold)
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
