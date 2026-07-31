import ComposableArchitecture
import Foundation
import Perception
import Sharing

// MARK: - AppTab

/// A top-level tab in the main window.
public enum AppTab: String, Equatable, Sendable {
  case workspaces
  case settings
  case about
}

// MARK: - SettingsSection

/// A deep-link target inside the Settings tab (a specific pane). Set on
/// `AppFeature.State` to route the Settings tab to a pane, then cleared once
/// the view consumes it.
public enum SettingsSection: String, Equatable, Sendable {
  case workspaceKeys
}

// MARK: - AppFeature

/// Top-level reducer. Composes the feature reducers that make up the
/// Tatami app and routes global hotkey events to the right child.
@Reducer
public struct AppFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    @Shared(.tatamiConfig) public var config = AppConfig()
    public var workspaceList = WorkspaceListFeature.State()
    public var activation = WorkspaceActivationFeature.State()
    public var hotKeys = HotKeysFeature.State()
    public var cli = CLIServerFeature.State()
    public var onboarding = OnboardingFeature.State()
    /// The selected top-level tab. Driven by the TabView and set
    /// programmatically for deep-links (e.g. jump to a Settings pane).
    public var selectedTab = AppTab.workspaces
    /// A pending Settings deep-link: the Settings view routes to this pane on
    /// appearance, then clears it via `.settingsSectionConsumed`.
    public var pendingSettingsSection: SettingsSection?
    /// Standing internal failures (config parse errors, invalid shortcuts,
    /// I/O failures) surfaced via the menu bar until resolved or dismissed.
    public var errorReports: IdentifiedArrayOf<ErrorReport> = []

    // MARK: Internal

    /// `.task` is driven by the main window's `.task` modifier, which
    /// re-fires every time the window is closed and reopened. Startup
    /// must run once per process: the subscriptions below consume
    /// process-singleton `AsyncStream`s that support a single consumer.
    var didStartUp = false

  }

  public enum Action {
    case task
    /// The top-level tab changed (TabView selection).
    case tabSelected(AppTab)
    /// The Settings view routed to `pendingSettingsSection`; clear it.
    case settingsSectionConsumed
    case gesturePerformed(TrackpadGesture)
    /// Global settings changed on disk (e.g. via the Settings tab) —
    /// reconfigure the launch-time integrations that don't re-read
    /// config on their own (focus-follows-mouse, gesture tap).
    case settingsChanged(AppSettings)
    case workspaceList(WorkspaceListFeature.Action)
    case activation(WorkspaceActivationFeature.Action)
    case hotKeys(HotKeysFeature.Action)
    case cli(CLIServerFeature.Action)
    case onboarding(OnboardingFeature.Action)
    case checkForUpdatesTapped
    /// An internal failure was reported or resolved (ErrorReportClient).
    case errorReportEvent(ErrorReportEvent)
    case errorReportsDismissed
    /// Switch to (activate) a profile — from the menu or a profile hotkey.
    /// Switch the active profile. `focus`, when set, is a workspace to land as
    /// the focused one after the switch's per-display retile (used by the detail
    /// Activate button on a non-active profile's workspace).
    case activateProfile(Profile.ID, focus: Workspace.ID?)
    /// Deep-copy a profile (fresh ids + copied layouts) right after it.
    case duplicateProfile(Profile.ID)
  }

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
    Scope(state: \.onboarding, action: \.onboarding) {
      OnboardingFeature()
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
        let permissionPrompt: Effect<Action> = hasExistingConfig
          ? .send(.activation(.surfaceMissingPermissions))
          : .none
        // Normalize the config on disk: re-save so any legacy carbon
        // hotkey tables migrate to the skhd-style string form.
        state.$config.withLock { $0 = $0 }
        return .concatenate(
          // Establish the process-wide safety bound before any startup effect
          // can issue AX IPC. A parallel `.merge` left initial activation and
          // observer setup free to race this one-time initialization.
          .run { _ in
            await MainActor.run { boundGlobalAXMessagingTimeout() }
          },
          // Resolve the persisted profile and workspace session before any
          // display observer can emit its initial topology. Otherwise that
          // first event can auto-select a profile from the empty startup state
          // and overwrite a valid last-used manual profile.
          .run { [profileSessionStore] send in
            let session = await profileSessionStore.load()
            await send(
              .activation(
                .restoreStartupSession(
                  lastUsedProfileId: session.activeProfileId,
                  displayWorkspaceHistory: session.historyByDisplay,
                  workspaceMRU: session.workspaceMRU,
                )
              )
            )
            await send(.hotKeys(.refreshBindings))
            await send(.activation(.activateInitial))
          },
          .merge(
            .run { [whatsNew] _ in await whatsNew.showIfNeeded(hasExistingConfig) },
            .send(.onboarding(.appStarted(
              config: state.config,
              hasExistingConfig: hasExistingConfig,
            ))),
            .send(.hotKeys(.onAppear)),
            .send(.cli(.start)),
            .send(.activation(.startObservingWindowEvents)),
            .send(.activation(.startObservingAppLaunches)),
            .send(.settingsChanged(settings)),
            // Guided Setup owns first-run permission education. Existing users
            // keep the established launch-time warning if a grant goes missing.
            permissionPrompt,
            // Always consume swipe events; the tap itself is toggled on/off
            // in `.settingsChanged`.
            .run { [client = gestures] send in
              for await gesture in client.events() {
                await send(.gesturePerformed(gesture))
              }
            },
            // The HUD captures navigation without becoming the active app.
            // Selection and commit still run through the activation reducer.
            .run { [workspaceHUD] send in
              for await interaction in workspaceHUD.windowSwitcherEvents() {
                await send(.activation(.windowCycleHUDInteraction(interaction)))
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
                await updater.configure(
                  automaticallyChecks: general.checkForUpdatesAutomatically,
                  interval: general.checkInterval.seconds,
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
            },
          ),
        )
        .cancellable(id: CancelID.startupSubscriptions, cancelInFlight: true)

      case .checkForUpdatesTapped:
        return .run { [updater] _ in await updater.checkForUpdates() }

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
            report.message,
            "exclamationmark.triangle.fill",
            report.detail,
            duration,
          )
        }

      case .errorReportEvent(.resolved(let domain)):
        guard state.errorReports[id: domain] != nil else { return .none }
        state.errorReports.remove(id: domain)
        // Confirm the recovery (e.g. the config edit that fixed the parse).
        let duration = max(state.config.settings.hud.durationMs, 900)
        return .run { [workspaceHUD] _ in
          await workspaceHUD.show(
            String(localized: "\(domain) issue resolved"),
            "checkmark.circle",
            nil,
            duration,
          )
        }

      case .errorReportsDismissed:
        state.errorReports.removeAll()
        return .none

      case .settingsChanged(let settings):
        let ffm = FocusFollowsMouseConfig(
          enabled: settings.focus.focusFollowsMouse,
          disableModifier: settings.focus.focusFollowsMouseDisableHotkey,
          ignoreFullscreen: settings.focus.focusFollowsMouseIgnoreFullscreen,
        )
        return .merge(
          .run { [client = focusFollowsMouse] _ in
            await client.configure(ffm)
          },
          // Mirror hover-handover follows the same setting: with FFM off,
          // hovering a floating mirror must not move focus.
          .run { [client = floatingOverlay] _ in
            await client.setHoverActivation(settings.focus.focusFollowsMouse)
          },
          .run { [client = gestures] _ in
            await client.stop()
            if settings.gestures.enabled {
              await client.start(settings.gestures.threshold)
            }
          },
          // Re-register hotkey handlers so a shortcut newly recorded in
          // the Settings tab actually fires: the config is the source of
          // truth, and this re-derives the Magnet bindings from it.
          .send(.hotKeys(.refreshBindings)),
        )

      case .gesturePerformed(let gesture):
        if
          state.onboarding.isPresented,
          state.onboarding.draft.settings.gestures.enabled
        {
          return .send(.onboarding(.demoGesturePerformed(gesture)))
        }
        guard state.config.settings.gestures.enabled else { return .none }
        let action = state.config.settings.gestures.action(for: gesture)
        guard let hotKeyAction = action.hotKeyAction else { return .none }
        debugLog.log(
          "Gesture",
          "dispatch fingers=\(gesture.fingerCount) direction=\(gesture.direction) "
            + "action=\(action.id)",
        )
        return route(hotKeyAction, config: state.config)

      case .hotKeys(.actionTriggered(let hotKeyAction)):
        if state.onboarding.isPresented {
          return .send(.onboarding(.demoShortcutPerformed(hotKeyAction)))
        }
        let holdModifiers: HotKeyModifiers? =
          switch hotKeyAction {
          case .cycleNextWindow:
            state.config.settings.shortcuts.cycleNextWindow?.holdModifiers
          case .cyclePreviousWindow:
            state.config.settings.shortcuts.cyclePreviousWindow?.holdModifiers
          default:
            nil
          }
        return route(
          hotKeyAction,
          config: state.config,
          windowCycleHoldModifiers: holdModifiers,
        )

      case .activation(.borrowChordKey(let key)):
        guard state.onboarding.isPresented else { return .none }
        return .send(.onboarding(.demoBorrowChordKey(key)))

      case .activateProfile(let id, let focus):
        guard
          state.config.activeProfileId != id,
          state.config.profiles.contains(where: { $0.id == id })
        else {
          // Already the active profile — just focus the requested workspace, if any.
          if let focus { return .send(.activation(.activate(workspaceId: focus, setFocus: true))) }
          return .none
        }
        state.$config.withLock { $0.activeProfileId = id }
        // The sidebar (col 1) is independent of the active profile, so switching
        // which profile runs no longer disturbs what's being viewed/edited.
        return .merge(
          // Bindings change with the active profile's workspaces; re-register.
          .send(.hotKeys(.refreshBindings)),
          // Retile every display for the new profile (all workspaces update). When
          // `focus` is set, the plan ends on that workspace so it lands active.
          // The per-display profile-switch HUD is shown from here (it knows the
          // actual plan) so each monitor names the workspace that lands on it.
          .send(.activation(.reactivateActiveProfile(focus: focus))),
          .run { [profileSessionStore] _ in await profileSessionStore.saveActiveProfileId(id) },
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
              if let snapshot = await layoutStore.load(old) {
                await layoutStore.save(new, snapshot)
              }
            }
          },
        )

      case .onboarding(.delegate(.applyRequested(let baseline, let draft, let activate))):
        guard state.config == baseline else {
          return .send(.onboarding(.configurationConflictDetected(state.config)))
        }
        state.$config.withLock { $0 = draft }
        var effects: [Effect<Action>] = [
          .send(.hotKeys(.refreshBindings)),
          .send(.onboarding(.configurationApplied)),
          .run { [profileSessionStore] _ in
            await profileSessionStore.saveActiveProfileId(draft.activeProfileId)
          },
        ]
        if
          activate,
          let workspace = draft.activeProfile?.workspaces.first(where: { $0.kind == .normal })
        {
          effects.append(
            .send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
          )
        }
        return .merge(effects)

      case .onboarding(.delegate(.gesturePreviewChanged(let enabled, let threshold))):
        return .run { [gestures] _ in
          await gestures.stop()
          if enabled { await gestures.start(threshold) }
        }

      case .onboarding(.delegate(.gesturePreviewEnded)):
        let settings = state.config.settings.gestures
        return .run { [gestures] _ in
          await gestures.stop()
          if settings.enabled { await gestures.start(settings.threshold) }
        }

      case .onboarding(.delegate(.borrowChordPreviewChanged(let armed))):
        return .run { [borrowChord] _ in
          await borrowChord.setArmed(armed)
        }

      case .onboarding(.delegate(.shortcutPreviewChanged(let draft))):
        return .run { [hotKeys] _ in
          await hotKeys.register(draft.hotKeyBindings)
        }

      case .onboarding(.delegate(.shortcutPreviewEnded)):
        return .send(.hotKeys(.refreshBindings))

      case .onboarding(.delegate(.shortcutRecordingChanged(let recording))):
        return .run { [hotKeys] _ in
          await hotKeys.setRecording(recording)
        }

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
        return .send(.activateProfile(id, focus: nil))

      case .workspaceList(.delegate(.profilesChanged)):
        return .send(.hotKeys(.refreshBindings))

      // A display rule auto-switched the profile: activation already retiled;
      // run the remaining switch side effects (rebind hotkeys, persist, HUD).
      case .activation(.delegate(.profileSwitchRequested(let id, let focus))):
        return .send(.activateProfile(id, focus: focus))

      case .activation(.delegate(.profileAutoActivated(let id))):
        guard state.config.profiles.contains(where: { $0.id == id }) else { return .none }
        // The per-display HUD is shown from the activation reconfigure path
        // (it has the plan); here we just persist + rebind.
        return .merge(
          .send(.hotKeys(.refreshBindings)),
          .run { [profileSessionStore] _ in await profileSessionStore.saveActiveProfileId(id) },
        )

      case .activation(.delegate(.startupProfileResolved(let id))):
        guard state.config.profiles.contains(where: { $0.id == id }) else { return .none }
        return .run { [profileSessionStore] _ in
          await profileSessionStore.saveActiveProfileId(id)
        }

      case .workspaceList(.detail(.layoutChanged)):
        // Re-tile now if the edited workspace is the active one, so the window
        // drops out of (or back into) the layout immediately.
        guard
          let wsId = state.workspaceList.detail?.workspaceId,
          state.activation.activeWorkspacesByDisplay.values.contains(wsId)
        else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      case .workspaceList(.detail(.importWorkspace)):
        // An import can change the key equivalent (rebind) and the app set
        // (re-tile if it's the active workspace).
        var effects: [Effect<Action>] = [.send(.hotKeys(.refreshBindings))]
        if
          let wsId = state.workspaceList.detail?.workspaceId,
          state.activation.activeWorkspacesByDisplay.values.contains(wsId)
        {
          effects.append(.send(.activation(.activate(workspaceId: wsId, setFocus: false))))
        }
        return .merge(effects)

      case .workspaceList(.shared(.appPickerAppSelected)),
           .workspaceList(.shared(.appRemoveRequested)),
           .workspaceList(.shared(.layoutChanged)):
        // Shared apps are part of every workspace — re-tile the active one
        // so the change (tiled / float / ignore / removed) lands immediately.
        guard let wsId = state.activation.primaryActiveWorkspaceID else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      // Layout-preview edits to the *active* workspace: the layout reducer can't
      // reach the activation sibling, so it delegates and we forward here.
      case .workspaceList(.detail(.layout(.delegate(.activeLayoutEdited(let workspaceId, let op))))):
        return .send(.activation(.layoutEdited(workspaceId: workspaceId, op: op)))

      case .workspaceList(.detail(.layout(.delegate(.activeFullscreenToggled(let windowKey))))):
        return .send(.activation(.bspOpResolved(windowKey: windowKey, op: .toggleZoomFullscreen)))

      case .workspaceList(.detail(.layout(.delegate(.residentLayoutInvalidated(let workspaceId))))):
        return .send(.activation(.invalidateResidentLayout(workspaceId: workspaceId)))

      // "Configure" on a non-tiled chip: send the user to where the app is
      // set up — the Shared Apps sidebar section, or this workspace's Apps
      // section (already the selected detail).
      case .workspaceList(.detail(.layout(.delegate(.revealAppSettings(let bundleId, let isShared))))):
        return isShared
          ? .send(.workspaceList(.topSelected(.shared)))
          : .send(.workspaceList(.detail(.scrollToApp(bundleId: bundleId))))

      // The detail Activate button. Activation only runs on the active profile,
      // so if the viewed workspace belongs to another profile, switch to that
      // profile first, then activate the specific workspace with focus.
      case .workspaceList(.detail(.activateTapped)):
        guard let wsId = state.workspaceList.detail?.workspaceId else { return .none }
        let owning = state.config.profileId(owning: wsId)
        let activeId = state.config.activeProfileId ?? state.config.profiles.first?.id
        if let owning, owning != activeId {
          // Switch to the workspace's profile; the reactivate plan ends on this
          // workspace so it lands active + focused (no race with the retile).
          return .send(.activateProfile(owning, focus: wsId))
        }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: true)))

      // A workspace's derived shortcut deep-links to the modifier scheme it
      // reads from: jump to the Settings tab and route it to Workspace Keys.
      case .workspaceList(.detail(.openWorkspaceKeysTapped)):
        state.selectedTab = .settings
        state.pendingSettingsSection = .workspaceKeys
        return .none

      case .tabSelected(let tab):
        state.selectedTab = tab
        return .none

      case .settingsSectionConsumed:
        state.pendingSettingsSection = nil
        return .none

      default:
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.focusFollowsMouse) var focusFollowsMouse
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.borrowChord) var borrowChord
  @Dependency(\.gestures) var gestures
  @Dependency(\.updater) var updater
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.whatsNew) var whatsNew
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.layoutStore) var layoutStore
  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.profileSessionStore) var profileSessionStore

  // MARK: Private

  /// Identifies the app-lifetime subscription bundle so a duplicate
  /// `.task` (defensive; see `didStartUp`) replaces rather than doubles it.
  private enum CancelID { case startupSubscriptions }

  private func route(
    _ action: HotKeyAction,
    config: AppConfig,
    windowCycleHoldModifiers: HotKeyModifiers? = nil,
  ) -> Effect<Action> {
    switch action {
    case .activateWorkspace(let id):
      if let owner = config.profileId(owning: id), owner != config.activeProfile?.id {
        return .send(.activateProfile(owner, focus: id))
      }
      return .send(.activation(.activate(workspaceId: id, setFocus: true)))

    case .assignFocusedAppToWorkspace(let id):
      return .send(.activation(.membershipEdit(.assign(to: id))))

    case .borrowWorkspace(let id):
      guard config.activeProfile?.workspaces[id: id] != nil else {
        debugLog.log("Gesture", "borrow target belongs to an inactive profile — dropped")
        return .none
      }
      return .send(.activation(.beginBorrowDirection(workspaceId: id)))

    case .switchToNextWorkspace:
      return .send(.activation(.activateNext))

    case .switchToPreviousWorkspace:
      return .send(.activation(.activatePrevious))

    case .switchToRecentWorkspace:
      return .send(.activation(.activateRecent))

    case .activateProfile(let id):
      return .send(.activateProfile(id, focus: nil))

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
      if let windowCycleHoldModifiers, !windowCycleHoldModifiers.isEmpty {
        return .send(.activation(
          .cycleWindowShortcut(.next, holdModifiers: windowCycleHoldModifiers)
        ))
      }
      return .send(.activation(.cycleWindow(.next)))

    case .cyclePreviousWindow:
      if let windowCycleHoldModifiers, !windowCycleHoldModifiers.isEmpty {
        return .send(.activation(
          .cycleWindowShortcut(.previous, holdModifiers: windowCycleHoldModifiers)
        ))
      }
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

extension GestureAction {
  var hotKeyAction: HotKeyAction? {
    switch self {
    case .none: nil
    case .nextWorkspace: .switchToNextWorkspace
    case .previousWorkspace: .switchToPreviousWorkspace
    case .recentWorkspace: .switchToRecentWorkspace
    case .moveAppToNextWorkspace: .moveFocusedAppToNextWorkspace
    case .moveAppToPreviousWorkspace: .moveFocusedAppToPreviousWorkspace
    case .assignAppToRecentWorkspace: .assignFocusedAppToRecentWorkspace
    case .assignAppToNextWorkspace: .assignFocusedAppToNextWorkspace
    case .assignAppToPreviousWorkspace: .assignFocusedAppToPreviousWorkspace
    case .focusNextDisplay: .focusNextDisplay
    case .focusPreviousDisplay: .focusPreviousDisplay
    case .focusLeft: .focusLeft
    case .focusRight: .focusRight
    case .focusUp: .focusUp
    case .focusDown: .focusDown
    case .cycleNextWindow: .cycleNextWindow
    case .cyclePreviousWindow: .cyclePreviousWindow
    case .growWindow: .resizeGrow
    case .shrinkWindow: .resizeShrink
    case .swapLeft: .swapLeft
    case .swapRight: .swapRight
    case .swapUp: .swapUp
    case .swapDown: .swapDown
    case .toggleOrientation: .toggleOrientation
    case .toggleFullscreen: .toggleFullscreen
    case .balanceLayout: .balance
    case .toggleFloating: .toggleFloating
    case .toggleSharedFloating: .toggleSharedFloating
    case .toggleTiling: .toggleSpaceActivated
    case .toggleAppInWorkspace: .toggleFocusedAppInActiveWorkspace
    case .toggleAppInSharedApps: .toggleAppInSharedApps
    case .borrowRecentWorkspace: .borrowRecentWorkspace
    case .borrowNextWorkspace: .borrowNextWorkspace
    case .borrowPreviousWorkspace: .borrowPreviousWorkspace
    case .dismissBorrow: .dismissBorrow
    case .activateWorkspace(let id): .activateWorkspace(id)
    case .assignAppToWorkspace(let id): .assignFocusedAppToWorkspace(id)
    case .borrowWorkspace(let id): .borrowWorkspace(id)
    case .activateProfile(let id): .activateProfile(id)
    }
  }
}
