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
    /// Switch to (activate) a profile — from the menu or a profile hotkey.
    case activateProfile(Profile.ID)
    /// Deep-copy a profile (fresh ids + copied layouts) right after it.
    case duplicateProfile(Profile.ID)
  }

  @Dependency(\.focusFollowsMouse) var focusFollowsMouse
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.gestures) var gestures
  @Dependency(\.updater) var updater
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.whatsNew) var whatsNew
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.profileSessionStore) var profileSessionStore

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
          // Restore the last-active profile (persisted in ProfileSessionStore,
          // not config.toml) before initial activation, so tiling + hotkeys
          // target it. No saved selection → straight to the default profile.
          .run { [profileSessionStore] send in
            if let id = await profileSessionStore.loadActiveProfileId() {
              await send(.activation(.restoreActiveProfile(id)))
              await send(.hotKeys(.refreshBindings))
            }
            await send(.activation(.activateInitial))
          },
          .send(.settingsChanged(settings)),
          .run { _ in
            await MainActor.run { boundGlobalAXMessagingTimeout() }
          },
          // Permission prompting lives in the activation feature (next to the
          // floating Screen-Recording warning); startup just triggers it.
          .send(.activation(.surfaceMissingPermissions)),
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
        // Skip redundant state churn + a duplicate HUD when an identical
        // report is re-emitted (the Hub replays standing reports on every
        // subscribe). Symmetric with `.resolved` below, which already guards.
        guard state.errorReports[id: report.id] != report else { return .none }
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
          // the Settings tab actually fires: the config is the source of
          // truth, and this re-derives the Magnet bindings from it.
          .send(.hotKeys(.refreshBindings))
        )

      case .swiped(let direction):
        // Right swipe → previous workspace, left swipe → next (natural
        // trackpad direction: content follows fingers).
        return .send(.activation(direction == .right ? .activatePrevious : .activateNext))

      case .hotKeys(.actionTriggered(let hotKeyAction)):
        return route(hotKeyAction, state: state)

      case .activateProfile(let id):
        guard state.config.activeProfileId != id,
              let profile = state.config.profiles.first(where: { $0.id == id })
        else { return .none }
        state.$config.withLock { $0.activeProfileId = id }
        // The new profile has different workspaces — drop any stale sidebar
        // selection so the detail pane doesn't dangle on a workspace that isn't
        // in this profile.
        state.workspaceList.selection = nil
        state.workspaceList.detail = nil
        state.workspaceList.shared = nil
        let hud = state.config.settings.hud
        let name = profile.name
        return .merge(
          // Bindings change with the active profile's workspaces; re-register.
          .send(.hotKeys(.refreshBindings)),
          // Retile every display for the new profile (all workspaces update).
          .send(.activation(.reactivateActiveProfile)),
          .run { [profileSessionStore, workspaceHUD] _ in
            profileSessionStore.saveActiveProfileId(id)
            if hud.shows(\.profileSwitch) {
              await workspaceHUD.show(name, "rectangle.stack.fill", nil, hud.durationMs)
            }
          }
        )

      case .duplicateProfile(let id):
        let remap = state.$config.withLock { $0.duplicateProfile(id) }
        guard !remap.isEmpty else { return .none }
        return .merge(
          .send(.hotKeys(.refreshBindings)),
          // Copy each source workspace's saved layout onto its fresh id so the
          // clone opens looking identical (layouts are keyed by workspace id).
          .run { [layoutStore] _ in
            for (old, new) in remap {
              if let snapshot = await layoutStore.load(old) { layoutStore.save(new, snapshot) }
            }
          }
        )

      case .cli(.delegate(.activateRequested(let workspaceId))):
        // The CLI drives the same activation pipeline as hotkeys.
        return .send(.activation(.activate(workspaceId: workspaceId, setFocus: true)))

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.workspaceDeleteRequested),
           .workspaceList(.detail(.activateShortcutChanged)),
           .workspaceList(.detail(.assignAppShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      // Profile management (sidebar toolbar) routes its side-effecting ops here.
      case .workspaceList(.delegate(.activateProfile(let id))):
        return .send(.activateProfile(id))
      case .workspaceList(.delegate(.profilesChanged)):
        return .send(.hotKeys(.refreshBindings))

      case .workspaceList(.detail(.layoutChanged)):
        // Re-tile now if the edited workspace is the active one, so the window
        // drops out of (or back into) the layout immediately.
        guard let wsId = state.workspaceList.detail?.workspaceId,
              state.activation.activeWorkspacesByDisplay.values.contains(wsId)
        else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      case .workspaceList(.shared(.appPickerAppSelected)),
           .workspaceList(.shared(.appRemoveRequested)),
           .workspaceList(.shared(.layoutChanged)):
        // Shared apps are part of every workspace — re-tile the active one
        // so the change (tiled / float / ignore / removed) lands immediately.
        guard let wsId = state.activation.primaryActiveWorkspaceID else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      // Layout-preview edits to the *active* workspace: the layout reducer can't
      // reach the activation sibling, so it delegates and we forward here.
      case let .workspaceList(.detail(.layout(.delegate(.activeLayoutEdited(workspaceId, op))))):
        return .send(.activation(.layoutEdited(workspaceId: workspaceId, op: op)))

      case let .workspaceList(.detail(.layout(.delegate(.activeFullscreenToggled(windowKey))))):
        return .send(.activation(.bspOpResolved(windowKey: windowKey, op: .toggleZoomFullscreen)))

      case let .workspaceList(.detail(.layout(.delegate(.residentLayoutInvalidated(workspaceId))))):
        return .send(.activation(.invalidateResidentLayout(workspaceId: workspaceId)))

      // "Configure" on a non-tiled chip: send the user to where the app is
      // set up — the Shared Apps sidebar section, or this workspace's Apps
      // section (already the selected detail).
      case let .workspaceList(.detail(.layout(.delegate(.revealAppSettings(bundleId, isShared))))):
        return isShared
          ? .send(.workspaceList(.sidebarSelected(.shared)))
          : .send(.workspaceList(.detail(.scrollToApp(bundleId: bundleId))))

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
    case .borrowWorkspace(let id):
      return .send(.activation(.beginBorrowDirection(workspaceId: id)))
    case .switchToNextWorkspace:
      return .send(.activation(.activateNext))
    case .switchToPreviousWorkspace:
      return .send(.activation(.activatePrevious))
    case .switchToRecentWorkspace:
      return .send(.activation(.activateRecent))
    case .activateProfile(let id):
      return .send(.activateProfile(id))
    case .assignFocusedAppToRecentWorkspace:
      return .send(.activation(.assignFocusedAppToRecentWorkspace))
    case .assignFocusedAppToNextWorkspace:
      return .send(.activation(.assignFocusedAppToAdjacentWorkspace(direction: 1)))
    case .assignFocusedAppToPreviousWorkspace:
      return .send(.activation(.assignFocusedAppToAdjacentWorkspace(direction: -1)))
    case .borrowRecentWorkspace:
      return .send(.activation(.borrowRecentWorkspace))
    case .borrowNextWorkspace:
      return .send(.activation(.borrowAdjacentWorkspace(direction: 1)))
    case .borrowPreviousWorkspace:
      return .send(.activation(.borrowAdjacentWorkspace(direction: -1)))
    case .dismissBorrow:
      return .send(.activation(.dismissBorrow(display: nil)))
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
      return .send(.activation(.cycleWindow(.next)))
    case .cyclePreviousWindow:
      return .send(.activation(.cycleWindow(.previous)))

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

}
