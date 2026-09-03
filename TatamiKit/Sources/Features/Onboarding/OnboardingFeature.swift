// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import IdentifiedCollections

// MARK: - OnboardingStep

public enum OnboardingStep: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case welcome
  case environment
  case workspaces
  case switching
  case tiling
  case borrow
  case floating
  case focusAndCycling
  case finish

  // MARK: Public

  public var id: String {
    rawValue
  }

  public var title: LocalizedStringResource {
    switch self {
    case .welcome: "Welcome"
    case .environment: "This Mac"
    case .workspaces: "Workspaces"
    case .switching: "Switching"
    case .tiling: "Tiling"
    case .borrow: "Borrow"
    case .floating: "Float & Ignore"
    case .focusAndCycling: "Focus & Cycling"
    case .finish: "Finish"
    }
  }

  public var icon: String {
    switch self {
    case .welcome: "sparkles"
    case .environment: "macbook.and.iphone"
    case .workspaces: "square.stack.3d.up"
    case .switching: "keyboard"
    case .tiling: "rectangle.split.2x2"
    case .borrow: "rectangle.righthalf.inset.filled"
    case .floating: "rectangle.on.rectangle"
    case .focusAndCycling: "cursorarrow.motionlines"
    case .finish: "checkmark.circle"
    }
  }
}

// MARK: - OnboardingPractice

public enum OnboardingPractice: String, Codable, Hashable, Sendable {
  case balance
  case borrow
  case borrowDismiss
  case cycle
  case floating
  case focus
  case fullscreen
  case focusFollowsMouse
  case gesture
  case ignore
  case mouseFollowsFocus
  case orientation
  case resize
  case swap
  case tiledHandling
  case windowGesture
  case workspaceGesture
  case workspaceSwitch
}

// MARK: - OnboardingContextStyle

public enum OnboardingContextStyle: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
  case focused
  case balanced
  case compact

  // MARK: Public

  public var id: String {
    rawValue
  }

  public var displayName: LocalizedStringResource {
    switch self {
    case .focused: "Focused"
    case .balanced: "Balanced"
    case .compact: "Compact"
    }
  }

  public var detail: LocalizedStringResource {
    switch self {
    case .focused: "More precise contexts; group only apps that always travel together."
    case .balanced: "A moderate number of activity-based contexts."
    case .compact: "Fewer broad contexts with more apps in each."
    }
  }

  // MARK: Internal

  var promptDescription: String {
    String(localized: detail)
  }
}

// MARK: - OnboardingDemoCommand

public enum OnboardingDemoCommand: Hashable, Sendable {
  case balance
  case cycle(CycleDirection)
  case focus(BSPDirection)
  case fullscreen
  case orientation
  case resize(delta: CGFloat)
  case swap(BSPDirection)
}

// MARK: - OnboardingDemoPoint

public struct OnboardingDemoPoint: Codable, Equatable, Sendable {
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public var x: Double
  public var y: Double
}

// MARK: - OnboardingDemoBlock

public enum OnboardingDemoBlock: String, Codable, Equatable, Sendable {
  case host
  case borrowed
}

// MARK: - OnboardingMode

public enum OnboardingMode: String, Codable, Hashable, Sendable {
  case fresh
  case review
}

// MARK: - OnboardingAppDestination

public enum OnboardingAppDestination: Hashable, Sendable {
  case shared
  case unassigned
  case workspace(Workspace.ID)
}

// MARK: - OnboardingRecommendationResponse

public enum OnboardingRecommendationResponse: Equatable, Sendable {
  case failure(String)
  case success(OnboardingRecommendation)
}

// MARK: - OnboardingRecommendationChange

public struct OnboardingRecommendationChange: Equatable, Identifiable, Sendable {
  public init(app: MacApp, destinationName: String) {
    self.app = app
    self.destinationName = destinationName
  }

  public var app: MacApp
  public var destinationName: String

  public var id: String {
    app.bundleIdentifier
  }
}

// MARK: - OnboardingWorkspaceAppGroup

public struct OnboardingWorkspaceAppGroup: Equatable, Identifiable, Sendable {
  public init(workspace: Workspace, apps: [MacApp]) {
    self.workspace = workspace
    self.apps = apps
  }

  public var workspace: Workspace
  public var apps: [MacApp]

  public var id: Workspace.ID {
    workspace.id
  }
}

// MARK: - OnboardingConfigSnapshot

public struct OnboardingConfigSnapshot: Codable, Equatable, Sendable {
  public init(_ config: AppConfig) {
    self.config = config
    activeProfileId = config.activeProfileId
  }

  public var config: AppConfig
  public var activeProfileId: Profile.ID?

  public var restored: AppConfig {
    var result = config
    result.activeProfileId = activeProfileId
    return result
  }
}

// MARK: - OnboardingProgress

public struct OnboardingProgress: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  public init(
    baseline: OnboardingConfigSnapshot,
    demoActiveWorkspaceID: Workspace.ID?,
    demoBorrowed: Bool,
    demoFullscreenZoomed: [Workspace.ID: Set<SlotID>],
    demoLayoutMode: LayoutMode,
    demoLayoutTree: BSPNode<SlotID>?,
    draft: OnboardingConfigSnapshot,
    furthestStepIndex: Int,
    contextStyle: OnboardingContextStyle,
    practices: Set<OnboardingPractice>,
    prefersScratchpads: Bool,
    recurringWork: String,
    roleDescription: String,
    step: OnboardingStep,
  ) {
    self.baseline = baseline
    self.demoActiveWorkspaceID = demoActiveWorkspaceID
    self.demoBorrowed = demoBorrowed
    self.demoFullscreenSlot = demoActiveWorkspaceID.flatMap { workspaceID in
      demoLayoutTree?.windows.first(where: {
        demoFullscreenZoomed[workspaceID]?.contains($0) == true
      })
    }
    self.demoFullscreenZoomed = demoFullscreenZoomed
    self.demoLayoutMode = demoLayoutMode
    self.demoLayoutTree = demoLayoutTree
    self.draft = draft
    self.furthestStepIndex = furthestStepIndex
    self.contextStyle = contextStyle
    self.practices = practices
    self.prefersScratchpads = prefersScratchpads
    self.recurringWork = recurringWork
    self.roleDescription = roleDescription
    self.step = step
  }

  // MARK: Public

  public var baseline: OnboardingConfigSnapshot
  public var demoActiveWorkspaceID: Workspace.ID?
  public var demoBorrowed: Bool
  /// Legacy single-window field retained so v1 progress snapshots still decode.
  public var demoFullscreenSlot: SlotID?
  public var demoFullscreenZoomed: [Workspace.ID: Set<SlotID>]?
  public var demoLayoutMode: LayoutMode
  public var demoLayoutTree: BSPNode<SlotID>?
  public var draft: OnboardingConfigSnapshot
  public var furthestStepIndex: Int
  public var contextStyle: OnboardingContextStyle
  public var practices: Set<OnboardingPractice>
  public var prefersScratchpads: Bool
  public var recurringWork: String
  public var roleDescription: String
  public var step: OnboardingStep

  public var restoredDemoFullscreenZoomed: [Workspace.ID: Set<SlotID>] {
    if let demoFullscreenZoomed {
      return demoFullscreenZoomed
    }
    guard let demoActiveWorkspaceID, let demoFullscreenSlot else { return [:] }
    return [demoActiveWorkspaceID: [demoFullscreenSlot]]
  }

}

// MARK: - OnboardingPreparation

public struct OnboardingPreparation: Equatable, Sendable {
  var apps: [MacApp]
  var config: AppConfig
  var displays: [DisplayName]
  var hasAccessibility: Bool
  var hasScreenRecording: Bool
  var mode: OnboardingMode
  var progress: OnboardingProgress?
  var requestsPresentation: Bool
}

// MARK: - OnboardingFeature

@Reducer
public struct OnboardingFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public var activateAfterApplying = true
    public var aiRecommendation: OnboardingRecommendation?
    public var aiRecommendationAvailability = OnboardingRecommendationAvailability.unavailable(
      "Checking Apple Intelligence…"
    )
    public var aiRecommendationError: String?
    public var baseline = AppConfig()
    public var configurationConflict = false
    public var conflictingConfig: AppConfig?
    public var contextStyle = OnboardingContextStyle.focused
    public var demoActionResult: String?
    public var demoActiveWorkspaceID: Workspace.ID?
    public var demoBorrowEdge: BorrowEdge?
    public var demoBorrowPendingWorkspaceID: Workspace.ID?
    public var demoBorrowWorkspaceID: Workspace.ID?
    public var demoBorrowed = false
    public var demoBorrowLayoutTree: BSPNode<SlotID>?
    public var demoBorrowSelectedSlot: SlotID?
    public var demoFocusedBlock = OnboardingDemoBlock.host
    public var demoFullscreenZoomed = [Workspace.ID: Set<SlotID>]()
    public var demoLastGesture: TrackpadGesture?
    public var demoLastShortcut: HotKeyAction?
    public var demoLayoutMode = LayoutMode.tiled
    public var demoLayoutTree: BSPNode<SlotID>?
    public var demoPreviousWorkspaceID: Workspace.ID?
    public var demoGestureWindowIndex = 0
    public var demoPointerLocation: OnboardingDemoPoint?
    public var demoPointerBlock = OnboardingDemoBlock.host
    public var demoSelectedSlot: SlotID?
    public var demoWindowMRU = [Workspace.ID: [SlotID]]()
    public var dismissalRequest = 0
    public var displays = [DisplayName]()
    public var draft = AppConfig()
    public var externalAIPromptCopied = false

    public var demoBorrowFullscreenSlots: Set<SlotID> {
      guard let demoBorrowWorkspaceID else { return [] }
      return demoFullscreenZoomed[demoBorrowWorkspaceID] ?? []
    }

    public var demoFullscreenSlots: Set<SlotID> {
      guard let demoActiveWorkspaceID else { return [] }
      return demoFullscreenZoomed[demoActiveWorkspaceID] ?? []
    }
    public var furthestStepIndex = 0
    public var hasAccessibility = true
    public var hasScreenRecording = true
    public var isApplying = false
    public var isGeneratingRecommendation = false
    public var isPresented = false
    public var mode = OnboardingMode.fresh
    public var practices = Set<OnboardingPractice>()
    public var prefersScratchpads = true
    public var presentationRequest = 0
    public var recurringWork = ""
    public var roleDescription = ""
    public var runningApps = [MacApp]()
    public var step = OnboardingStep.welcome

    public var activeProfile: Profile? {
      draft.activeProfile
    }

    public var activeProfileID: Profile.ID? {
      draft.activeProfileId ?? draft.profiles.first?.id
    }

    public var normalWorkspaces: [Workspace] {
      activeProfile?.workspaces.filter { $0.kind == .normal } ?? []
    }

    /// The fresh-install placeholders are intentionally generic. Until the
    /// user changes them, Guided Setup can teach with richer role examples;
    /// once edited, the preview should always reflect the user's own draft.
    public var hasCustomizedWorkspaceMap: Bool {
      guard
        scratchpads.isEmpty,
        draft.sharedApps.isEmpty,
        normalWorkspaces.count == 2
      else { return true }

      let expected: [(name: String, key: String)] = [
        ("Primary", "1"),
        ("Secondary", "2"),
      ]
      return zip(normalWorkspaces, expected).contains { workspace, placeholder in
        workspace.name != placeholder.name
          || workspace.keyEquivalent != placeholder.key
          || !workspace.apps.isEmpty
          || workspace.displayHint != displays.first
      }
    }

    public var scratchpads: [Workspace] {
      activeProfile?.workspaces.filter { $0.kind == .scratchpad } ?? []
    }

    public var activeWorkspaces: [Workspace] {
      activeProfile?.workspaces.elements ?? []
    }

    public var validationMessage: String? {
      guard !normalWorkspaces.isEmpty else { return "Add at least one workspace." }
      if normalWorkspaces.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        return "Give every workspace a name."
      }
      let keys = normalWorkspaces.compactMap(\.keyEquivalent)
      if Set(keys).count != keys.count {
        return "Workspace keys must be unique."
      }
      return nil
    }

    public var canApply: Bool {
      validationMessage == nil
    }

    public var canRequestAIRecommendation: Bool {
      !roleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !recurringWork.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var demoApps: [MacApp] {
      let byID = Dictionary(uniqueKeysWithValues: allKnownApps
        .map { ($0.bundleIdentifier, $0) })
      return (demoLayoutTree?.windows ?? []).compactMap { byID[$0.bundleId] }
    }

    public var demoAppBySlot: [SlotID: MacApp] {
      let byID = Dictionary(uniqueKeysWithValues: allKnownApps
        .map { ($0.bundleIdentifier, $0) })
      return Dictionary(uniqueKeysWithValues: (demoLayoutTree?.windows ?? []).compactMap { slot in
        byID[slot.bundleId].map { (slot, $0) }
      })
    }

    public var demoBorrowAppBySlot: [SlotID: MacApp] {
      let byID = Dictionary(uniqueKeysWithValues: allKnownApps
        .map { ($0.bundleIdentifier, $0) })
      return Dictionary(uniqueKeysWithValues: (demoBorrowLayoutTree?.windows ?? []).compactMap { slot in
        byID[slot.bundleId].map { (slot, $0) }
      })
    }

    public var demoPrimarySlot: SlotID? {
      demoSelectedSlot ?? demoLayoutTree?.windows.first
    }

    public var activeDemoWorkspace: Workspace? {
      guard let demoActiveWorkspaceID else { return normalWorkspaces.first }
      return activeWorkspaces.first { $0.id == demoActiveWorkspaceID }
    }

    public var activeDemoApps: [MacApp] {
      activeDemoWorkspace.map { apps(in: $0.id) } ?? []
    }

    public var gestureDemoApps: [MacApp] {
      let assigned = activeDemoApps
      return Array((assigned.isEmpty ? allKnownApps : assigned).prefix(3))
    }

    public var demoBorrowWorkspace: Workspace? {
      guard let demoBorrowWorkspaceID else {
        return scratchpads.first ?? normalWorkspaces.first(where: { $0.id != demoActiveWorkspaceID })
      }
      return activeWorkspaces.first { $0.id == demoBorrowWorkspaceID }
    }

    public var demoBorrowApps: [MacApp] {
      demoBorrowWorkspace.map { apps(in: $0.id) } ?? []
    }

    public var demoEffectiveBorrowEdge: BorrowEdge {
      demoBorrowEdge
        ?? demoBorrowWorkspace?.borrowEdge
        ?? draft.settings.switching.borrowDefaultEdge
        ?? .right
    }

    public var demoEffectiveBorrowFraction: Double {
      demoBorrowWorkspace?.borrowFraction ?? draft.settings.switching.borrowFraction
    }

    public var workspaceAppGroups: [OnboardingWorkspaceAppGroup] {
      activeWorkspaces.map { workspace in
        OnboardingWorkspaceAppGroup(workspace: workspace, apps: apps(in: workspace.id))
      }
    }

    public var unassignedApps: [MacApp] {
      allKnownApps.filter { destination(for: $0.bundleIdentifier) == .unassigned }
    }

    public var sharedKnownApps: [MacApp] {
      allKnownApps.filter { destination(for: $0.bundleIdentifier) == .shared }
    }

    public var aiRecommendationChangeCount: Int {
      aiRecommendationChanges.count
    }

    public var aiRecommendationChanges: [OnboardingRecommendationChange] {
      guard let aiRecommendation else { return [] }
      let appByID = Dictionary(uniqueKeysWithValues: allKnownApps.map { ($0.bundleIdentifier, $0) })
      return aiRecommendation.assignments.compactMap { assignment in
        guard
          let app = appByID[assignment.bundleIdentifier],
          let workspaceName = assignment.workspaceName
        else { return nil }
        return OnboardingRecommendationChange(app: app, destinationName: workspaceName)
      }
    }

    public var allKnownApps: [MacApp] {
      var result = [MacApp]()
      var seen = Set<String>()
      let configured = draft.profiles.flatMap(\.workspaces).flatMap(\.apps).map(\.app)
        + draft.sharedApps.map(\.app)
      for app in runningApps + configured
        where seen.insert(app.bundleIdentifier).inserted
        && !MacApp.isTatami(app.bundleIdentifier)
      {
        result.append(app)
      }
      return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public var appDestinations: [String: OnboardingAppDestination] {
      Dictionary(uniqueKeysWithValues: allKnownApps.map { ($0.bundleIdentifier, destination(for: $0.bundleIdentifier)) })
    }

    public func apps(in workspaceID: Workspace.ID) -> [MacApp] {
      allKnownApps.filter { destination(for: $0.bundleIdentifier) == .workspace(workspaceID) }
    }

    public func destination(for bundleID: String) -> OnboardingAppDestination {
      if draft.sharedApps.contains(where: { $0.bundleIdentifier == bundleID }) {
        return .shared
      }
      for workspace in activeProfile?.workspaces ?? []
        where workspace.apps.contains(where: { $0.bundleIdentifier == bundleID })
      {
        return .workspace(workspace.id)
      }
      return .unassigned
    }

    public func workspaceName(_ id: Workspace.ID) -> String {
      draft.workspace(id: id)?.name ?? String(localized: "Workspace")
    }

    public func shortcut(for action: HotKeyAction) -> HotKey? {
      draft.hotKeyBindings.first { $0.action == action }?.hotKey
    }

  }

  public enum Action: BindableAction {
    case accessibilityChanged
    case addProfileButtonTapped
    case addScratchpadButtonTapped
    case addWorkspaceButtonTapped
    case appDestinationChanged(String, OnboardingAppDestination)
    case appStarted(config: AppConfig, hasExistingConfig: Bool)
    case aiRecommendationApplyButtonTapped
    case aiRecommendationButtonTapped
    case aiRecommendationDismissButtonTapped
    case aiRecommendationResponse(OnboardingRecommendationResponse)
    case applyButtonTapped
    case backButtonTapped
    case binding(BindingAction<State>)
    case chooseAppButtonTapped
    case chosenAppResponse(MacApp?)
    case configurationApplied
    case configurationConflictDetected(AppConfig)
    case deleteProfileButtonTapped(Profile.ID)
    case deleteWorkspaceButtonTapped(Workspace.ID)
    case demoCommandTapped(OnboardingDemoCommand)
    case demoDividerResized([BSPSide], CGFloat)
    case demoGestureEnabledChanged(Bool)
    case demoGesturePerformed(TrackpadGesture)
    case demoLayoutModeChanged(LayoutMode)
    case demoPointerHovered(OnboardingDemoBlock, SlotID, OnboardingDemoPoint)
    case demoShortcutPerformed(HotKeyAction)
    case demoTileMoved(source: [BSPSide], target: [BSPSide], zone: DropZone)
    case demoTileTapped(OnboardingDemoBlock, SlotID)
    case demoBorrowButtonTapped
    case demoBorrowCancelButtonTapped
    case demoBorrowChordKey(BorrowChordKey)
    case demoBorrowDirectionTapped(BorrowEdge)
    case demoBorrowWorkspaceTapped(Workspace.ID)
    case demoWorkspaceSelectionChanged(Workspace.ID)
    case demoWorkspaceTapped(Workspace.ID)
    case externalAIPromptCopyButtonTapped
    case externalAIResponsePasteButtonTapped
    case grantAccessibilityButtonTapped
    case grantScreenRecordingButtonTapped
    case nextButtonTapped
    case preparationResponse(OnboardingPreparation)
    case profileNameChanged(Profile.ID, String)
    case reloadConfigurationButtonTapped
    case relaunchButtonTapped
    case resetButtonTapped
    case shortcutChanged(HotKeyAction, HotKey?)
    case shortcutRecordingChanged(Bool)
    case startRequested(config: AppConfig)
    case stepSelected(OnboardingStep)
    case viewAppeared
    case viewDisappeared
    case workspaceDisplayChanged(Workspace.ID, DisplayName?)
    case workspaceKeyChanged(Workspace.ID, String)
    case workspaceNameChanged(Workspace.ID, String)
    case delegate(Delegate)

    // MARK: Public

    public enum Delegate {
      case applyRequested(baseline: AppConfig, draft: AppConfig, activateFirstWorkspace: Bool)
      case gesturePreviewChanged(enabled: Bool, threshold: Double)
      case gesturePreviewEnded
      case borrowChordPreviewChanged(Bool)
      case shortcutPreviewChanged(AppConfig)
      case shortcutPreviewEnded
      case shortcutRecordingChanged(Bool)
    }
  }

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .appStarted(let config, let hasExistingConfig):
        return prepare(
          config: config,
          mode: hasExistingConfig ? .review : .fresh,
          autoPresent: true,
          gate: .appLaunch(hasExistingConfig: hasExistingConfig),
        )

      case .startRequested(let config):
        return prepare(config: config, mode: .review, autoPresent: true, gate: .always)

      case .preparationResponse(let preparation):
        let matchingProgress = preparation.progress.flatMap {
          $0.baseline.restored == preparation.config ? $0 : nil
        }
        state.baseline = matchingProgress?.baseline.restored ?? preparation.config
        state.draft = matchingProgress?.draft.restored
          ?? makeDraft(from: preparation.config, apps: preparation.apps, displays: preparation.displays)
        if isFreshSetup(preparation.config) {
          seedRecommendedShortcuts(in: &state.draft.settings.shortcuts)
          seedRecommendedGestures(in: &state.draft.settings.gestures)
        }
        state.externalAIPromptCopied = false
        state.step = matchingProgress?.step ?? .welcome
        state.demoActiveWorkspaceID = matchingProgress?.demoActiveWorkspaceID
          ?? state.normalWorkspaces.first?.id
        state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        state.demoBorrowed = matchingProgress?.demoBorrowed ?? false
        state.demoFullscreenZoomed = matchingProgress?.restoredDemoFullscreenZoomed ?? [:]
        state.demoLayoutMode = matchingProgress?.demoLayoutMode ?? .tiled
        state.demoLayoutTree = restoredDemoLayoutTree(
          matchingProgress?.demoLayoutTree,
          workspaceID: state.demoActiveWorkspaceID,
          config: state.draft,
          includesAllAssignments: state.step == .floating || state.step == .focusAndCycling,
        )
        state.demoSelectedSlot = state.demoLayoutTree?.windows.first
        syncDemoBorrowLayout(state: &state)
        state.demoFocusedBlock = state.demoBorrowed ? .borrowed : .host
        state.demoPointerBlock = state.demoFocusedBlock
        state.displays = preparation.displays
        state.furthestStepIndex = matchingProgress?.furthestStepIndex ?? 0
        state.contextStyle = matchingProgress?.contextStyle ?? .focused
        state.hasAccessibility = preparation.hasAccessibility
        state.hasScreenRecording = preparation.hasScreenRecording
        state.mode = preparation.mode
        state.practices = matchingProgress?.practices ?? []
        state.prefersScratchpads = matchingProgress?.prefersScratchpads ?? true
        state.recurringWork = matchingProgress?.recurringWork ?? ""
        state.roleDescription = matchingProgress?.roleDescription ?? ""
        state.runningApps = mergedApps(preparation.apps, config: state.draft)
        state.aiRecommendation = nil
        state.aiRecommendationAvailability = onboardingRecommendations.availability()
        state.aiRecommendationError = nil
        state.isGeneratingRecommendation = false
        state.configurationConflict = false
        state.conflictingConfig = nil
        state.isApplying = false
        state.isPresented = preparation.requestsPresentation
        if preparation.requestsPresentation { state.presentationRequest += 1 }
        return persist(state)

      case .viewAppeared:
        state.isPresented = true
        state.hasAccessibility = accessibility.isTrusted()
        state.hasScreenRecording = screenRecording.isGranted()
        state.runningApps = mergedApps(runningApps.current(), config: state.draft)
        state.displays = displayClient.all()
        state.aiRecommendationAvailability = onboardingRecommendations.availability()
        return .merge(
          persist(state),
          .send(.delegate(.gesturePreviewChanged(
            enabled: state.draft.settings.gestures.enabled,
            threshold: state.draft.settings.gestures.threshold,
          ))),
          .send(.delegate(.shortcutPreviewChanged(state.draft))),
          .send(.delegate(.borrowChordPreviewChanged(
            state.demoBorrowPendingWorkspaceID != nil
          ))),
          .run { [accessibility] send in
            for await _ in accessibility.changes() {
              await send(.accessibilityChanged)
            }
          }
          .cancellable(id: CancelID.permissionChanges, cancelInFlight: true),
        )

      case .viewDisappeared:
        state.isPresented = false
        return .merge(
          persist(state),
          .cancel(id: CancelID.permissionChanges),
          .send(.delegate(.gesturePreviewEnded)),
          .send(.delegate(.shortcutPreviewEnded)),
          .send(.delegate(.borrowChordPreviewChanged(false))),
        )

      case .accessibilityChanged:
        state.hasAccessibility = accessibility.isTrusted()
        state.hasScreenRecording = screenRecording.isGranted()
        return persist(state)

      case .grantAccessibilityButtonTapped:
        return .run { [accessibility, onboardingProgress] _ in
          // System Settings can terminate and reopen Tatami itself after a
          // TCC change, bypassing our explicit relaunch button.
          await onboardingProgress.requestResumeAfterRelaunch()
          await accessibility.requestAccess()
          await accessibility.openSettings()
        }

      case .grantScreenRecordingButtonTapped:
        return .run { [onboardingProgress, screenRecording] _ in
          // Persist before prompting because macOS may own the subsequent
          // Quit & Reopen transaction and terminate this process directly.
          await onboardingProgress.requestResumeAfterRelaunch()
          await screenRecording.requestAccess()
          await screenRecording.openSettings()
        }

      case .relaunchButtonTapped:
        return .run { [accessibility, onboardingProgress] _ in
          await onboardingProgress.requestResumeAfterRelaunch()
          await accessibility.relaunch()
        }

      case .binding:
        state.externalAIPromptCopied = false
        return persist(state)

      case .stepSelected(let step):
        selectStep(step, state: &state)
        state.furthestStepIndex = max(state.furthestStepIndex, step.index)
        return persistAndSyncBorrowChord(state)

      case .backButtonTapped:
        guard let previous = state.step.previous else { return .none }
        selectStep(previous, state: &state)
        return persistAndSyncBorrowChord(state)

      case .nextButtonTapped:
        guard let next = state.step.next else { return .none }
        selectStep(next, state: &state)
        state.furthestStepIndex = max(state.furthestStepIndex, next.index)
        return persistAndSyncBorrowChord(state)

      case .addWorkspaceButtonTapped:
        guard let profileID = state.activeProfileID else { return .none }
        let existingKeys = Set(state.normalWorkspaces.compactMap(\.keyEquivalent))
        let key = Self.starterKeys.first { !existingKeys.contains($0) }
        let workspace = Workspace(
          id: uuid(),
          name: "Workspace \(state.normalWorkspaces.count + 1)",
          displayHint: state.displays.first,
          symbolIconName: "square.stack.3d.up",
          keyEquivalent: key,
        )
        state.draft.mutateProfile(profileID) { $0.workspaces.append(workspace) }
        if state.demoActiveWorkspaceID == nil { state.demoActiveWorkspaceID = workspace.id }
        if state.demoBorrowWorkspaceID == nil {
          state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        }
        state.aiRecommendation = nil
        return persistAndRefreshShortcuts(state)

      case .deleteWorkspaceButtonTapped(let id):
        guard
          let workspace = state.activeProfile?.workspaces[id: id],
          workspace.kind == .scratchpad || state.normalWorkspaces.count > 1
        else {
          return .none
        }
        state.draft.removeWorkspace(id)
        if state.demoActiveWorkspaceID == id {
          state.demoActiveWorkspaceID = state.normalWorkspaces.first?.id
          syncDemoLayout(state: &state)
        }
        if state.demoBorrowWorkspaceID == id {
          state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        }
        state.aiRecommendation = nil
        return persistAndRefreshShortcuts(state)

      case .workspaceNameChanged(let id, let name):
        state.draft.mutateWorkspace(id) { $0.name = name }
        state.aiRecommendation = nil
        return persist(state)

      case .workspaceKeyChanged(let id, let key):
        let normalized = key.lowercased().first.map(String.init)
        state.draft.mutateWorkspace(id) { $0.keyEquivalent = normalized }
        return persistAndRefreshShortcuts(state)

      case .workspaceDisplayChanged(let id, let display):
        state.draft.mutateWorkspace(id) { $0.displayHint = display }
        return persist(state)

      case .appDestinationChanged(let bundleID, let destination):
        guard assignApp(bundleID, to: destination, state: &state) else { return .none }
        syncDemoLayout(state: &state)
        state.aiRecommendation = nil
        return persist(state)

      case .chooseAppButtonTapped:
        return .run { [appChooser] send in
          await send(.chosenAppResponse(await appChooser.choose()))
        }

      case .chosenAppResponse(let app):
        guard let app, !MacApp.isTatami(app.bundleIdentifier) else { return .none }
        state.runningApps = mergedApps(state.runningApps + [app], config: state.draft)
        syncDemoLayout(state: &state)
        return persist(state)

      case .externalAIPromptCopyButtonTapped:
        guard state.canRequestAIRecommendation else {
          state.aiRecommendationError = "Describe your role or a typical week first."
          return .none
        }
        let prompt = onboardingRecommendations.makeExternalPrompt(
          state.allKnownApps,
          OnboardingRecommendationContext(
            role: state.roleDescription,
            recurringWork: state.recurringWork,
            contextStyle: state.contextStyle,
            prefersScratchpads: state.prefersScratchpads,
            displays: recommendationDisplays(),
          ),
        )
        guard clipboard.writeString(prompt) else {
          state.externalAIPromptCopied = false
          state.aiRecommendationError = "Tatami could not write the prompt to the clipboard."
          return .none
        }
        state.externalAIPromptCopied = true
        state.aiRecommendationError = nil
        return .none

      case .externalAIResponsePasteButtonTapped:
        guard let response = clipboard.readString(), !response.isEmpty else {
          state.aiRecommendationError = "Copy the AI's JSON result, then try Paste Result again."
          return .none
        }
        do {
          state.aiRecommendation = try onboardingRecommendations.parseExternalResponse(
            response,
            state.allKnownApps,
          )
          state.aiRecommendationError = nil
        } catch {
          state.aiRecommendation = nil
          state.aiRecommendationError = "That result did not match Tatami's workspace format. Ask the AI to answer with only the requested JSON, then copy it again."
        }
        return .none

      case .aiRecommendationButtonTapped:
        guard !state.isGeneratingRecommendation else { return .none }
        guard state.canRequestAIRecommendation else {
          state.aiRecommendationError = "Describe your role or recurring work first."
          return .none
        }
        state.isGeneratingRecommendation = true
        state.aiRecommendation = nil
        state.aiRecommendationError = nil
        let apps = state.allKnownApps
        let context = OnboardingRecommendationContext(
          role: state.roleDescription,
          recurringWork: state.recurringWork,
          contextStyle: state.contextStyle,
          prefersScratchpads: state.prefersScratchpads,
          displays: recommendationDisplays(),
        )
        return .run { [onboardingRecommendations] send in
          do {
            let recommendation = try await onboardingRecommendations.recommend(apps, context)
            await send(.aiRecommendationResponse(.success(recommendation)))
          } catch {
            await send(.aiRecommendationResponse(.failure(
              "Apple Intelligence could not finish this recommendation. Try again in a moment."
            )))
          }
        }
        .cancellable(id: CancelID.aiRecommendation, cancelInFlight: true)

      case .aiRecommendationResponse(.success(let recommendation)):
        state.isGeneratingRecommendation = false
        state.aiRecommendation = recommendation
        return .none

      case .aiRecommendationResponse(.failure(let message)):
        state.isGeneratingRecommendation = false
        state.aiRecommendationError = message
        return .none

      case .aiRecommendationApplyButtonTapped:
        guard
          let recommendation = state.aiRecommendation,
          let profileID = state.activeProfileID
        else { return .none }
        let display = state.displays.first
        var workspaceIDByName = [String: Workspace.ID]()
        let workspaces = recommendation.workspaces.enumerated().map { index, suggestion in
          let id = uuid()
          workspaceIDByName[normalizedWorkspaceName(suggestion.name)] = id
          return Workspace(
            id: id,
            name: suggestion.name,
            displayHint: display,
            symbolIconName: suggestedWorkspaceSymbol(for: suggestion.name),
            kind: suggestion.kind,
            keyEquivalent: Self.starterKeys.indices.contains(index)
              ? Self.starterKeys[index]
              : nil,
            borrowEdge: suggestion.kind == .scratchpad ? .right : nil,
          )
        }
        state.draft.mutateProfile(profileID) { profile in
          profile.workspaces = IdentifiedArray(uniqueElements: workspaces)
          // The recommendation replaces the workspace set wholesale with new
          // identities. Existing chains cannot be remapped reliably because
          // suggestions may rename, split, or merge workspaces.
          profile.workspaceChains = []
        }
        var assignedScratchpads = Set<Workspace.ID>()
        for assignment in recommendation.assignments {
          let workspaceID = assignment.workspaceName
            .flatMap { workspaceIDByName[normalizedWorkspaceName($0)] }
          let destination: OnboardingAppDestination =
            if
              let workspaceID,
              state.draft.workspace(id: workspaceID)?.kind == .scratchpad
            {
              assignedScratchpads.insert(workspaceID).inserted
                ? .workspace(workspaceID)
                : .unassigned
            } else {
              workspaceID.map(OnboardingAppDestination.workspace) ?? .unassigned
            }
          _ = assignApp(assignment.bundleIdentifier, to: destination, state: &state)
        }
        state.demoActiveWorkspaceID = state.normalWorkspaces.first?.id
        state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        syncDemoLayout(state: &state)
        state.aiRecommendation = nil
        state.aiRecommendationError = nil
        return persistAndRefreshShortcuts(state)

      case .aiRecommendationDismissButtonTapped:
        state.aiRecommendation = nil
        state.aiRecommendationError = nil
        return .none

      case .demoWorkspaceTapped(let id):
        guard activateDemoWorkspace(id, state: &state) else { return .none }
        state.practices.insert(.workspaceSwitch)
        return persist(state)

      case .demoWorkspaceSelectionChanged(let id):
        guard state.activeWorkspaces.contains(where: { $0.id == id }) else { return .none }
        if state.demoActiveWorkspaceID != id {
          state.demoPreviousWorkspaceID = state.demoActiveWorkspaceID
        }
        state.demoActiveWorkspaceID = id
        state.demoGestureWindowIndex = 0
        if state.demoBorrowWorkspaceID == id {
          state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
          dismissDemoBorrow(state: &state)
          syncDemoBorrowLayout(state: &state)
        }
        state.demoBorrowPendingWorkspaceID = nil
        syncDemoLayout(state: &state)
        state.demoFocusedBlock = .host
        if let selected = state.demoSelectedSlot {
          focusDemoWindow(selected, in: .host, state: &state)
        }
        followDemoFocusIfEnabled(state: &state)
        return persistAndSyncBorrowChord(state)

      case .demoBorrowWorkspaceTapped(let id):
        guard
          state.activeWorkspaces.contains(where: { $0.id == id }),
          id != state.demoActiveWorkspaceID
        else { return .none }
        state.demoBorrowWorkspaceID = id
        state.demoBorrowLayoutTree = nil
        state.demoBorrowSelectedSlot = nil
        dismissDemoBorrow(state: &state)
        syncDemoBorrowLayout(state: &state)
        return persistAndSyncBorrowChord(state)

      case .demoGestureEnabledChanged(let enabled):
        state.draft.settings.gestures.enabled = enabled
        state.demoLastGesture = nil
        return .merge(
          persist(state),
          .send(.delegate(.gesturePreviewChanged(
            enabled: enabled,
            threshold: state.draft.settings.gestures.threshold,
          ))),
        )

      case .demoGesturePerformed(let gesture):
        state.demoLastGesture = gesture
        state.practices.insert(.gesture)
        switch state.draft.settings.gestures.action(for: gesture) {
        case .nextWorkspace:
          _ = switchDemoWorkspace(offset: 1, state: &state)
          state.practices.insert(.workspaceGesture)
          state.practices.insert(.workspaceSwitch)

        case .previousWorkspace:
          _ = switchDemoWorkspace(offset: -1, state: &state)
          state.practices.insert(.workspaceGesture)
          state.practices.insert(.workspaceSwitch)

        case .cycleNextWindow:
          if state.step.index >= OnboardingStep.tiling.index {
            _ = applyDemoCommand(.cycle(.next), state: &state)
          } else {
            cycleGestureWindow(offset: 1, state: &state)
          }
          state.practices.insert(.windowGesture)

        case .cyclePreviousWindow:
          if state.step.index >= OnboardingStep.tiling.index {
            _ = applyDemoCommand(.cycle(.previous), state: &state)
          } else {
            cycleGestureWindow(offset: -1, state: &state)
          }
          state.practices.insert(.windowGesture)

        default:
          break
        }
        return persist(state)

      case .demoBorrowButtonTapped:
        guard let id = state.demoBorrowWorkspaceID ?? state.demoBorrowWorkspace?.id else {
          return .none
        }
        guard beginDemoBorrow(workspaceID: id, state: &state) else { return .none }
        return persistAndSyncBorrowChord(state)

      case .demoBorrowDirectionTapped(let edge):
        guard let id = state.demoBorrowPendingWorkspaceID else { return .none }
        performDemoBorrow(workspaceID: id, edge: edge, state: &state)
        return persistAndSyncBorrowChord(state)

      case .demoBorrowChordKey(.edge(let edge)):
        guard let id = state.demoBorrowPendingWorkspaceID else { return .none }
        performDemoBorrow(workspaceID: id, edge: edge, state: &state)
        return persistAndSyncBorrowChord(state)

      case .demoBorrowChordKey(.cancel):
        guard state.demoBorrowPendingWorkspaceID != nil else { return .none }
        state.demoBorrowPendingWorkspaceID = nil
        state.demoActionResult = String(localized: "Borrow cancelled")
        return persistAndSyncBorrowChord(state)

      case .demoBorrowCancelButtonTapped:
        guard state.demoBorrowPendingWorkspaceID != nil else { return .none }
        state.demoBorrowPendingWorkspaceID = nil
        state.demoActionResult = String(localized: "Borrow cancelled")
        return persistAndSyncBorrowChord(state)

      case .demoLayoutModeChanged(let mode):
        setDemoLayoutMode(mode, state: &state)
        return persist(state)

      case .demoTileTapped(let block, let slot):
        guard demoTree(for: block, state: state)?.windows.contains(slot) == true else {
          return .none
        }
        focusDemoWindow(slot, in: block, state: &state)
        state.demoPointerBlock = block
        state.demoPointerLocation = demoPointerTarget(for: slot, in: block, state: state)
        state.practices.insert(.focus)
        return persist(state)

      case .demoPointerHovered(let block, let slot, let location):
        guard demoTree(for: block, state: state)?.windows.contains(slot) == true else {
          return .none
        }
        state.demoPointerBlock = block
        state.demoPointerLocation = location
        guard
          state.draft.settings.focus.focusFollowsMouse,
          state.demoFocusedBlock != block || demoSelection(in: block, state: state) != slot
        else { return .none }
        focusDemoWindow(slot, in: block, state: &state)
        state.practices.insert(.focusFollowsMouse)
        state.demoActionResult = String(
          localized: "FFM focused \(demoAppName(for: slot, in: block, state: state))"
        )
        return persist(state)

      case .demoDividerResized(let path, let ratio):
        guard let tree = state.demoLayoutTree else { return .none }
        let updated = tree.applying(.setRatio(path: path, ratio: ratio))
        guard updated != tree else { return .none }
        state.demoLayoutTree = updated
        state.practices.insert(.resize)
        return persist(state)

      case .demoTileMoved(let source, let target, let zone):
        guard let tree = state.demoLayoutTree else { return .none }
        let updated = tree.applying(.relocate(source: source, target: target, zone: zone))
        guard updated != tree else { return .none }
        state.demoLayoutTree = updated
        state.practices.insert(zone == .swap ? .swap : .resize)
        return persist(state)

      case .demoCommandTapped(let command):
        guard applyDemoCommand(command, state: &state) else { return .none }
        return persist(state)

      case .demoShortcutPerformed(let shortcut):
        let recognizedShortcut = recognizedDemoShortcut(shortcut, state: state)
        guard applyDemoShortcut(shortcut, state: &state) else { return .none }
        state.demoLastShortcut = recognizedShortcut
        return persistAndSyncBorrowChord(state)

      case .addScratchpadButtonTapped:
        guard state.scratchpads.isEmpty, let profileID = state.activeProfileID else { return .none }
        let displayHint = state.displays.first
        let id = uuid()
        state.draft.mutateProfile(profileID) { profile in
          profile.workspaces.append(Workspace(
            id: id,
            name: "Quick Look",
            displayHint: displayHint,
            symbolIconName: "tray.full",
            kind: .scratchpad,
            keyEquivalent: "q",
            borrowFraction: 0.4,
          ))
        }
        state.demoBorrowWorkspaceID = id
        state.practices.insert(.borrow)
        return persistAndRefreshShortcuts(state)

      case .addProfileButtonTapped:
        guard let source = state.activeProfile else { return .none }
        var workspaceIDMap = [Workspace.ID: Workspace.ID]()
        var workspaces: IdentifiedArrayOf<Workspace> = []
        for var workspace in source.workspaces {
          let sourceID = workspace.id
          workspace.id = uuid()
          workspaceIDMap[sourceID] = workspace.id
          workspaces.append(workspace)
        }
        let workspaceChains: [WorkspaceChain] = source.workspaceChains.compactMap { sourceChain in
          var chain = sourceChain
          chain.id = uuid()
          let workspaceIDs = sourceChain.workspaceIDs.compactMap { workspaceIDMap[$0] }
          guard workspaceIDs.count == sourceChain.workspaceIDs.count else { return nil }
          chain.workspaceIDs = workspaceIDs
          let dynamicWorkspaceIDs = sourceChain.dynamicWorkspaceIDs.compactMap {
            workspaceIDMap[$0]
          }
          guard dynamicWorkspaceIDs.count == sourceChain.dynamicWorkspaceIDs.count else {
            return nil
          }
          chain.dynamicWorkspaceIDs = dynamicWorkspaceIDs
          return chain
        }
        let profile = Profile(
          id: uuid(),
          name: state.displays.count > 1 ? "Desk" : "Another Setup",
          symbolIconName: "display.2",
          autoActivation: ProfileActivation(displayCount: .atLeast(2)),
          workspaceChains: workspaceChains,
          workspaces: workspaces,
        )
        if
          let sourceIndex = state.draft.profiles.firstIndex(where: { $0.id == source.id }),
          state.draft.profiles[sourceIndex].autoActivation == nil
        {
          state.draft.profiles[sourceIndex].autoActivation = ProfileActivation(displayCount: .atMost(1))
        }
        state.draft.profiles.append(profile)
        return persist(state)

      case .deleteProfileButtonTapped(let id):
        guard state.draft.profiles.count > 1 else { return .none }
        state.draft.profiles.removeAll { $0.id == id }
        if state.draft.activeProfileId == id {
          state.draft.activeProfileId = state.draft.profiles.first?.id
        }
        return persist(state)

      case .profileNameChanged(let id, let name):
        state.draft.mutateProfile(id) { $0.name = name }
        return persist(state)

      case .applyButtonTapped:
        state.isApplying = true
        state.configurationConflict = false
        return .send(.delegate(.applyRequested(
          baseline: state.baseline,
          draft: state.draft,
          activateFirstWorkspace: state.activateAfterApplying && state.hasAccessibility,
        )))

      case .configurationConflictDetected(let latest):
        state.configurationConflict = true
        state.conflictingConfig = latest
        state.isApplying = false
        return .none

      case .reloadConfigurationButtonTapped:
        guard let latest = state.conflictingConfig else { return .none }
        state.baseline = latest
        state.draft = makeDraft(from: latest, apps: state.runningApps, displays: state.displays)
        state.configurationConflict = false
        state.conflictingConfig = nil
        state.demoActiveWorkspaceID = state.normalWorkspaces.first?.id
        state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        syncDemoLayout(state: &state)
        state.aiRecommendation = nil
        return persistAndRefreshShortcuts(state)

      case .configurationApplied:
        state.baseline = state.draft
        state.isApplying = false
        state.isPresented = false
        state.dismissalRequest += 1
        return .concatenate(
          .cancel(id: CancelID.saveProgress),
          .run { [onboardingProgress] _ in await onboardingProgress.complete() },
        )

      case .resetButtonTapped:
        state.draft = makeDraft(from: state.baseline, apps: state.runningApps, displays: state.displays)
        state.contextStyle = .focused
        state.prefersScratchpads = true
        state.recurringWork = ""
        state.roleDescription = ""
        state.step = .welcome
        state.furthestStepIndex = 0
        state.practices = []
        state.demoActiveWorkspaceID = state.normalWorkspaces.first?.id
        state.demoPreviousWorkspaceID = nil
        state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
        state.demoBorrowed = false
        state.demoBorrowLayoutTree = nil
        state.demoBorrowSelectedSlot = nil
        state.demoBorrowEdge = nil
        state.demoBorrowPendingWorkspaceID = nil
        state.demoFocusedBlock = .host
        state.demoFullscreenZoomed = [:]
        state.demoLastGesture = nil
        state.demoLastShortcut = nil
        state.demoActionResult = nil
        state.demoLayoutMode = .tiled
        state.demoPointerBlock = .host
        state.demoPointerLocation = nil
        state.demoWindowMRU = [:]
        state.demoGestureWindowIndex = 0
        syncDemoLayout(state: &state)
        syncDemoBorrowLayout(state: &state)
        state.aiRecommendation = nil
        state.aiRecommendationError = nil
        state.configurationConflict = false
        state.conflictingConfig = nil
        return .merge(
          persistAndRefreshShortcuts(state),
          .send(.delegate(.borrowChordPreviewChanged(false))),
        )

      case .shortcutChanged(let action, let hotKey):
        guard setShortcut(action, hotKey: hotKey, state: &state) else { return .none }
        state.demoLastShortcut = nil
        return persistAndRefreshShortcuts(state)

      case .shortcutRecordingChanged(let recording):
        return .send(.delegate(.shortcutRecordingChanged(recording)))

      case .delegate:
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.accessibility) var accessibility
  @Dependency(\.appChooser) var appChooser
  @Dependency(\.clipboard) var clipboard
  @Dependency(\.displays) var displayClient
  @Dependency(\.onboardingRecommendations) var onboardingRecommendations
  @Dependency(\.onboardingProgress) var onboardingProgress
  @Dependency(\.runningApps) var runningApps
  @Dependency(\.screenRecording) var screenRecording
  @Dependency(\.uuid) var uuid

  // MARK: Private

  private enum CancelID {
    case aiRecommendation
    case permissionChanges
    case saveProgress
  }

  private enum PreparationGate: Sendable {
    case always
    case appLaunch(hasExistingConfig: Bool)
  }

  private static let starterKeys = ["1", "2", "3", "4", "5", "6", "7", "8"]
  private static let demoWorkArea = CGRect(x: 0, y: 0, width: 1200, height: 720)

  private func recommendationDisplays() -> [OnboardingRecommendationDisplay] {
    let displays = displayClient.all()
    let primary = displayClient.primary()
    return displays.enumerated().map { index, display in
      let workArea = displayClient.workArea(display)
      let hasUsableArea = workArea.width > 0 && workArea.height > 0
      return OnboardingRecommendationDisplay(
        name: display.name,
        usableWidth: hasUsableArea ? Int(workArea.width.rounded()) : nil,
        usableHeight: hasUsableArea ? Int(workArea.height.rounded()) : nil,
        isPrimary: primary.map { display.matches($0) } ?? (index == 0),
      )
    }
  }

  private func prepare(
    config: AppConfig,
    mode: OnboardingMode,
    autoPresent: Bool,
    gate: PreparationGate,
  ) -> Effect<Action> {
    .run {
      [accessibility, displayClient, onboardingProgress, runningApps, screenRecording]
      send in
      switch gate {
      case .always:
        break

      case .appLaunch(let hasExistingConfig):
        let shouldResume = await onboardingProgress.consumeResumeAfterRelaunch()
        if !shouldResume {
          guard !hasExistingConfig else { return }
          guard !(await onboardingProgress.hasCompleted()) else { return }
        }
      }
      let progress = await onboardingProgress.load()
      let environment = await MainActor.run {
        (
          runningApps.current(),
          displayClient.all(),
          accessibility.isTrusted(),
          screenRecording.isGranted(),
        )
      }
      await send(.preparationResponse(OnboardingPreparation(
        apps: environment.0,
        config: config,
        displays: environment.1,
        hasAccessibility: environment.2,
        hasScreenRecording: environment.3,
        mode: mode,
        progress: progress,
        requestsPresentation: autoPresent,
      )))
    }
  }

  private func persist(_ state: State) -> Effect<Action> {
    let progress = OnboardingProgress(
      baseline: OnboardingConfigSnapshot(state.baseline),
      demoActiveWorkspaceID: state.demoActiveWorkspaceID,
      demoBorrowed: state.demoBorrowed,
      demoFullscreenZoomed: state.demoFullscreenZoomed,
      demoLayoutMode: state.demoLayoutMode,
      demoLayoutTree: state.demoLayoutTree,
      draft: OnboardingConfigSnapshot(state.draft),
      furthestStepIndex: state.furthestStepIndex,
      contextStyle: state.contextStyle,
      practices: state.practices,
      prefersScratchpads: state.prefersScratchpads,
      recurringWork: state.recurringWork,
      roleDescription: state.roleDescription,
      step: state.step,
    )
    return .run { [onboardingProgress] _ in await onboardingProgress.save(progress) }
      .cancellable(id: CancelID.saveProgress, cancelInFlight: true)
  }

  private func persistAndRefreshShortcuts(_ state: State) -> Effect<Action> {
    .merge(
      persist(state),
      .send(.delegate(.shortcutPreviewChanged(state.draft))),
    )
  }

  private func persistAndSyncBorrowChord(_ state: State) -> Effect<Action> {
    .merge(
      persist(state),
      .send(.delegate(.borrowChordPreviewChanged(
        state.demoBorrowPendingWorkspaceID != nil
      ))),
    )
  }

  private func makeDraft(
    from config: AppConfig,
    apps _: [MacApp],
    displays: [DisplayName],
  ) -> AppConfig {
    var draft = config
    let isFreshSetup = isFreshSetup(config)
    if
      isFreshSetup,
      draft.settings.general.launchAtLogin == AppSettings.General().launchAtLogin
    {
      draft.settings.general.launchAtLogin = true
    }
    if isFreshSetup {
      seedRecommendedShortcuts(in: &draft.settings.shortcuts)
      seedRecommendedGestures(in: &draft.settings.gestures)
    }
    if draft.profiles.isEmpty {
      draft.profiles = [Profile(id: uuid(), name: Profile.defaultName)]
    }
    guard draft.profiles.allSatisfy({ $0.workspaces.isEmpty }) else { return draft }

    let workspaces = [
      Workspace(
        id: uuid(),
        name: "Primary",
        displayHint: displays.first,
        symbolIconName: "square.stack.3d.up",
        keyEquivalent: "1",
      ),
      Workspace(
        id: uuid(),
        name: "Secondary",
        displayHint: displays.first,
        symbolIconName: "rectangle.stack",
        keyEquivalent: "2",
      ),
    ]
    let profileID = draft.activeProfileId ?? draft.profiles.first!.id
    draft.activeProfileId = profileID
    draft.mutateProfile(profileID) { profile in
      profile.workspaces = IdentifiedArray(uniqueElements: workspaces)
      profile.workspaceChains = []
    }
    return draft
  }

  private func isFreshSetup(_ config: AppConfig) -> Bool {
    config.profiles.allSatisfy(\.workspaces.isEmpty) && config.sharedApps.isEmpty
  }

  /// Onboarding uses the same starter scheme as Tatami's persisted fresh-install
  /// config. Existing or already-recorded values win; only missing bindings and
  /// untouched modifier defaults are filled.
  private func seedRecommendedShortcuts(in shortcuts: inout AppSettings.Shortcuts) {
    let defaults = AppSettings.Shortcuts()
    let recommended = AppSettings.Shortcuts.recommended
    let hotKeyPaths: [WritableKeyPath<AppSettings.Shortcuts, HotKey?>] = [
      \.focusLeft,
      \.focusRight,
      \.focusUp,
      \.focusDown,
      \.switchToNextWorkspace,
      \.switchToPreviousWorkspace,
      \.switchToRecentWorkspace,
      \.moveToNextWorkspace,
      \.moveToPreviousWorkspace,
      \.focusNextDisplay,
      \.focusPreviousDisplay,
      \.cycleNextWindow,
      \.cyclePreviousWindow,
      \.resizeGrow,
      \.resizeShrink,
      \.swapLeft,
      \.swapRight,
      \.swapUp,
      \.swapDown,
      \.toggleOrientation,
      \.toggleFullscreen,
      \.balance,
      \.toggleFloating,
      \.toggleSharedFloating,
      \.toggleSpaceActivated,
      \.toggleFocusedAppInActiveWorkspace,
      \.toggleAppInSharedApps,
      \.assignRecentWorkspace,
      \.assignNextWorkspace,
      \.assignPreviousWorkspace,
      \.borrowRecentWorkspace,
      \.borrowNextWorkspace,
      \.borrowPreviousWorkspace,
      \.dismissBorrow,
    ]
    for keyPath in hotKeyPaths where shortcuts[keyPath: keyPath] == nil {
      shortcuts[keyPath: keyPath] = recommended[keyPath: keyPath]
    }

    let workspaceKeyPaths: [WritableKeyPath<AppSettings.Shortcuts, String?>] = [
      \.recentWorkspaceKey,
      \.nextWorkspaceKey,
      \.previousWorkspaceKey,
    ]
    for keyPath in workspaceKeyPaths where shortcuts[keyPath: keyPath] == nil {
      shortcuts[keyPath: keyPath] = recommended[keyPath: keyPath]
    }

    if shortcuts.keyEquivalentModifiers == defaults.keyEquivalentModifiers {
      shortcuts.keyEquivalentModifiers = recommended.keyEquivalentModifiers
    }
    if shortcuts.assignModifiers == defaults.assignModifiers {
      shortcuts.assignModifiers = recommended.assignModifiers
    }
    if shortcuts.borrowModifiers == defaults.borrowModifiers {
      shortcuts.borrowModifiers = recommended.borrowModifiers
    }
  }

  /// Tatami's historical config default used three fingers for workspace
  /// switching. Guided Setup teaches the more deliberate current scheme:
  /// three fingers cycle local windows and four fingers change context.
  /// Only the untouched historical mapping is migrated; custom bindings win.
  private func seedRecommendedGestures(in gestures: inout AppSettings.Gestures) {
    let historical = AppSettings.Gestures()
    guard
      gestures.threeFinger == historical.threeFinger,
      gestures.fourFinger == historical.fourFinger
    else { return }
    gestures.threeFinger = .init(
      left: .cyclePreviousWindow,
      right: .cycleNextWindow,
    )
    gestures.fourFinger = .workspaceSwitch
  }

  private func normalizedWorkspaceName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func suggestedWorkspaceSymbol(for name: String) -> String {
    let value = name.lowercased()
    if value.contains("code") || value.contains("develop") { return "chevron.left.forwardslash.chevron.right" }
    if value.contains("design") { return "paintpalette.fill" }
    if value.contains("research") || value.contains("browse") { return "safari.fill" }
    if value.contains("write") || value.contains("document") { return "doc.text.fill" }
    if value.contains("chat") || value.contains("communicat") { return "ellipsis.message.fill" }
    if value.contains("plan") || value.contains("manage") { return "checklist" }
    return "square.stack.3d.up"
  }

  private func mergedApps(_ apps: [MacApp], config: AppConfig) -> [MacApp] {
    var result = [MacApp]()
    var seen = Set<String>()
    let configured = config.profiles.flatMap(\.workspaces).flatMap(\.apps).map(\.app)
      + config.sharedApps.map(\.app)
    for app in apps + configured
      where seen.insert(app.bundleIdentifier).inserted
      && !MacApp.isTatami(app.bundleIdentifier)
    {
      result.append(app)
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func makeDemoLayoutTree(
    workspaceID: Workspace.ID?,
    config: AppConfig,
    includesAllAssignments: Bool = false,
  ) -> BSPNode<SlotID>? {
    guard let workspaceID, let workspace = config.workspace(id: workspaceID) else { return nil }
    let bundleIDs =
      if includesAllAssignments {
        workspace.apps.map(\.bundleIdentifier)
      } else {
        tiledLayoutBundleIds(workspace: workspace, sharedApps: config.sharedApps)
      }
    return BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: Array(bundleIDs))
  }

  private func restoredDemoLayoutTree(
    _ restored: BSPNode<SlotID>?,
    workspaceID: Workspace.ID?,
    config: AppConfig,
    includesAllAssignments: Bool = false,
  ) -> BSPNode<SlotID>? {
    let fresh = makeDemoLayoutTree(
      workspaceID: workspaceID,
      config: config,
      includesAllAssignments: includesAllAssignments,
    )
    guard
      let restored,
      Set(restored.windows) == Set(fresh?.windows ?? [])
    else { return fresh }
    return restored
  }

  private func syncDemoLayout(state: inout State) {
    state.demoLayoutTree = restoredDemoLayoutTree(
      state.demoLayoutTree,
      workspaceID: state.demoActiveWorkspaceID,
      config: state.draft,
      includesAllAssignments: state.step == .floating || state.step == .focusAndCycling,
    )
    if
      let selected = state.demoSelectedSlot,
      state.demoLayoutTree?.windows.contains(selected) == true
    {
      // Preserve the focused tile while the selected workspace's app set is unchanged.
    } else {
      state.demoSelectedSlot = state.demoLayoutTree?.windows.first
    }
    pruneDemoFullscreenSlots(
      workspaceID: state.demoActiveWorkspaceID,
      tree: state.demoLayoutTree,
      state: &state,
    )
    syncDemoLayoutMode(state: &state)
  }

  private func syncDemoBorrowLayout(state: inout State) {
    state.demoBorrowLayoutTree = restoredDemoLayoutTree(
      state.demoBorrowLayoutTree,
      workspaceID: state.demoBorrowWorkspaceID,
      config: state.draft,
      includesAllAssignments: true,
    )
    if
      let selected = state.demoBorrowSelectedSlot,
      state.demoBorrowLayoutTree?.windows.contains(selected) == true
    {
      // Preserve the visitor's focused tile while its app set is unchanged.
    } else {
      state.demoBorrowSelectedSlot = state.demoBorrowLayoutTree?.windows.first
    }
    pruneDemoFullscreenSlots(
      workspaceID: state.demoBorrowWorkspaceID,
      tree: state.demoBorrowLayoutTree,
      state: &state,
    )
  }

  private func pruneDemoFullscreenSlots(
    workspaceID: Workspace.ID?,
    tree: BSPNode<SlotID>?,
    state: inout State,
  ) {
    guard let workspaceID else { return }
    var fullscreen = state.demoFullscreenZoomed[workspaceID] ?? []
    fullscreen.formIntersection(Set(tree?.windows ?? []))
    state.demoFullscreenZoomed[workspaceID] = fullscreen.isEmpty ? nil : fullscreen
  }

  private func demoTree(
    for block: OnboardingDemoBlock,
    state: State,
  ) -> BSPNode<SlotID>? {
    switch block {
    case .host:
      state.demoLayoutTree
    case .borrowed:
      state.demoBorrowed ? state.demoBorrowLayoutTree : nil
    }
  }

  private func demoSelection(
    in block: OnboardingDemoBlock,
    state: State,
  ) -> SlotID? {
    switch block {
    case .host:
      state.demoSelectedSlot
    case .borrowed:
      state.demoBorrowSelectedSlot
    }
  }

  private func setDemoSelection(
    _ slot: SlotID,
    in block: OnboardingDemoBlock,
    state: inout State,
  ) {
    switch block {
    case .host:
      state.demoSelectedSlot = slot
      syncDemoLayoutMode(state: &state)

    case .borrowed:
      state.demoBorrowSelectedSlot = slot
    }
  }

  private func focusDemoWindow(
    _ slot: SlotID,
    in block: OnboardingDemoBlock,
    state: inout State,
  ) {
    setDemoSelection(slot, in: block, state: &state)
    state.demoFocusedBlock = block
    guard let workspaceID = demoWorkspaceID(for: block, state: state) else { return }
    var recent = state.demoWindowMRU[workspaceID] ?? []
    recent.removeAll { $0 == slot }
    recent.insert(slot, at: 0)
    let live = Set(demoTree(for: block, state: state)?.windows ?? [])
    state.demoWindowMRU[workspaceID] = recent.filter { live.contains($0) }
  }

  private func demoWorkspaceID(
    for block: OnboardingDemoBlock,
    state: State,
  ) -> Workspace.ID? {
    switch block {
    case .host:
      state.demoActiveWorkspaceID
    case .borrowed:
      state.demoBorrowWorkspaceID
    }
  }

  private func setDemoTree(
    _ tree: BSPNode<SlotID>,
    in block: OnboardingDemoBlock,
    state: inout State,
  ) {
    switch block {
    case .host:
      state.demoLayoutTree = tree
    case .borrowed:
      state.demoBorrowLayoutTree = tree
    }
  }

  private func demoFullscreenSlots(
    in block: OnboardingDemoBlock,
    state: State,
  ) -> Set<SlotID> {
    guard let workspaceID = demoWorkspaceID(for: block, state: state) else { return [] }
    return state.demoFullscreenZoomed[workspaceID] ?? []
  }

  private func setDemoFullscreenSlots(
    _ slots: Set<SlotID>,
    in block: OnboardingDemoBlock,
    state: inout State,
  ) {
    guard let workspaceID = demoWorkspaceID(for: block, state: state) else { return }
    state.demoFullscreenZoomed[workspaceID] = slots.isEmpty ? nil : slots
  }

  private func demoAppName(
    for slot: SlotID,
    in block: OnboardingDemoBlock,
    state: State,
  ) -> String {
    switch block {
    case .host:
      state.demoAppBySlot[slot]?.name ?? String(localized: "the hovered window")
    case .borrowed:
      state.demoBorrowAppBySlot[slot]?.name ?? String(localized: "the hovered window")
    }
  }

  private func syncDemoLayoutMode(state: inout State) {
    guard
      let workspaceID = state.demoActiveWorkspaceID,
      let bundleID = state.demoPrimarySlot?.bundleId,
      let assignment = state.draft.workspace(id: workspaceID)?.apps.first(where: {
        $0.bundleIdentifier == bundleID
      })
    else {
      state.demoLayoutMode = .tiled
      return
    }
    state.demoLayoutMode = assignment.layout
  }

  private func setDemoLayoutMode(_ mode: LayoutMode, state: inout State) {
    state.demoLayoutMode = mode
    switch mode {
    case .tiled: state.practices.insert(.tiledHandling)
    case .floating: state.practices.insert(.floating)
    case .unmanaged: state.practices.insert(.ignore)
    }
    guard
      let workspaceID = state.demoActiveWorkspaceID,
      let bundleID = state.demoPrimarySlot?.bundleId
    else { return }
    state.draft.mutateWorkspace(workspaceID) { workspace in
      guard let index = workspace.apps.firstIndex(where: { $0.bundleIdentifier == bundleID })
      else { return }
      workspace.apps[index].layout = mode
    }
  }

  private func preferredBorrowWorkspaceID(state: State) -> Workspace.ID? {
    state.scratchpads.first?.id
      ?? state.normalWorkspaces.first(where: { $0.id != state.demoActiveWorkspaceID })?.id
  }

  private func selectStep(_ step: OnboardingStep, state: inout State) {
    state.step = step
    state.demoLastShortcut = nil
    state.demoActionResult = nil
    state.demoBorrowPendingWorkspaceID = nil
    if
      step == .switching || step == .borrow || step == .focusAndCycling,
      state.activeDemoWorkspace?.kind != .normal
    {
      state.demoActiveWorkspaceID = state.normalWorkspaces.first?.id
    }
    if
      step == .tiling || step == .focusAndCycling,
      state.activeDemoApps.count < 2,
      let practiceWorkspace = state.normalWorkspaces.max(by: {
        state.apps(in: $0.id).count < state.apps(in: $1.id).count
      }),
      state.apps(in: practiceWorkspace.id).count >= 2
    {
      state.demoActiveWorkspaceID = practiceWorkspace.id
      state.demoGestureWindowIndex = 0
      syncDemoLayout(state: &state)
    }
    if state.demoBorrowWorkspaceID == state.demoActiveWorkspaceID {
      state.demoBorrowWorkspaceID = preferredBorrowWorkspaceID(state: state)
    }
    if step == .tiling || step == .floating || step == .switching || step == .focusAndCycling {
      syncDemoLayout(state: &state)
    }
    if step == .focusAndCycling {
      syncDemoBorrowLayout(state: &state)
      let block = state.demoBorrowed ? state.demoFocusedBlock : .host
      if let slot = demoSelection(in: block, state: state) {
        state.demoPointerBlock = block
        state.demoPointerLocation = demoPointerTarget(for: slot, in: block, state: state)
      }
    }
  }

  private func setShortcut(
    _ action: HotKeyAction,
    hotKey: HotKey?,
    state: inout State,
  ) -> Bool {
    switch action {
    case .activateWorkspace(let id):
      guard state.draft.workspace(id: id) != nil else { return false }
      state.draft.mutateWorkspace(id) { $0.activateShortcut = hotKey }

    case .assignFocusedAppToWorkspace(let id):
      guard state.draft.workspace(id: id) != nil else { return false }
      state.draft.mutateWorkspace(id) { $0.assignAppShortcut = hotKey }

    case .borrowWorkspace(let id):
      guard state.draft.workspace(id: id) != nil else { return false }
      state.draft.mutateWorkspace(id) { $0.borrowShortcut = hotKey }

    case .focusRight:
      state.draft.settings.shortcuts.focusRight = hotKey

    case .switchToNextWorkspace:
      state.draft.settings.shortcuts.switchToNextWorkspace = hotKey

    case .switchToPreviousWorkspace:
      state.draft.settings.shortcuts.switchToPreviousWorkspace = hotKey

    case .swapRight:
      state.draft.settings.shortcuts.swapRight = hotKey

    case .resizeGrow:
      state.draft.settings.shortcuts.resizeGrow = hotKey

    case .toggleOrientation:
      state.draft.settings.shortcuts.toggleOrientation = hotKey

    case .toggleFullscreen:
      state.draft.settings.shortcuts.toggleFullscreen = hotKey

    case .balance:
      state.draft.settings.shortcuts.balance = hotKey

    case .toggleFloating:
      state.draft.settings.shortcuts.toggleFloating = hotKey

    default:
      return false
    }
    return true
  }

  private func applyDemoShortcut(_ shortcut: HotKeyAction, state: inout State) -> Bool {
    // Labs are cumulative: once a family has been introduced, its real
    // shortcut keeps controlling the same virtual environment in every later
    // step. This lets users build muscle memory instead of losing earlier
    // commands whenever they press Continue.
    if state.step.index >= OnboardingStep.switching.index {
      switch shortcut {
      case .activateWorkspace(let id):
        if state.draft.workspace(id: id)?.kind == .scratchpad {
          guard state.step.index >= OnboardingStep.borrow.index else { return false }
          return beginDemoBorrow(workspaceID: id, state: &state)
        }
        guard activateDemoWorkspace(id, state: &state) else { return false }
        state.practices.insert(.workspaceSwitch)
        return true

      case .switchToNextWorkspace:
        _ = switchDemoWorkspace(offset: 1, state: &state)
        state.practices.insert(.workspaceSwitch)
        return true

      case .switchToPreviousWorkspace:
        _ = switchDemoWorkspace(offset: -1, state: &state)
        state.practices.insert(.workspaceSwitch)
        return true

      case .switchToRecentWorkspace:
        guard
          let recent = state.demoPreviousWorkspaceID,
          activateDemoWorkspace(recent, state: &state)
        else {
          state.demoActionResult = String(localized: "No recent workspace yet")
          return true
        }
        state.practices.insert(.workspaceSwitch)
        return true

      default:
        break
      }
    }

    if
      state.step.index >= OnboardingStep.tiling.index,
      let command = demoTilingCommand(for: shortcut)
    {
      return applyDemoCommand(command, state: &state)
    }

    if state.step.index >= OnboardingStep.borrow.index {
      switch shortcut {
      case .borrowWorkspace(let id):
        return beginDemoBorrow(workspaceID: id, state: &state)

      case .borrowNextWorkspace:
        guard
          let id = adjacentDemoWorkspaceID(offset: 1, state: state),
          beginDemoBorrow(workspaceID: id, state: &state)
        else {
          state.demoActionResult = String(localized: "No eligible next workspace to borrow")
          return true
        }
        return true

      case .borrowPreviousWorkspace:
        guard
          let id = adjacentDemoWorkspaceID(offset: -1, state: state),
          beginDemoBorrow(workspaceID: id, state: &state)
        else {
          state.demoActionResult = String(localized: "No eligible previous workspace to borrow")
          return true
        }
        return true

      case .borrowRecentWorkspace:
        guard
          let id = state.demoPreviousWorkspaceID,
          beginDemoBorrow(workspaceID: id, state: &state)
        else {
          state.demoActionResult = String(localized: "No recent workspace to borrow")
          return true
        }
        return true

      case .dismissBorrow:
        guard state.demoBorrowed else {
          state.demoActionResult = String(localized: "Nothing is borrowed on this display")
          return true
        }
        dismissDemoBorrow(state: &state)
        state.practices.insert(.borrowDismiss)
        state.demoActionResult = String(localized: "Borrow dismissed · host restored")
        return true

      default:
        break
      }
    }

    if
      state.step.index >= OnboardingStep.floating.index,
      shortcut == .toggleFloating,
      state.demoPrimarySlot != nil
    {
      toggleDemoFloating(state: &state)
      return true
    }
    return false
  }

  private func recognizedDemoShortcut(
    _ shortcut: HotKeyAction,
    state: State,
  ) -> HotKeyAction {
    if
      case .activateWorkspace(let id) = shortcut,
      state.step.index >= OnboardingStep.borrow.index,
      state.draft.workspace(id: id)?.kind == .scratchpad
    {
      return .borrowWorkspace(id)
    }
    return shortcut
  }

  private func applyDemoCommand(
    _ command: OnboardingDemoCommand,
    state: inout State,
  ) -> Bool {
    let block = state.demoBorrowed ? state.demoFocusedBlock : .host
    guard let tree = demoTree(for: block, state: state), !tree.windows.isEmpty else {
      return false
    }
    let slots = tree.windows
    let selected = demoSelection(in: block, state: state)
      .flatMap { slots.contains($0) ? $0 : nil } ?? slots[0]
    switch command {
    case .balance:
      setDemoTree(
        tree.balancedForCommand(
          autoBalance: state.draft.settings.layout.autoBalance,
          in: Self.demoWorkArea,
          gap: CGFloat(state.draft.settings.layout.gapInner),
          splitAxis: state.draft.settings.layout.splitType.bspSplitAxis(),
        ),
        in: block,
        state: &state,
      )
      state.practices.insert(.balance)
      state.demoActionResult = String(localized: "Layout Balanced")

    case .cycle(let direction):
      let candidates = cycleCandidates(
        byWindow: state.draft.settings.switching.cycleSameAppWindows,
        focusedBlock: block,
        state: state,
      )
      guard candidates.count > 1 else {
        state.demoActionResult = String(localized: "Cycle needs at least two apps or windows")
        return true
      }
      let currentIndex = candidates.firstIndex(where: {
        $0.block == block
          && (state.draft.settings.switching.cycleSameAppWindows
            ? $0.slot == selected
            : $0.slot.bundleId == selected.bundleId)
      }) ?? -1
      let step = direction == .next ? 1 : -1
      let next = ((currentIndex + step) % candidates.count + candidates.count) % candidates.count
      let target = candidates[next]
      focusDemoWindow(target.slot, in: target.block, state: &state)
      followDemoFocusIfEnabled(state: &state)
      state.practices.insert(.cycle)
      state.demoActionResult = direction == .next
        ? String(localized: "Cycled to the next window")
        : String(localized: "Cycled to the previous window")

    case .focus(let direction):
      guard
        let target = tree.directionalNeighbor(
          of: selected,
          direction: direction,
          in: Self.demoWorkArea,
          gap: CGFloat(state.draft.settings.layout.gapInner),
          focusOrder: slots,
        )
      else {
        if
          let crossBlock = crossDemoBlockFocus(
            from: selected,
            in: block,
            direction: direction,
            state: state,
          )
        {
          focusDemoWindow(crossBlock.slot, in: crossBlock.block, state: &state)
          followDemoFocusIfEnabled(state: &state)
          state.practices.insert(.focus)
          let appName = demoAppName(
            for: crossBlock.slot,
            in: crossBlock.block,
            state: state,
          )
          state.demoActionResult = String(
            localized: "Focused across the Borrow boundary to \(appName)"
          )
          return true
        }
        state.demoActionResult = String(
          localized:
            "No window lies \(String(localized: direction.displayName).lowercased()) of the focused tile"
        )
        return true
      }
      focusDemoWindow(target, in: block, state: &state)
      followDemoFocusIfEnabled(state: &state)
      state.practices.insert(.focus)
      state.demoActionResult = String(
        localized: "Focused the \(String(localized: direction.displayName).lowercased()) neighbour"
      )

    case .fullscreen:
      var fullscreen = demoFullscreenSlots(in: block, state: state)
      let zoomingIn = !fullscreen.contains(selected)
      if zoomingIn {
        fullscreen.insert(selected)
      } else {
        fullscreen.remove(selected)
      }
      setDemoFullscreenSlots(fullscreen, in: block, state: &state)
      state.practices.insert(.fullscreen)
      state.demoActionResult =
        if zoomingIn {
          String(localized: "Zoomed the focused window")
        } else if fullscreen.isEmpty {
          String(localized: "Restored the split tree")
        } else {
          String(localized: "Restored the focused window")
        }

    case .orientation:
      let updated = tree.togglingSplit(at: selected)
      guard updated != tree else {
        state.demoActionResult = String(
          localized: "A single root tile has no parent split to flip"
        )
        return true
      }
      setDemoTree(updated, in: block, state: &state)
      state.practices.insert(.orientation)
      state.demoActionResult = String(localized: "Flipped the focused tile's parent split")

    case .resize(let delta):
      let updated = tree.resizing(window: selected, direction: .east, delta: delta)
      guard updated != tree else {
        state.demoActionResult = String(localized: "No vertical split owns the focused tile")
        return true
      }
      setDemoTree(updated, in: block, state: &state)
      state.practices.insert(.resize)
      state.demoActionResult = delta > 0
        ? String(localized: "Grew the focused window by one step")
        : String(localized: "Shrank the focused window by one step")

    case .swap(let direction):
      let hadNeighbor = tree.directionalNeighbor(
        of: selected,
        direction: direction,
        in: Self.demoWorkArea,
        gap: CGFloat(state.draft.settings.layout.gapInner),
        focusOrder: slots,
      ) != nil
      let updated = tree.applyingDirectionalSwap(
        window: selected,
        direction: direction,
        in: Self.demoWorkArea,
        gap: CGFloat(state.draft.settings.layout.gapInner),
        focusOrder: slots,
      )
      guard updated != tree else {
        state.demoActionResult = tree.windows.count <= 1
          ? String(localized: "A single root tile cannot swap or warp")
          : String(
            localized:
              "No neighbour there · the parent split already points \(String(localized: direction.displayName).lowercased())"
          )
        return true
      }
      setDemoTree(updated, in: block, state: &state)
      setDemoSelection(selected, in: block, state: &state)
      followDemoFocusIfEnabled(state: &state)
      state.practices.insert(.swap)
      state.demoActionResult = hadNeighbor
        ? String(
          localized:
            "Swapped with the \(String(localized: direction.displayName).lowercased()) neighbour"
        )
        : String(
          localized:
            "No neighbour there · warped the parent split \(String(localized: direction.displayName).lowercased())"
        )
    }
    return true
  }

  private func demoTilingCommand(for shortcut: HotKeyAction) -> OnboardingDemoCommand? {
    switch shortcut {
    case .focusLeft: .focus(.west)
    case .focusRight: .focus(.east)
    case .focusUp: .focus(.north)
    case .focusDown: .focus(.south)
    case .cycleNextWindow: .cycle(.next)
    case .cyclePreviousWindow: .cycle(.previous)
    case .swapLeft: .swap(.west)
    case .swapRight: .swap(.east)
    case .swapUp: .swap(.north)
    case .swapDown: .swap(.south)
    case .resizeGrow: .resize(delta: 0.05)
    case .resizeShrink: .resize(delta: -0.05)
    case .toggleOrientation: .orientation
    case .toggleFullscreen: .fullscreen
    case .balance: .balance
    default: nil
    }
  }

  private func cycleCandidates(
    byWindow: Bool,
    focusedBlock: OnboardingDemoBlock,
    state: State,
  ) -> [(block: OnboardingDemoBlock, slot: SlotID)] {
    let blocks: [OnboardingDemoBlock] = state.demoBorrowed
      ? [.host, .borrowed]
      : [focusedBlock]
    let windows = blocks.flatMap { block in
      (demoTree(for: block, state: state)?.windows ?? []).map {
        (block: block, slot: $0)
      }
    }
    guard !byWindow else { return windows }
    var seen = Set<String>()
    let representatives = windows.filter { seen.insert($0.slot.bundleId).inserted }
    return representatives.map { representative in
      guard
        let workspaceID = demoWorkspaceID(for: representative.block, state: state),
        let tree = demoTree(for: representative.block, state: state)
      else { return representative }
      let recent = state.demoWindowMRU[workspaceID] ?? []
      let slot = recent.first(where: {
        $0.bundleId == representative.slot.bundleId && tree.windows.contains($0)
      }) ?? representative.slot
      return (block: representative.block, slot: slot)
    }
  }

  private func crossDemoBlockFocus(
    from slot: SlotID,
    in block: OnboardingDemoBlock,
    direction: BSPDirection,
    state: State,
  ) -> (block: OnboardingDemoBlock, slot: SlotID)? {
    guard state.demoBorrowed else { return nil }
    let directionEdge: BorrowEdge =
      switch direction {
      case .east: .right
      case .west: .left
      case .north: .top
      case .south: .bottom
      }
    let targetBlock: OnboardingDemoBlock
    switch block {
    case .host:
      guard directionEdge == state.demoEffectiveBorrowEdge else { return nil }
      targetBlock = .borrowed

    case .borrowed:
      guard directionEdge == state.demoEffectiveBorrowEdge.opposite else { return nil }
      targetBlock = .host
    }
    guard
      let sourceTree = demoTree(for: block, state: state),
      let targetTree = demoTree(for: targetBlock, state: state),
      !targetTree.windows.isEmpty
    else { return nil }

    let frames = demoBorrowedFrames(state: state)
    let sourceRect = block == .host ? frames.host : frames.visitor
    let targetRect = targetBlock == .host ? frames.host : frames.visitor
    let gap = CGFloat(state.draft.settings.layout.gapInner)
    let sourceCenter = sourceTree.frames(in: sourceRect, gap: gap)[slot]
      .map { CGPoint(x: $0.midX, y: $0.midY) }
      ?? CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let target = targetTree.frames(in: targetRect, gap: gap).min {
      hypot($0.value.midX - sourceCenter.x, $0.value.midY - sourceCenter.y)
        < hypot($1.value.midX - sourceCenter.x, $1.value.midY - sourceCenter.y)
    }?.key
    return target.map { (targetBlock, $0) }
  }

  private func demoBorrowedFrames(
    state: State
  ) -> (host: CGRect, visitor: CGRect) {
    let bounds = Self.demoWorkArea
    let gap = CGFloat(state.draft.settings.layout.gapInner)
    let fraction = CGFloat(min(0.7, max(0.3, state.demoEffectiveBorrowFraction)))
    switch state.demoEffectiveBorrowEdge {
    case .left:
      let visitorWidth = (bounds.width - gap) * fraction
      return (
        CGRect(
          x: bounds.minX + visitorWidth + gap,
          y: bounds.minY,
          width: bounds.width - visitorWidth - gap,
          height: bounds.height,
        ),
        CGRect(x: bounds.minX, y: bounds.minY, width: visitorWidth, height: bounds.height),
      )

    case .right:
      let visitorWidth = (bounds.width - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width - visitorWidth - gap,
          height: bounds.height,
        ),
        CGRect(
          x: bounds.maxX - visitorWidth,
          y: bounds.minY,
          width: visitorWidth,
          height: bounds.height,
        ),
      )

    case .top:
      let visitorHeight = (bounds.height - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY + visitorHeight + gap,
          width: bounds.width,
          height: bounds.height - visitorHeight - gap,
        ),
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: visitorHeight),
      )

    case .bottom:
      let visitorHeight = (bounds.height - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width,
          height: bounds.height - visitorHeight - gap,
        ),
        CGRect(
          x: bounds.minX,
          y: bounds.maxY - visitorHeight,
          width: bounds.width,
          height: visitorHeight,
        ),
      )
    }
  }

  private func cycleGestureWindow(offset: Int, state: inout State) {
    // The switching monitor always renders three practice windows. Cycle that
    // exact visible set, including floating/unmanaged assignments that are not
    // leaves in the tiling BSP tree.
    let count = max(state.gestureDemoApps.count, 3)
    let current = state.demoGestureWindowIndex.clamped(to: 0 ... max(count - 1, 0))
    state.demoGestureWindowIndex = (current + offset + count) % count
    state.demoActionResult = offset > 0
      ? String(localized: "Cycled to the next window")
      : String(localized: "Cycled to the previous window")
  }

  private func beginDemoBorrow(
    workspaceID: Workspace.ID,
    state: inout State,
  ) -> Bool {
    guard
      let workspace = state.activeWorkspaces.first(where: { $0.id == workspaceID }),
      workspaceID != state.demoActiveWorkspaceID
    else { return false }

    let repeatsActiveBorrow = state.demoBorrowed && state.demoBorrowWorkspaceID == workspaceID
    if !state.demoBorrowed || repeatsActiveBorrow {
      state.demoBorrowWorkspaceID = workspaceID
    }
    if
      repeatsActiveBorrow,
      state.draft.settings.switching.toggleBorrowOnRepeat
    {
      dismissDemoBorrow(state: &state)
      state.practices.insert(.borrowDismiss)
      state.demoActionResult = String(localized: "Repeated summon dismissed \(workspace.name)")
      return true
    }

    if let edge = workspace.borrowEdge ?? state.draft.settings.switching.borrowDefaultEdge {
      performDemoBorrow(workspaceID: workspaceID, edge: edge, state: &state)
    } else {
      state.demoBorrowPendingWorkspaceID = workspaceID
      state.demoActionResult = String(localized: "Choose where \(workspace.name) should dock")
    }
    return true
  }

  private func performDemoBorrow(
    workspaceID: Workspace.ID,
    edge: BorrowEdge,
    state: inout State,
  ) {
    guard let workspace = state.activeWorkspaces.first(where: { $0.id == workspaceID }) else {
      return
    }
    state.demoBorrowWorkspaceID = workspaceID
    state.demoBorrowPendingWorkspaceID = nil
    state.demoBorrowEdge = edge
    state.demoBorrowed = true
    syncDemoBorrowLayout(state: &state)
    if
      let tree = state.demoBorrowLayoutTree,
      let selected = (state.demoWindowMRU[workspaceID] ?? [])
        .first(where: { tree.windows.contains($0) }) ?? state.demoBorrowSelectedSlot
    {
      focusDemoWindow(selected, in: .borrowed, state: &state)
      followDemoFocusIfEnabled(state: &state)
      if !state.draft.settings.focus.mouseFollowsFocus {
        state.demoPointerBlock = .host
      }
    }
    state.practices.insert(.borrow)
    state.demoActionResult = String(
      localized: "Borrowed \(workspace.name) on the \(String(localized: edge.displayName))"
    )
  }

  private func dismissDemoBorrow(state: inout State) {
    state.demoBorrowed = false
    state.demoBorrowEdge = nil
    state.demoBorrowPendingWorkspaceID = nil
    state.demoFocusedBlock = .host
    if state.draft.settings.focus.mouseFollowsFocus {
      followDemoFocusIfEnabled(state: &state)
    } else if state.demoPointerBlock == .borrowed {
      state.demoPointerBlock = .host
      state.demoPointerLocation = nil
    }
  }

  private func toggleDemoFloating(state: inout State) {
    guard
      let workspaceID = state.demoActiveWorkspaceID,
      let slot = state.demoPrimarySlot,
      let app = state.demoAppBySlot[slot]
    else { return }
    let nowFloating = state.draft.toggleFloating(
      bundleId: slot.bundleId,
      name: app.name,
      in: workspaceID,
    )
    state.demoLayoutMode = nowFloating ? .floating : .tiled
    state.practices.insert(nowFloating ? .floating : .tiledHandling)
    state.demoActionResult = nowFloating
      ? String(localized: "Floating \(app.name) above the split tree")
      : String(localized: "Returned \(app.name) to the split tree")
  }

  private func assignApp(
    _ bundleID: String,
    to destination: OnboardingAppDestination,
    state: inout State,
  ) -> Bool {
    guard let app = state.allKnownApps.first(where: { $0.bundleIdentifier == bundleID }) else {
      return false
    }
    if case .workspace(let id) = destination, state.draft.workspace(id: id) == nil {
      return false
    }
    let existingAssignment = state.draft.profiles
      .flatMap(\.workspaces)
      .flatMap(\.apps)
      .first { $0.bundleIdentifier == bundleID }
    let existingShared = state.draft.sharedApps.first { $0.bundleIdentifier == bundleID }
    for profileIndex in state.draft.profiles.indices {
      for workspaceID in state.draft.profiles[profileIndex].workspaces.ids {
        state.draft.profiles[profileIndex].workspaces[id: workspaceID]?.apps
          .removeAll { $0.bundleIdentifier == bundleID }
      }
    }
    state.draft.sharedApps.removeAll { $0.bundleIdentifier == bundleID }
    switch destination {
    case .unassigned:
      break
    case .shared:
      state.draft.sharedApps.append(existingShared ?? SharedApp(app))
    case .workspace(let id):
      state.draft.mutateWorkspace(id) { workspace in
        workspace.apps.append(existingAssignment ?? AppAssignment(app))
      }
    }
    return true
  }

  private func activateDemoWorkspace(
    _ workspaceID: Workspace.ID,
    state: inout State,
  ) -> Bool {
    guard state.normalWorkspaces.contains(where: { $0.id == workspaceID }) else { return false }
    if state.demoActiveWorkspaceID != workspaceID {
      state.demoPreviousWorkspaceID = state.demoActiveWorkspaceID
    }
    state.demoActiveWorkspaceID = workspaceID
    state.demoGestureWindowIndex = 0
    state.demoActionResult = String(localized: "Activated \(state.workspaceName(workspaceID))")
    syncDemoLayout(state: &state)
    state.demoFocusedBlock = .host
    if let selected = state.demoSelectedSlot {
      focusDemoWindow(selected, in: .host, state: &state)
    }
    followDemoFocusIfEnabled(state: &state)
    return true
  }

  private func followDemoFocusIfEnabled(state: inout State) {
    let block = state.demoBorrowed ? state.demoFocusedBlock : .host
    guard
      state.step.index >= OnboardingStep.focusAndCycling.index,
      state.draft.settings.focus.mouseFollowsFocus,
      let selected = demoSelection(in: block, state: state),
      let target = demoPointerTarget(for: selected, in: block, state: state)
    else { return }
    state.demoPointerBlock = block
    state.demoPointerLocation = target
    state.practices.insert(.mouseFollowsFocus)
  }

  private func demoPointerTarget(
    for slot: SlotID,
    in block: OnboardingDemoBlock,
    state: State,
  ) -> OnboardingDemoPoint? {
    guard let tree = demoTree(for: block, state: state) else { return nil }
    let fullscreen = demoFullscreenSlots(in: block, state: state)
    if fullscreen.contains(slot) {
      return OnboardingDemoPoint(x: 0.5, y: 0.5)
    }
    if block == .host, state.demoPrimarySlot == slot {
      switch state.demoLayoutMode {
      case .floating:
        return OnboardingDemoPoint(x: 0.81, y: 0.25)
      case .unmanaged:
        return OnboardingDemoPoint(x: 0.5, y: 0.9)
      case .tiled:
        break
      }
    }

    let outerGap = CGFloat(state.draft.settings.layout.gapOuter)
    let contentBounds = Self.demoWorkArea.insetBy(dx: outerGap, dy: outerGap)
    let baseTree =
      if
        block == .host,
        let primarySlot = state.demoPrimarySlot,
        state.demoLayoutMode != .tiled
      {
        tree.removing(primarySlot)
      } else {
        tree
      }
    let layoutTree = baseTree?.removingAll(fullscreen)
    guard
      let region = layoutTree?.leafRegions(
        in: contentBounds,
        gap: CGFloat(state.draft.settings.layout.gapInner),
      )
      .first(where: { $0.leaf.topWindow == slot })
    else { return nil }
    return OnboardingDemoPoint(
      x: region.rect.midX / Self.demoWorkArea.width,
      y: region.rect.midY / Self.demoWorkArea.height,
    )
  }

  private func adjacentDemoWorkspaceID(
    offset: Int,
    state: State,
  ) -> Workspace.ID? {
    let workspaces = state.normalWorkspaces
    guard !workspaces.isEmpty else { return nil }
    let current = state.demoActiveWorkspaceID
      .flatMap { id in workspaces.firstIndex(where: { $0.id == id }) }
      ?? -1
    let runningBundleIDs = Set(state.runningApps.map(\.bundleIdentifier))
    var index = current
    for _ in 0 ..< workspaces.count {
      let proposed = index + offset
      if state.draft.settings.switching.loop {
        index = (proposed + workspaces.count) % workspaces.count
      } else {
        guard proposed >= 0, proposed < workspaces.count else { return nil }
        index = proposed
      }
      let candidate = workspaces[index]
      if state.draft.settings.switching.skipEmpty {
        let hasRunningApp = candidate.apps.contains {
          runningBundleIDs.contains($0.bundleIdentifier)
        }
        if !hasRunningApp { continue }
      }
      return candidate.id
    }
    return nil
  }

  @discardableResult
  private func switchDemoWorkspace(offset: Int, state: inout State) -> Bool {
    guard let next = adjacentDemoWorkspaceID(offset: offset, state: state) else {
      state.demoActionResult = offset > 0
        ? String(localized: "No eligible next workspace")
        : String(localized: "No eligible previous workspace")
      return false
    }
    return activateDemoWorkspace(next, state: &state)
  }

}

extension BSPDirection {
  fileprivate var displayName: LocalizedStringResource {
    switch self {
    case .west: "Left"
    case .east: "Right"
    case .north: "Up"
    case .south: "Down"
    }
  }
}

extension OnboardingStep {
  public var index: Int {
    Self.allCases.firstIndex(of: self) ?? 0
  }

  public var next: Self? {
    let nextIndex = index + 1
    return Self.allCases.indices.contains(nextIndex) ? Self.allCases[nextIndex] : nil
  }

  public var previous: Self? {
    let previousIndex = index - 1
    return Self.allCases.indices.contains(previousIndex) ? Self.allCases[previousIndex] : nil
  }
}
