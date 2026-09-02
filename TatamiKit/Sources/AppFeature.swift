// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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

    @Shared(.tatamiConfig) public var config
    public var workspaceList = WorkspaceListFeature.State()
    public var activation = WorkspaceActivationFeature.State()
    public var hotKeys = HotKeysFeature.State()
    public var cli = CLIServerFeature.State()
    public var hooks = HooksFeature.State()
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
    /// Records the process launch event even when no matching hook existed at
    /// startup, so adding one later cannot replay an event from the past.
    var didPublishTatamiLaunched = false
    /// Startup hooks require both the restored profile and a terminal CLI
    /// listener result. A failed listener still completes Tatami startup.
    var didRestoreStartupProfile = false
    var didCompleteCLIStart = false

  }

  public enum Action {
    case task
    /// Startup profile reconciliation completed; publish its initial hook
    /// context without widening WorkspaceActivationFeature's delegate contract.
    case startupProfileRestored
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
    case hooks(HooksFeature.Action)
    case onboarding(OnboardingFeature.Action)
    case checkForUpdatesTapped
    /// An internal failure was reported or resolved (ErrorReportClient).
    case errorReportEvent(ErrorReportEvent)
    /// A compact HUD publication captured centrally by WorkspaceHUDClient.
    case actionHUDPresented(ActionHUDPresentation)
    case errorReportsDismissed
    /// Switch to (activate) a profile — from the menu or a profile hotkey.
    /// Switch the active profile. `focus`, when set, is a workspace to land as
    /// the focused one after the switch's per-display retile (used by the detail
    /// Activate button on a non-active profile's workspace).
    case activateProfile(Profile.ID, focus: Workspace.ID?)
    /// Switch after deleting the active profile while retaining the outgoing
    /// profile snapshot for the `profileChanged` hook payload.
    case activateProfileAfterDeletion(Profile.ID, previousProfile: Profile)
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
    Scope(state: \.hooks, action: \.hooks) {
      HooksFeature()
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
          // Seed overlay awareness before profile restoration can trigger the
          // first workspace activation. Keeping this in the sequential prefix
          // avoids a startup race with `.settingsChanged`, which intentionally
          // joins the later subscription merge.
          .run { [overlayAwareness, windowSnapshot] _ in
            overlayAwareness.configure(settings.visibility.overlayAwareApps)
            let frontmost = await MainActor.run {
              windowSnapshot.frontmostApp()
            }
            guard let frontmost else { return }
            let process = OverlayAwareProcess(
              bundleId: frontmost.bundleId,
              pid: frontmost.pid,
            )
            let evaluation = overlayAwareness.beginEvaluation([process])
            defer { overlayAwareness.endEvaluation(evaluation) }
            let preserved = await overlayAwareness.processesToKeepVisible(
              evaluation,
              [process],
            )
            guard !Task.isCancelled else { return }
            _ = overlayAwareness.commitEvaluation(evaluation, preserved)
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
            await send(.startupProfileRestored)
            await send(.hotKeys(.refreshBindings))
          },
          .merge(
            .run { [whatsNew] _ in await whatsNew.showIfNeeded(hasExistingConfig) },
            .send(.onboarding(.appStarted(
              config: state.config,
              hasExistingConfig: hasExistingConfig,
            ))),
            .send(.hotKeys(.onAppear)),
            .send(.cli(.start)),
            .send(.hooks(.start)),
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
            // Bridge the exact localized action feedback sent to the visual HUD
            // into the configured `hud` hooks. Keeping this at the client
            // boundary covers every producer, including errors and permissions.
            .run { [workspaceHUD] send in
              for await presentation in workspaceHUD.actionPresentations() {
                await send(.actionHUDPresented(presentation))
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

      case .actionHUDPresented(let presentation):
        guard
          state.config.hasEnabledHook(for: .hud),
          let profile = state.config.activeProfile
        else { return .none }
        return .send(.hooks(.emit(HookInvocation(
          event: .hud,
          occurredAt: now,
          profile: .init(profile),
          display: presentation.display.map(HookInvocation.DisplaySnapshot.init),
          hud: .init(
            title: presentation.title,
            symbolIconName: presentation.symbolIconName,
            subtitle: presentation.subtitle,
            durationMs: presentation.durationMs,
            position: presentation.position,
            size: presentation.size,
          ),
        ))))

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
        let position = state.config.settings.hud.position
        let size = state.config.settings.hud.size
        return .run { [workspaceHUD] _ in
          await workspaceHUD.showAction(
            ActionHUDRequest(
              name: report.message,
              symbolIconName: "exclamationmark.triangle.fill",
              subtitle: report.detail,
              durationMs: duration,
              position: position,
              size: size,
              emitsHookEvent: !report.domain.hasPrefix("Hook"),
            )
          )
        }

      case .errorReportEvent(.resolved(let domain)):
        guard state.errorReports[id: domain] != nil else { return .none }
        state.errorReports.remove(id: domain)
        // Confirm the recovery (e.g. the config edit that fixed the parse).
        let duration = max(state.config.settings.hud.durationMs, 900)
        let position = state.config.settings.hud.position
        let size = state.config.settings.hud.size
        return .run { [workspaceHUD] _ in
          await workspaceHUD.showAction(
            ActionHUDRequest(
              name: String(localized: "\(domain) issue resolved"),
              symbolIconName: "checkmark.circle",
              subtitle: nil,
              durationMs: duration,
              position: position,
              size: size,
              emitsHookEvent: !domain.hasPrefix("Hook"),
            )
          )
        }

      case .errorReportsDismissed:
        state.errorReports.removeAll()
        return .none

      case .settingsChanged(let settings):
        // This registry is synchronous state. Commit it in reducer order so a
        // delayed effect from an older settings snapshot cannot restore a
        // removed allowlist entry.
        overlayAwareness.configure(settings.visibility.overlayAwareApps)
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
        return activateProfileEffect(
          id,
          focus: focus,
          previousProfile: nil,
          state: &state,
        )

      case .activateProfileAfterDeletion(let id, let previousProfile):
        return activateProfileEffect(
          id,
          focus: nil,
          previousProfile: previousProfile,
          state: &state,
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

      case .cli(.delegate(.activateProfileRequested(let profileId, let complete))):
        guard state.config.profiles.contains(where: { $0.id == profileId }) else {
          return .run { _ in complete("The requested profile no longer exists") }
        }
        let request = WorkspaceActivationFeature.CLIActivationRequest(
          target: .profile(profileId),
          complete: complete,
        )
        guard state.config.activeProfile?.id != profileId else {
          if
            state.activation.isActivating
            || state.activation.activeActivationGeneration != nil
            || !state.activation.pendingDisplayRestores.isEmpty
          {
            return .send(.activation(.trackCLIActivation(
              request,
              joinCurrentActivation: true,
            )))
          }
          return .run { _ in complete(nil) }
        }
        return .concatenate(
          .send(.activation(.trackCLIActivation(
            request,
            joinCurrentActivation: false,
          ))),
          .send(.activateProfile(profileId, focus: nil)),
        )

      case .cli(.delegate(.activateWorkspaceRequested(let workspaceId, let complete))):
        // The CLI drives the same cross-profile activation pipeline as hotkeys.
        guard let owner = state.config.profileId(owning: workspaceId) else {
          return .run { _ in complete("The requested workspace no longer exists") }
        }
        let request = WorkspaceActivationFeature.CLIActivationRequest(
          target: .workspace(workspaceId),
          complete: complete,
        )
        let activation: Effect<Action> =
          if owner != state.config.activeProfile?.id {
            .send(.activateProfile(owner, focus: workspaceId))
          } else {
            .send(.activation(.activateFromCLI(
              workspaceId: workspaceId,
              requestID: request.id,
            )))
          }
        return .concatenate(
          .send(.activation(.trackCLIActivation(
            request,
            joinCurrentActivation: false,
          ))),
          activation,
        )

      case .cli(.delegate(.dispatchDomainCommandRequested(let action, let complete))):
        if let error = actionAvailabilityError(action, config: state.config) {
          return .run { _ in complete(error) }
        }
        // The CLI shares the exact dispatcher used by gestures and hotkeys.
        // Its response is intentionally `accepted`: child reducers can still
        // decide that changed live window/focus state leaves nothing to do.
        return .concatenate(
          route(action, config: state.config),
          .run { _ in complete(nil) },
        )

      case .cli(.delegate(.configurationChanged)):
        return .send(.hotKeys(.refreshBindings))

      case .cli(.startCompleted):
        state.didCompleteCLIStart = true
        return publishStartupHooksIfReady(state: &state)

      case .workspaceList(.addWorkspaceFormSubmitted),
           .workspaceList(.alert(.presented(.confirmDeletion))),
           .workspaceList(.detail(.activateShortcutChanged)),
           .workspaceList(.detail(.assignAppShortcutChanged)),
           .workspaceList(.detail(.keyEquivalentChanged)),
           .workspaceList(.detail(.borrowShortcutChanged)):
        return .send(.hotKeys(.refreshBindings))

      // Profile management (sidebar toolbar) routes its side-effecting ops here.
      case .workspaceList(.delegate(.activateProfile(let id))):
        return .send(.activateProfile(id, focus: nil))

      case .workspaceList(.delegate(.activateProfileAfterDeletion(
        let id,
        previousProfile: let previousProfile,
      ))):
        return .send(.activateProfileAfterDeletion(id, previousProfile: previousProfile))

      case .workspaceList(.delegate(.profilesChanged)):
        return .send(.hotKeys(.refreshBindings))

      // A display rule auto-switched the profile: activation already retiled;
      // run the remaining switch side effects (rebind hotkeys, persist, HUD).
      case .activation(.delegate(.profileSwitchRequested(let id, let focus))):
        return .send(.activateProfile(id, focus: focus))

      case .activation(.delegate(.profileAutoActivated(let previousID, let id))):
        guard let current = state.config.profiles.first(where: { $0.id == id }) else { return .none }
        let previous = previousID.flatMap { previousID in
          state.config.profiles.first(where: { $0.id == previousID })
        }
        // The per-display HUD is shown from the activation reconfigure path
        // (it has the plan); here we just persist + rebind.
        var effects: [Effect<Action>] = [
          .send(.hotKeys(.refreshBindings)),
          .run { [profileSessionStore] _ in await profileSessionStore.saveActiveProfileId(id) },
        ]
        if state.config.hasEnabledHook(for: .profileChanged) {
          effects.append(.send(.hooks(.emit(HookInvocation(
            event: .profileChanged,
            occurredAt: now,
            profile: .init(current),
            previousProfile: previous.map(HookInvocation.ProfileSnapshot.init),
          )))))
        }
        return .merge(effects)

      case .startupProfileRestored:
        state.didRestoreStartupProfile = true
        return publishStartupHooksIfReady(state: &state)

      case .activation(.delegate(.startupProfileResolved(let id))):
        guard state.config.profiles.contains(where: { $0.id == id }) else { return .none }
        return .run { [profileSessionStore] _ in
          await profileSessionStore.saveActiveProfileId(id)
        }

      case .activation(.activationCompleted(let workspaceId, let display, let generation)):
        guard
          state.activation.activeActivationGeneration == generation,
          state.config.hasEnabledHook(for: .workspaceActivated),
          let profileID = state.config.profileId(owning: workspaceId),
          let profile = state.config.profiles.first(where: { $0.id == profileID }),
          let workspace = profile.workspaces[id: workspaceId]
        else { return .none }
        return .send(.hooks(.emit(HookInvocation(
          event: .workspaceActivated,
          occurredAt: now,
          profile: .init(profile),
          workspace: .init(workspace),
          display: display.map(HookInvocation.DisplaySnapshot.init),
        ))))

      case .workspaceList(.detail(.layoutChanged)):
        // Re-tile now if the edited workspace is the active one, so the window
        // drops out of (or back into) the layout immediately.
        guard
          let wsId = state.workspaceList.detail?.workspaceId,
          state.activation.activeWorkspacesByDisplay.values.contains(wsId)
        else { return .none }
        return .send(.activation(.activate(workspaceId: wsId, setFocus: false)))

      case .workspaceList(.detail(.delegate(.importApplied(let workspaceId)))):
        // Only a successfully committed import delegates here. A rejected
        // conflict/stale review must not rebind or re-tile unchanged state.
        var effects: [Effect<Action>] = [.send(.hotKeys(.refreshBindings))]
        if state.activation.activeWorkspacesByDisplay.values.contains(workspaceId) {
          effects.append(.send(.activation(.activate(workspaceId: workspaceId, setFocus: false))))
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
  @Dependency(\.overlayAwareness) var overlayAwareness
  @Dependency(\.windowSnapshot) var windowSnapshot
  @Dependency(\.floatingOverlay) var floatingOverlay
  @Dependency(\.borrowChord) var borrowChord
  @Dependency(\.gestures) var gestures
  @Dependency(\.updater) var updater
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.whatsNew) var whatsNew
  @Dependency(\.debugLog) var debugLog
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.workspaceHUD) var workspaceHUD
  @Dependency(\.hotKeys) var hotKeys
  @Dependency(\.profileSessionStore) var profileSessionStore
  @Dependency(\.date.now) var now

  // MARK: Private

  /// Identifies the app-lifetime subscription bundle so a duplicate
  /// `.task` (defensive; see `didStartUp`) replaces rather than doubles it.
  private enum CancelID { case startupSubscriptions }

  /// Publishes startup work only after profile restoration and the CLI
  /// listener's terminal result. Launch precedes the initial `profileChanged`
  /// publication and workspace activation. The CLI is available to the launch
  /// hook only when that terminal result was successful.
  private func publishStartupHooksIfReady(state: inout State) -> Effect<Action> {
    guard
      state.didRestoreStartupProfile,
      state.didCompleteCLIStart,
      !state.didPublishTatamiLaunched
    else { return .none }
    state.didPublishTatamiLaunched = true

    // `AppConfig` always seeds at least one profile. Treat an empty profile
    // list as a broken startup invariant and surface it instead of silently
    // dropping the launch lifecycle event.
    guard let profile = state.config.activeProfile else {
      errorReporter.report(
        "StartupHooks",
        String(localized: "Hook configuration is invalid"),
        "Tatami launch context has no active profile after startup restoration",
      )
      return .none
    }

    let launchEffect: Effect<Action> =
      if state.config.hasEnabledHook(for: .tatamiLaunched) {
        .send(.hooks(.emit(HookInvocation(
          event: .tatamiLaunched,
          occurredAt: now,
          profile: .init(profile),
        ))))
      } else {
        .none
      }
    let profileChangedEffect: Effect<Action> =
      if state.config.hasEnabledHook(for: .profileChanged) {
        .send(.hooks(.emit(HookInvocation(
          event: .profileChanged,
          occurredAt: now,
          profile: .init(profile),
        ))))
      } else {
        .none
      }
    return .concatenate(
      launchEffect,
      profileChangedEffect,
      .send(.activation(.activateInitial)),
    )
  }

  private func activateProfileEffect(
    _ id: Profile.ID,
    focus: Workspace.ID?,
    previousProfile: Profile?,
    state: inout State,
  ) -> Effect<Action> {
    guard state.config.profiles.contains(where: { $0.id == id }) else {
      guard
        let request = state.activation.pendingCLIActivation,
        request.target == .profile(id)
      else { return .none }
      return .send(.activation(.failCLIActivation(
        requestID: request.id,
        error: "The requested profile no longer exists",
      )))
    }
    guard state.config.activeProfileId != id else {
      // Already the active profile. Just focus the requested workspace, if any.
      if let focus { return .send(.activation(.activate(workspaceId: focus, setFocus: true))) }
      return .none
    }
    let outgoingProfile = previousProfile ?? state.config.activeProfile
    state.$config.withLock { $0.activeProfileId = id }
    let currentProfile = state.config.activeProfile
    let hook: Effect<Action> =
      if
        state.config.hasEnabledHook(for: .profileChanged),
        let currentProfile,
        outgoingProfile?.id != currentProfile.id
      {
        .send(.hooks(.emit(HookInvocation(
          event: .profileChanged,
          occurredAt: now,
          profile: .init(currentProfile),
          previousProfile: outgoingProfile.map(HookInvocation.ProfileSnapshot.init),
        ))))
      } else {
        .none
      }
    // The sidebar is independent of the active profile, so switching which
    // profile runs does not disturb what is being viewed or edited.
    return .merge(
      .send(.hotKeys(.refreshBindings)),
      // Retile every display for the new profile. When `focus` is set, the
      // plan ends on that workspace so it lands active.
      .send(.activation(.reactivateActiveProfile(focus: focus))),
      .run { [profileSessionStore] _ in await profileSessionStore.saveActiveProfileId(id) },
      hook,
    )
  }

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

  private func actionAvailabilityError(
    _ action: HotKeyAction,
    config: AppConfig,
  ) -> String? {
    switch action {
    case .activateWorkspace(let id),
         .assignFocusedAppToWorkspace(let id):
      config.workspace(id: id) == nil ? "The requested workspace no longer exists" : nil

    case .borrowWorkspace(let id):
      config.activeProfile?.workspaces[id: id] == nil
        ? "The requested workspace is no longer available in the active profile"
        : nil

    case .activateProfile(let id):
      config.profiles.contains(where: { $0.id == id })
        ? nil
        : "The requested profile no longer exists"

    default:
      nil
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

extension AppConfig {
  fileprivate func hasEnabledHook(for event: HookEvent) -> Bool {
    HookDefinition.validate(hooks).validHooks.contains {
      $0.enabled && $0.event == event
    }
  }
}
