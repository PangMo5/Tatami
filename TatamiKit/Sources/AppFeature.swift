import ComposableArchitecture
import Foundation
import Perception
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
    /// Standing internal failures (config parse errors, invalid shortcuts,
    /// I/O failures) surfaced via the menu bar until resolved or dismissed.
    public var errorReports: IdentifiedArrayOf<ErrorReport> = []
    /// `.task` is driven by the main window's `.task` modifier, which
    /// re-fires every time the window is closed and reopened. Startup
    /// must run once per process: the subscriptions below consume
    /// process-singleton `AsyncStream`s that support a single consumer.
    var didStartUp = false
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
    case checkForUpdatesTapped
    /// An internal failure was reported or resolved (ErrorReportClient).
    case errorReportEvent(ErrorReportEvent)
    case errorReportsDismissed
  }

  @Dependency(\.focusManager) var focusManager
  @Dependency(\.focusFollowsMouse) var focusFollowsMouse
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.gestures) var gestures
  @Dependency(\.updater) var updater
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.whatsNew) var whatsNew
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.workspaceHUD) var workspaceHUD

  /// Identifies the app-lifetime subscription bundle so a duplicate
  /// `.task` (defensive; see `didStartUp`) replaces rather than doubles it.
  private enum CancelID { case startupSubscriptions }

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
        guard !state.didStartUp else { return .none }
        state.didStartUp = true
        let settings = state.config.settings
        let sharedConfig = state.$config
        // Existing setup = at least one configured workspace or shared app;
        // a brand-new install has nothing migrated worth announcing.
        let hasExistingConfig =
          !(state.config.activeProfile?.workspaces.isEmpty ?? true)
            || !state.config.sharedApps.isEmpty
        // Normalize the config on disk: re-save so any legacy carbon
        // hotkey tables migrate to the skhd-style string form.
        state.$config.withLock { $0 = $0 }
        return .merge(
          .run { [whatsNew] _ in await whatsNew.showIfNeeded(hasExistingConfig) },
          .send(.hotKeys(.onAppear)),
          .send(.cli(.start)),
          .send(.activation(.startObservingWindowEvents)),
          .send(.activation(.startObservingAppLaunches)),
          .send(.activation(.activateInitial)),
          .send(.settingsChanged(settings)),
          .run { _ in
            await MainActor.run {
              _ = ensureAccessibilityTrust()
              boundGlobalAXMessagingTimeout()
            }
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
          // `Perceptions` is Perception's back-port of Swift's
          // `Observations` async sequence (Observation requires macOS 26);
          // observing only `.settings` re-emits just on settings changes.
          .run { send in
            for await settings in Perceptions({ sharedConfig.wrappedValue.settings }) {
              await send(.settingsChanged(settings))
            }
          },
          // Reading `updater` starts Sparkle's background schedule; keep
          // its auto-check preference + interval in sync with settings.
          .run { [updater, sharedConfig] _ in
            for await general in Perceptions({ sharedConfig.wrappedValue.settings.general }) {
              updater.configure(
                automaticallyChecks: general.checkForUpdatesAutomatically,
                interval: general.checkInterval.seconds
              )
            }
          },
          // Keep the login-item registration in sync with the setting.
          .run { [loginItem, sharedConfig] _ in
            for await enabled in Perceptions({
              sharedConfig.wrappedValue.settings.general.launchAtLogin
            }) {
              loginItem.setEnabled(enabled)
            }
          },
          // Mirror the debug-log toggle into the writer so flipping it
          // in Settings opens/closes the log file immediately.
          .run { [debugLog, sharedConfig] _ in
            for await enabled in Perceptions({
              sharedConfig.wrappedValue.settings.general.debugLogging
            }) {
              debugLog.setEnabled(enabled)
              if enabled {
                debugLog.log("App", "debug log enabled (settings toggle)")
              }
            }
          },
          // Surface internal failures (config parse, invalid shortcuts,
          // I/O errors) in the UI. Replays anything reported before this
          // subscription — the initial config decode runs at the first
          // `@Shared` access, well before `.task`.
          .run { [errorReporter] send in
            for await event in errorReporter.events() {
              await send(.errorReportEvent(event))
            }
          }
        )
        .cancellable(id: CancelID.startupSubscriptions, cancelInFlight: true)

      case .checkForUpdatesTapped:
        updater.checkForUpdates()
        return .none

      case .errorReportEvent(.reported(let report)):
        state.errorReports[id: report.id] = report
        // Errors always show, regardless of the HUD category toggles —
        // gating them would hide exactly what the user asked to see.
        // Linger longer than action HUDs so the detail is readable.
        let duration = max(state.config.settings.hud.durationMs * 2, 2400)
        return .run { [workspaceHUD] _ in
          await workspaceHUD.show(
            report.message, "exclamationmark.triangle.fill", report.detail, duration
          )
        }

      case .errorReportEvent(.resolved(let domain)):
        guard state.errorReports[id: domain] != nil else { return .none }
        state.errorReports.remove(id: domain)
        // Confirm the recovery (e.g. the config edit that fixed the parse).
        let duration = max(state.config.settings.hud.durationMs, 900)
        return .run { [workspaceHUD] _ in
          await workspaceHUD.show(
            "\(domain) issue resolved", "checkmark.circle", nil, duration
          )
        }

      case .errorReportsDismissed:
        state.errorReports.removeAll()
        return .none

      case .settingsChanged(let settings):
        let ffm = FocusFollowsMouseConfig(
          enabled: settings.focus.focusFollowsMouse,
          disableModifier: settings.focus.focusFollowsMouseDisableHotkey,
          ignoreFullscreen: settings.focus.focusFollowsMouseIgnoreFullscreen
        )
        return .merge(
          .run { [client = focusFollowsMouse] _ in
            await client.configure(ffm)
          },
          // Mirror hover-handover follows the same setting: with FFM off,
          // hovering a floating mirror must not move focus.
          .run { [client = floatingOverlay] _ in
            client.setHoverActivation(settings.focus.focusFollowsMouse)
          },
          .run { [client = gestures] _ in
            await client.stop()
            if settings.gestures.enabled {
              await client.start(settings.gestures.fingerCount, settings.gestures.threshold)
            }
          },
          // Re-register hotkey handlers so a shortcut newly recorded in
          // the Settings tab actually fires. Without this the
          // KeyboardShortcuts library slot gets the new combo but our
          // `onKeyDown` handler was never wired for it.
          .send(.hotKeys(.refreshBindings))
        )

      case .swiped(let direction):
        // Right swipe → previous workspace, left swipe → next (natural
        // trackpad direction: content follows fingers).
        return .send(.activation(direction == .right ? .activatePrevious : .activateNext))

      case .hotKeys(.actionTriggered(let hotKeyAction)):
        return route(hotKeyAction, state: state)

      case .cli(.delegate(.activateRequested(let workspaceId))):
        // The CLI drives the same activation pipeline as hotkeys.
        return .send(.activation(.activate(workspaceId: workspaceId, setFocus: true)))

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.workspaceDeleteRequested),
           .workspaceList(.detail(.activateShortcutChanged)),
           .workspaceList(.detail(.assignAppShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      case .workspaceList(.detail(.floatingToggled)):
        // Re-tile now if the edited workspace is the active one, so the window
        // drops out of (or back into) the layout immediately.
        guard let wsId = state.workspaceList.detail?.workspaceId,
              state.activation.activeWorkspacesByDisplay.values.contains(wsId)
        else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      case .workspaceList(.shared(.appPickerAppSelected)),
           .workspaceList(.shared(.appRemoveRequested)),
           .workspaceList(.shared(.floatingToggled)):
        // Shared apps are part of every workspace — re-tile the active one
        // so the change (tiled ↔ floating ↔ removed) lands immediately.
        guard let wsId = state.activation.primaryActiveWorkspaceID else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      default:
        return .none
      }
    }
  }

  private func route(_ action: HotKeyAction, state: State) -> Effect<Action> {
    switch action {
    case .activateWorkspace(let id):
      return .send(.activation(.activate(workspaceId: id, setFocus: true)))
    case .assignFocusedAppToWorkspace(let id):
      return .send(.activation(.membershipEdit(.assign(to: id))))
    case .switchToNextWorkspace:
      return .send(.activation(.activateNext))
    case .switchToPreviousWorkspace:
      return .send(.activation(.activatePrevious))
    case .switchToRecentWorkspace:
      return .send(.activation(.activateRecent))
    case .moveFocusedAppToNextWorkspace:
      return .send(.activation(.moveFocusedAppToAdjacent(direction: 1)))
    case .moveFocusedAppToPreviousWorkspace:
      return .send(.activation(.moveFocusedAppToAdjacent(direction: -1)))
    case .focusNextDisplay:
      return .send(.activation(.focusAdjacentDisplay(direction: 1)))
    case .focusPreviousDisplay:
      return .send(.activation(.focusAdjacentDisplay(direction: -1)))

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
      return .send(.activation(.membershipEdit(.toggleFloating)))
    case .toggleSharedFloating:
      return .send(.activation(.membershipEdit(.toggleSharedFloating)))
    case .toggleSpaceActivated:
      return .send(.activation(.togglePaused))
    case .toggleFocusedAppInActiveWorkspace:
      return .send(.activation(.membershipEdit(.toggleInActiveWorkspace)))
    case .toggleAppInSharedApps:
      return .send(.activation(.membershipEdit(.toggleShared)))

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
      // Multi-window fullscreen: several windows can be fullscreen-
      // zoomed at once, the tree shapes around their absence, focus
      // determines which sits on top. (The tree also supports a
      // single-tile parent-zoom — `BSPNode.togglingParentZoom` — with
      // no binding surface yet.)
      return .send(.activation(.bspToggleZoomFullscreen))
    case .balance:
      return .send(.activation(.bspBalance))
    }
  }

  private func currentWorkspaceBundleIds(_ state: State) -> [String] {
    guard let id = state.activation.primaryActiveWorkspaceID,
          let ws = state.workspaceList.config.activeProfile?
            .workspaces[id: id]
    else { return [] }
    return ws.apps.map(\.bundleIdentifier)
  }

  /// Cycle targets for opt+tab: the active workspace's apps plus every
  /// shared app, so the loop walks all focusable windows including
  /// shared/floating ones (KeyCastr, Zoom, etc.).
  private func cycleBundleIds(_ state: State) -> [String] {
    let workspace = currentWorkspaceBundleIds(state)
    let shared = state.workspaceList.config.sharedApps.map(\.bundleIdentifier)
    var seen = Set<String>()
    return (workspace + shared).filter { seen.insert($0).inserted }
  }
}
