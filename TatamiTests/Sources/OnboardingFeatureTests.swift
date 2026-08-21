// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct OnboardingFeatureTests {
  @Test
  func `focus and cycling is the cumulative step after floating`() {
    #expect(OnboardingStep.allCases == [
      .welcome,
      .environment,
      .workspaces,
      .switching,
      .tiling,
      .borrow,
      .floating,
      .focusAndCycling,
      .finish,
    ])
    #expect(OnboardingStep.floating.next == .focusAndCycling)
    #expect(OnboardingStep.focusAndCycling.previous == .floating)
    #expect(OnboardingStep.focusAndCycling.next == .finish)
  }

  @Test
  func `setup validation rejects duplicate workspace keys`() {
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [
      Profile(name: "Default", workspaces: [
        Workspace(name: "Focus", keyEquivalent: "f"),
        Workspace(name: "Fallback", keyEquivalent: "f"),
      ])
    ])

    #expect(!state.canApply)
    #expect(state.validationMessage == "Workspace keys must be unique.")
  }

  @Test
  func `fresh install builds A starter setup from this mac and presents it`() async throws {
    let apps = [
      MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"),
      MacApp(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack"),
      MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari"),
    ]
    let display = DisplayName("Studio Display")
    let store = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.accessibility.isTrusted = { true }
      $0.displays.all = { [display] }
      $0.onboardingProgress.consumeResumeAfterRelaunch = { false }
      $0.onboardingProgress.hasCompleted = { false }
      $0.onboardingProgress.load = { nil }
      $0.onboardingProgress.save = { _ in }
      $0.runningApps.current = { apps }
      $0.screenRecording.isGranted = { true }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    let persistedFreshConfig = AppConfig(settings: AppSettings(shortcuts: .recommended))
    await store.send(.appStarted(config: persistedFreshConfig, hasExistingConfig: false))
    await store.receive(\.preparationResponse)

    #expect(store.state.isPresented)
    #expect(store.state.presentationRequest == 1)
    #expect(store.state.normalWorkspaces.map(\.name) == ["Primary", "Secondary"])
    #expect(store.state.normalWorkspaces.compactMap(\.keyEquivalent) == ["1", "2"])
    #expect(store.state.normalWorkspaces.allSatisfy { $0.displayHint == display })
    #expect(!store.state.hasCustomizedWorkspaceMap)
    #expect(apps.allSatisfy { store.state.destination(for: $0.bundleIdentifier) == .unassigned })
    #expect(store.state.draft.settings.general.launchAtLogin)
    #expect(!store.state.draft.settings.focus.focusFollowsMouse)
    #expect(!store.state.draft.settings.gestures.enabled)
    #expect(store.state.draft.settings.gestures.threeFinger.right == .cycleNextWindow)
    #expect(store.state.draft.settings.gestures.fourFinger.left == .nextWorkspace)
    #expect(store.state.draft.settings.switching.borrowDefaultEdge == nil)
    #expect(store.state.draft.settings.shortcuts.focusRight?.symbols == "⌃⌥L")
    #expect(store.state.draft.settings.shortcuts.swapRight?.symbols == "⌃⌥→")
    #expect(store.state.draft.settings.shortcuts.toggleFullscreen?.symbols == "⌃⌥↩")
    #expect(store.state.draft.settings.shortcuts.toggleFloating?.symbols == "⌥⌘↩")
    #expect(store.state.draft.settings.shortcuts.balance?.symbols == "⌃⌥E")
    #expect(store.state.draft.settings.shortcuts.keyEquivalentModifiers == ["ctrl", "alt", "shift"])
    #expect(store.state.draft.settings.shortcuts.assignModifiers == ["alt", "shift", "cmd"])
    #expect(store.state.draft.settings.shortcuts.recentWorkspaceKey == "\\")
    #expect(store.state.draft.settings.shortcuts.nextWorkspaceKey == ".")
    #expect(store.state.draft.settings.shortcuts.previousWorkspaceKey == ",")

    let firstWorkspace = try #require(
      store.state.normalWorkspaces.first,
      "Expected the fresh draft to contain a starter workspace",
    )
    await store.send(.workspaceNameChanged(firstWorkspace.id, "Build"))
    #expect(store.state.hasCustomizedWorkspaceMap)
  }

  @Test
  func `completed or existing setup does not interrupt launch`() async {
    let existing = AppConfig(profiles: [
      Profile(name: "Default", workspaces: [Workspace(name: "Focus")])
    ])
    let existingStore = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.consumeResumeAfterRelaunch = { false }
    }
    existingStore.exhaustivity = .off

    await existingStore.send(.appStarted(config: existing, hasExistingConfig: true))
    #expect(existingStore.state.presentationRequest == 0)

    let completedStore = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.consumeResumeAfterRelaunch = { false }
      $0.onboardingProgress.hasCompleted = { true }
    }
    completedStore.exhaustivity = .off

    await completedStore.send(.appStarted(config: AppConfig(), hasExistingConfig: false))
    await completedStore.finish()
    #expect(completedStore.state.presentationRequest == 0)
  }

  @Test
  func `onboarding relaunch resumes the guide after an existing config launch`() async {
    let calls = LockIsolated<[String]>([])
    let relaunchStore = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.accessibility.relaunch = {
        calls.withValue { $0.append("relaunch") }
      }
      $0.onboardingProgress.requestResumeAfterRelaunch = {
        calls.withValue { $0.append("resume") }
      }
    }
    relaunchStore.exhaustivity = .off

    await relaunchStore.send(.relaunchButtonTapped)
    await relaunchStore.finish()
    #expect(calls.value == ["resume", "relaunch"])

    let existing = AppConfig(profiles: [
      Profile(name: "Default", workspaces: [Workspace(name: "Focus")])
    ])
    let launchStore = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.consumeResumeAfterRelaunch = { true }
      $0.onboardingProgress.load = { nil }
      $0.onboardingProgress.save = { _ in }
      $0.screenRecording.isGranted = { false }
    }
    launchStore.exhaustivity = .off

    await launchStore.send(.appStarted(config: existing, hasExistingConfig: true))
    await launchStore.receive(\.preparationResponse)

    #expect(launchStore.state.isPresented)
    #expect(launchStore.state.presentationRequest == 1)
    #expect(launchStore.state.mode == .review)
  }

  @Test
  func `screen recording grant preserves the guide before macOS can restart the app`() async {
    let calls = LockIsolated<[String]>([])
    let store = TestStore(initialState: OnboardingFeature.State()) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.requestResumeAfterRelaunch = {
        calls.withValue { $0.append("resume") }
      }
      $0.screenRecording.requestAccess = {
        calls.withValue { $0.append("request") }
      }
      $0.screenRecording.openSettings = {
        calls.withValue { $0.append("settings") }
      }
    }
    store.exhaustivity = .off

    await store.send(.grantScreenRecordingButtonTapped)
    await store.finish()

    #expect(calls.value == ["resume", "request", "settings"])
  }

  @Test
  func `successful apply commits the baseline and requests one window dismissal`() async {
    let workspace = Workspace(name: "Applied")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    let completions = LockIsolated(0)
    var state = OnboardingFeature.State()
    state.draft = draft
    state.dismissalRequest = 2
    state.isApplying = true
    state.isPresented = true
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.complete = {
        completions.withValue { $0 += 1 }
      }
    }

    await store.send(.configurationApplied) {
      $0.baseline = draft
      $0.dismissalRequest = 3
      $0.isApplying = false
      $0.isPresented = false
    }
    await store.finish()

    #expect(completions.value == 1)
  }

  @Test
  func `editing an app destination only changes the draft`() async {
    let workspace = Workspace(name: "Focus")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let config = AppConfig(profiles: [profile], activeProfileId: profile.id)
    let app = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    var initialState = OnboardingFeature.State()
    initialState.baseline = config
    initialState.draft = config
    initialState.runningApps = [app]
    initialState.demoActiveWorkspaceID = workspace.id
    initialState.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [app.bundleIdentifier]
    )
    let store = TestStore(initialState: initialState) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.appDestinationChanged(app.bundleIdentifier, .workspace(workspace.id)))

    #expect(store.state.baseline == config)
    #expect(store.state.baseline.workspace(id: workspace.id)?.apps.isEmpty == true)
    #expect(store.state.draft.workspace(id: workspace.id)?.apps.map(\.bundleIdentifier) == [app.bundleIdentifier])

    await store.send(.demoLayoutModeChanged(.unmanaged))

    #expect(store.state.baseline.workspace(id: workspace.id)?.apps.isEmpty == true)
    #expect(store.state.draft.workspace(id: workspace.id)?.apps.first?.layout == .unmanaged)
  }

  @Test
  func `switching preview teaches window and workspace gestures independently`() async {
    let focus = Workspace(name: "Focus")
    let browse = Workspace(name: "Browse")
    let profile = Profile(name: "Default", workspaces: [focus, browse])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.gestures = AppSettings.Gestures(
      enabled: true,
      threeFinger: .init(
        left: .cyclePreviousWindow,
        right: .cycleNextWindow,
      ),
      fourFinger: .workspaceSwitch,
    )
    state.demoActiveWorkspaceID = focus.id
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoWorkspaceTapped(browse.id))
    #expect(store.state.demoActiveWorkspaceID == browse.id)

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 4, direction: .left)))
    #expect(store.state.demoActiveWorkspaceID == focus.id)
    #expect(store.state.demoLastGesture?.direction == .left)
    #expect(store.state.practices.contains(.gesture))
    #expect(store.state.practices.contains(.workspaceGesture))
    #expect(store.state.practices.contains(.workspaceSwitch))

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 3, direction: .right)))
    #expect(store.state.demoActiveWorkspaceID == focus.id)
    #expect(store.state.demoGestureWindowIndex == 1)
    #expect(store.state.practices.contains(.windowGesture))
  }

  @Test
  func `switching preview follows loop skip empty recent and scratchpad rules`() async {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let terminal = MacApp(bundleIdentifier: "terminal", name: "Terminal")
    let focus = Workspace(name: "Focus", apps: [AppAssignment(editor)])
    let empty = Workspace(name: "Empty")
    let browse = Workspace(name: "Browse", apps: [AppAssignment(browser)])
    let scratchpad = Workspace(
      name: "Terminal",
      kind: .scratchpad,
      apps: [AppAssignment(terminal)],
    )
    let profile = Profile(name: "Default", workspaces: [focus, empty, browse, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.switching.skipEmpty = true
    state.demoActiveWorkspaceID = focus.id
    state.runningApps = [editor, browser, terminal]
    state.step = .switching
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoShortcutPerformed(.switchToNextWorkspace))
    #expect(store.state.demoActiveWorkspaceID == browse.id)
    #expect(store.state.demoPreviousWorkspaceID == focus.id)

    await store.send(.demoShortcutPerformed(.switchToRecentWorkspace))
    #expect(store.state.demoActiveWorkspaceID == focus.id)
    #expect(store.state.demoPreviousWorkspaceID == browse.id)

    await store.send(.demoShortcutPerformed(.activateWorkspace(browse.id)))
    await store.send(.binding(.set(\.draft.settings.switching.loop, false)))
    await store.send(.demoShortcutPerformed(.switchToNextWorkspace))
    #expect(store.state.demoActiveWorkspaceID == browse.id)
    #expect(store.state.demoActionResult == "No eligible next workspace")
  }

  @Test
  func `switching shortcuts can be overridden and drive the workspace cycle`() async throws {
    let focus = Workspace(name: "Focus")
    let browse = Workspace(name: "Browse")
    let profile = Profile(name: "Default", workspaces: [focus, browse])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.demoActiveWorkspaceID = focus.id
    state.step = .switching
    let next = try #require(HotKey(parsing: "ctrl + alt - ]"))
    let previous = try #require(HotKey(parsing: "ctrl + alt - ["))
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.shortcutChanged(.switchToNextWorkspace, next))
    await store.send(.shortcutChanged(.switchToPreviousWorkspace, previous))
    #expect(store.state.draft.settings.shortcuts.switchToNextWorkspace == next)
    #expect(store.state.draft.settings.shortcuts.switchToPreviousWorkspace == previous)

    await store.send(.demoShortcutPerformed(.switchToNextWorkspace))
    #expect(store.state.demoActiveWorkspaceID == browse.id)
    #expect(store.state.demoLastShortcut == .switchToNextWorkspace)

    await store.send(.demoShortcutPerformed(.switchToPreviousWorkspace))
    #expect(store.state.demoActiveWorkspaceID == focus.id)
    #expect(store.state.demoLastShortcut == .switchToPreviousWorkspace)
  }

  @Test
  func `scratchpad workspace shortcut borrows instead of being discarded`() async {
    let host = Workspace(name: "Build")
    let scratchpad = Workspace(
      name: "Team Chat",
      kind: .scratchpad,
      borrowEdge: .right,
    )
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.demoActiveWorkspaceID = host.id
    state.demoBorrowWorkspaceID = scratchpad.id
    state.step = .borrow
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoShortcutPerformed(.activateWorkspace(scratchpad.id)))

    #expect(store.state.demoBorrowed)
    #expect(store.state.demoBorrowWorkspaceID == scratchpad.id)
    #expect(store.state.demoBorrowEdge == .right)
    #expect(store.state.demoLastShortcut == .borrowWorkspace(scratchpad.id))
  }

  @Test
  func `window gesture cycles every window rendered in the switching monitor`() async {
    let simulator = MacApp(bundleIdentifier: "simulator", name: "Simulator")
    let xcode = MacApp(bundleIdentifier: "xcode", name: "Xcode")
    let messages = MacApp(bundleIdentifier: "messages", name: "Messages")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(simulator),
      AppAssignment(xcode),
      AppAssignment(messages, layout: .unmanaged),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.gestures = AppSettings.Gestures(
      enabled: true,
      threeFinger: .init(
        left: .cyclePreviousWindow,
        right: .cycleNextWindow,
      ),
      fourFinger: .workspaceSwitch,
    )
    state.runningApps = [simulator, xcode, messages]
    state.demoActiveWorkspaceID = workspace.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [simulator.bundleIdentifier, xcode.bundleIdentifier]
    )
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 3, direction: .right)))
    #expect(store.state.demoGestureWindowIndex == 1)

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 3, direction: .right)))
    #expect(store.state.demoGestureWindowIndex == 2)
    #expect(Set(store.state.gestureDemoApps.map(\.name)) == ["Simulator", "Xcode", "Messages"])

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 3, direction: .right)))
    #expect(store.state.demoGestureWindowIndex == 0)
  }

  @Test
  func `window gesture controls the shared layout in the cumulative lab`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(editor),
      AppAssignment(browser),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.gestures = AppSettings.Gestures(
      enabled: true,
      threeFinger: .init(
        left: .cyclePreviousWindow,
        right: .cycleNextWindow,
      ),
      fourFinger: .workspaceSwitch,
    )
    state.runningApps = [editor, browser]
    state.demoActiveWorkspaceID = workspace.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier, browser.bundleIdentifier]
    )
    state.demoSelectedSlot = state.demoLayoutTree?.windows.first
    state.step = .focusAndCycling
    let expected = try #require(state.demoLayoutTree?.windows.last)
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoGesturePerformed(TrackpadGesture(fingerCount: 3, direction: .right)))

    #expect(store.state.demoSelectedSlot == expected)
    #expect(store.state.demoGestureWindowIndex == 0)
    #expect(store.state.practices.contains(.cycle))
    #expect(store.state.practices.contains(.windowGesture))
  }

  @Test
  func `MFF and FFM share focus state with the cumulative layout`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(editor),
      AppAssignment(browser),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.focus.mouseFollowsFocus = true
    state.draft.settings.focus.focusFollowsMouse = true
    state.runningApps = [editor, browser]
    state.demoActiveWorkspaceID = workspace.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier, browser.bundleIdentifier]
    )
    let slots = try #require(state.demoLayoutTree?.windows)
    state.demoSelectedSlot = slots[0]
    state.demoPointerLocation = OnboardingDemoPoint(x: 0.1, y: 0.1)
    state.step = .focusAndCycling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoCommandTapped(.cycle(.next)))

    #expect(store.state.demoSelectedSlot == slots[1])
    #expect(store.state.demoPointerLocation != OnboardingDemoPoint(x: 0.1, y: 0.1))
    #expect(store.state.practices.contains(.mouseFollowsFocus))

    let hoverPoint = OnboardingDemoPoint(x: 0.25, y: 0.5)
    await store.send(.demoPointerHovered(.host, slots[0], hoverPoint))

    #expect(store.state.demoSelectedSlot == slots[0])
    #expect(store.state.demoPointerLocation == hoverPoint)
    #expect(store.state.practices.contains(.focusFollowsMouse))
  }

  @Test
  func `fullscreen set remains attached and supports multiple windows`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(editor),
      AppAssignment(browser),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.runningApps = [editor, browser]
    state.demoActiveWorkspaceID = workspace.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier, browser.bundleIdentifier]
    )
    let tree = try #require(state.demoLayoutTree)
    let zoomed = try #require(tree.windows.first)
    let focused = try #require(
      tree.directionalNeighbor(
        of: zoomed,
        direction: .east,
        in: CGRect(x: 0, y: 0, width: 1200, height: 720),
        gap: CGFloat(state.draft.settings.layout.gapInner),
        focusOrder: tree.windows,
      )
    )
    state.demoSelectedSlot = zoomed
    state.step = .focusAndCycling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoCommandTapped(.fullscreen))
    #expect(store.state.demoFullscreenSlots == [zoomed])

    await store.send(.demoCommandTapped(.focus(.east)))
    #expect(store.state.demoSelectedSlot == focused)
    #expect(store.state.demoFullscreenSlots == [zoomed])

    await store.send(.demoCommandTapped(.fullscreen))
    #expect(store.state.demoFullscreenSlots == [zoomed, focused])

    await store.send(.demoTileTapped(.host, zoomed))
    await store.send(.demoCommandTapped(.fullscreen))
    #expect(store.state.demoFullscreenSlots == [focused])
  }

  @Test
  func `onboarding progress preserves fullscreen sets and restores legacy snapshots`() throws {
    let workspace = Workspace(name: "Build")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let config = AppConfig(profiles: [profile], activeProfileId: profile.id)
    let first = SlotID(bundleId: "editor", occurrence: 0)
    let second = SlotID(bundleId: "browser", occurrence: 0)
    let tree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [first.bundleId, second.bundleId]
    )
    var progress = OnboardingProgress(
      baseline: OnboardingConfigSnapshot(config),
      demoActiveWorkspaceID: workspace.id,
      demoBorrowed: false,
      demoFullscreenZoomed: [workspace.id: [first, second]],
      demoLayoutMode: .tiled,
      demoLayoutTree: tree,
      draft: OnboardingConfigSnapshot(config),
      furthestStepIndex: 4,
      contextStyle: .focused,
      practices: [.fullscreen],
      prefersScratchpads: true,
      recurringWork: "",
      roleDescription: "",
      step: .tiling,
    )

    let current = try JSONDecoder().decode(
      OnboardingProgress.self,
      from: JSONEncoder().encode(progress),
    )
    #expect(current.restoredDemoFullscreenZoomed == [workspace.id: [first, second]])

    progress.demoFullscreenZoomed = nil
    progress.demoFullscreenSlot = first
    let legacy = try JSONDecoder().decode(
      OnboardingProgress.self,
      from: JSONEncoder().encode(progress),
    )
    #expect(legacy.restoredDemoFullscreenZoomed == [workspace.id: [first]])
  }

  @Test
  func `borrow focuses its MRU window and MFF follows into the borrowed block`() async {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let chat = MacApp(bundleIdentifier: "chat", name: "Chat")
    let host = Workspace(name: "Build", apps: [AppAssignment(editor)])
    let scratchpad = Workspace(
      name: "Team Chat",
      kind: .scratchpad,
      borrowEdge: .right,
      apps: [AppAssignment(chat)],
    )
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.focus.mouseFollowsFocus = true
    state.runningApps = [editor, chat]
    state.demoActiveWorkspaceID = host.id
    state.demoBorrowWorkspaceID = scratchpad.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier]
    )
    state.demoSelectedSlot = state.demoLayoutTree?.windows.first
    state.step = .focusAndCycling
    let expected = SlotID(bundleId: chat.bundleIdentifier, occurrence: 0)
    state.demoWindowMRU[scratchpad.id] = [expected]
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoShortcutPerformed(.borrowWorkspace(scratchpad.id)))

    #expect(store.state.demoBorrowed)
    #expect(store.state.demoFocusedBlock == .borrowed)
    #expect(store.state.demoBorrowSelectedSlot == expected)
    #expect(store.state.demoPointerBlock == .borrowed)
    #expect(store.state.demoPointerLocation != nil)
    #expect(store.state.demoWindowMRU[scratchpad.id]?.first == expected)
    #expect(store.state.practices.contains(.mouseFollowsFocus))
  }

  @Test
  func `cycling crosses between the host and borrowed block`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let chat = MacApp(bundleIdentifier: "chat", name: "Chat")
    let host = Workspace(name: "Build", apps: [AppAssignment(editor)])
    let scratchpad = Workspace(
      name: "Team Chat",
      kind: .scratchpad,
      borrowEdge: .right,
      apps: [AppAssignment(chat)],
    )
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.runningApps = [editor, chat]
    state.demoActiveWorkspaceID = host.id
    state.demoBorrowWorkspaceID = scratchpad.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier]
    )
    let hostSlot = try #require(state.demoLayoutTree?.windows.first)
    state.demoSelectedSlot = hostSlot
    state.demoBorrowed = true
    state.demoBorrowEdge = .right
    state.demoBorrowLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [chat.bundleIdentifier]
    )
    let borrowedSlot = try #require(state.demoBorrowLayoutTree?.windows.first)
    state.demoBorrowSelectedSlot = borrowedSlot
    state.demoFocusedBlock = .host
    state.step = .focusAndCycling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoCommandTapped(.cycle(.next)))
    #expect(store.state.demoFocusedBlock == .borrowed)
    #expect(store.state.demoBorrowSelectedSlot == borrowedSlot)

    await store.send(.demoCommandTapped(.cycle(.next)))
    #expect(store.state.demoFocusedBlock == .host)
    #expect(store.state.demoSelectedSlot == hostSlot)
  }

  @Test
  func `FFM and directional focus cross the host Borrow boundary`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let chat = MacApp(bundleIdentifier: "chat", name: "Chat")
    let host = Workspace(name: "Build", apps: [AppAssignment(editor)])
    let scratchpad = Workspace(
      name: "Team Chat",
      kind: .scratchpad,
      borrowEdge: .right,
      apps: [AppAssignment(chat)],
    )
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.focus.mouseFollowsFocus = true
    state.draft.settings.focus.focusFollowsMouse = true
    state.runningApps = [editor, chat]
    state.demoActiveWorkspaceID = host.id
    state.demoBorrowWorkspaceID = scratchpad.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier]
    )
    let hostSlot = try #require(state.demoLayoutTree?.windows.first)
    state.demoSelectedSlot = hostSlot
    state.demoBorrowed = true
    state.demoBorrowEdge = .right
    state.demoBorrowLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [chat.bundleIdentifier]
    )
    let borrowedSlot = try #require(state.demoBorrowLayoutTree?.windows.first)
    state.demoBorrowSelectedSlot = borrowedSlot
    state.demoFocusedBlock = .host
    state.step = .focusAndCycling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoCommandTapped(.focus(.east)))

    #expect(store.state.demoFocusedBlock == .borrowed)
    #expect(store.state.demoBorrowSelectedSlot == borrowedSlot)
    #expect(store.state.demoPointerBlock == .borrowed)

    let hostPoint = OnboardingDemoPoint(x: 0.4, y: 0.5)
    await store.send(.demoPointerHovered(.host, hostSlot, hostPoint))

    #expect(store.state.demoFocusedBlock == .host)
    #expect(store.state.demoSelectedSlot == hostSlot)
    #expect(store.state.demoPointerBlock == .host)
    #expect(store.state.demoPointerLocation == hostPoint)
    #expect(store.state.demoWindowMRU[host.id]?.first == hostSlot)
  }

  @Test
  func `app-level cycle recalls the app MRU window`() async throws {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(editor),
      AppAssignment(browser),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.draft.settings.switching.cycleSameAppWindows = false
    state.demoActiveWorkspaceID = workspace.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [editor.bundleIdentifier, editor.bundleIdentifier, browser.bundleIdentifier]
    )
    let editorMRU = SlotID(bundleId: editor.bundleIdentifier, occurrence: 1)
    let browserSlot = try #require(state.demoLayoutTree?.windows.first {
      $0.bundleId == browser.bundleIdentifier
    })
    state.demoSelectedSlot = browserSlot
    state.demoWindowMRU[workspace.id] = [editorMRU, browserSlot]
    state.step = .focusAndCycling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoCommandTapped(.cycle(.next)))

    #expect(store.state.demoSelectedSlot == editorMRU)
    #expect(store.state.demoWindowMRU[workspace.id]?.first == editorMRU)
  }

  @Test
  func `tiling preview applies the same BSP edit operations as workspace layouts`() async throws {
    let original = try #require(BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: ["a", "b", "c"]))
    let source = try #require(original.pathTo(window: SlotID(bundleId: "a", occurrence: 0)))
    let target = try #require(original.pathTo(window: SlotID(bundleId: "c", occurrence: 0)))
    var state = OnboardingFeature.State()
    state.demoLayoutTree = original
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoTileMoved(source: source, target: target, zone: .swap))
    #expect(store.state.demoLayoutTree == original.applying(.relocate(
      source: source,
      target: target,
      zone: .swap,
    )))

    await store.send(.demoDividerResized([], 0.65))
    guard case .branch(let root) = store.state.demoLayoutTree else {
      Issue.record("Expected a branch")
      return
    }
    #expect(root.ratio == 0.65)
  }

  @Test
  func `tiling lesson records every supported edit family independently`() async throws {
    let tree = try #require(BSPNode<SlotID>.synthesizedTemplate(tiledBundleIds: ["a", "b", "c"]))
    var state = OnboardingFeature.State()
    state.demoLayoutTree = tree
    state.demoSelectedSlot = tree.windows.first
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    for command in [
      OnboardingDemoCommand.resize(delta: 0.05),
      OnboardingDemoCommand.focus(.east),
      .cycle(.next),
      .swap(.south),
      .orientation,
      .fullscreen,
      .balance,
    ] {
      await store.send(.demoCommandTapped(command))
    }

    #expect(store.state.practices.isSuperset(of: [
      .focus,
      .cycle,
      .swap,
      .resize,
      .orientation,
      .fullscreen,
      .balance,
    ]))
  }

  @Test
  func `workspace demos rebuild from the selected draft workspace apps`() async {
    let xcode = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let safari = MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    let terminal = MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
    let build = Workspace(name: "Build", apps: [AppAssignment(xcode), AppAssignment(terminal)])
    let research = Workspace(name: "Research", apps: [AppAssignment(safari)])
    let profile = Profile(name: "Default", workspaces: [build, research])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.runningApps = [xcode, safari, terminal]
    state.demoActiveWorkspaceID = build.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [xcode.bundleIdentifier, terminal.bundleIdentifier]
    )
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoWorkspaceSelectionChanged(research.id))

    #expect(store.state.demoActiveWorkspaceID == research.id)
    #expect(store.state.demoLayoutTree?.windows.map(\.bundleId) == [safari.bundleIdentifier])
    #expect(store.state.demoApps == [safari])
  }

  @Test
  func `tiling uses only tiled local and shared apps while handling shows every assignment`() async {
    let editor = MacApp(bundleIdentifier: "editor", name: "Editor")
    let browser = MacApp(bundleIdentifier: "browser", name: "Browser")
    let terminal = MacApp(bundleIdentifier: "terminal", name: "Terminal")
    let notes = MacApp(bundleIdentifier: "notes", name: "Notes")
    let chat = MacApp(bundleIdentifier: "chat", name: "Chat")
    let workspace = Workspace(name: "Build", apps: [
      AppAssignment(editor),
      AppAssignment(browser, layout: .floating),
      AppAssignment(terminal, layout: .unmanaged),
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(
      profiles: [profile],
      sharedApps: [
        SharedApp(notes),
        SharedApp(chat, layout: .floating),
      ],
      activeProfileId: profile.id,
    )
    state.runningApps = [editor, browser, terminal, notes, chat]
    state.demoActiveWorkspaceID = workspace.id
    state.step = .tiling
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.demoWorkspaceSelectionChanged(workspace.id))
    #expect(Set(store.state.demoLayoutTree?.windows.map(\.bundleId) ?? []) == ["editor", "notes"])

    await store.send(.stepSelected(.floating))
    #expect(Set(store.state.demoLayoutTree?.windows.map(\.bundleId) ?? []) == [
      "editor",
      "browser",
      "terminal",
    ])

    await store.send(.stepSelected(.focusAndCycling))
    #expect(Set(store.state.demoLayoutTree?.windows.map(\.bundleId) ?? []) == [
      "editor",
      "browser",
      "terminal",
    ])
  }

  @Test
  func `learned shortcuts remain active throughout later onboarding steps`() async throws {
    let xcode = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let safari = MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    let host = Workspace(name: "Build", apps: [AppAssignment(xcode), AppAssignment(safari)])
    let scratchpad = Workspace(
      name: "Terminal",
      kind: .scratchpad,
      apps: [AppAssignment(MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal"))],
    )
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.demoActiveWorkspaceID = host.id
    state.demoBorrowWorkspaceID = scratchpad.id
    state.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [xcode.bundleIdentifier, safari.bundleIdentifier]
    )
    state.demoSelectedSlot = state.demoLayoutTree?.windows.first
    state.step = .tiling
    let original = try #require(state.demoLayoutTree)
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    let selected = try #require(state.demoSelectedSlot)
    let expected = original.applyingDirectionalSwap(
      window: selected,
      direction: .south,
      in: CGRect(x: 0, y: 0, width: 1200, height: 720),
      gap: 8,
      focusOrder: original.windows,
    )
    await store.send(.demoShortcutPerformed(.swapDown))
    #expect(store.state.demoLayoutTree == expected)
    #expect(store.state.demoLastShortcut == .swapDown)
    #expect(store.state.practices.contains(.swap))

    await store.send(.stepSelected(.borrow))
    await store.send(.demoShortcutPerformed(.toggleOrientation))
    #expect(store.state.demoLastShortcut == .toggleOrientation)
    #expect(store.state.practices.contains(.orientation))

    await store.send(.demoShortcutPerformed(.borrowWorkspace(scratchpad.id)))
    #expect(store.state.demoBorrowPendingWorkspaceID == scratchpad.id)
    await store.send(.demoBorrowChordKey(.edge(.right)))
    #expect(store.state.demoBorrowed)
    #expect(store.state.demoLastShortcut == .borrowWorkspace(scratchpad.id))
    await store.send(.demoShortcutPerformed(.borrowWorkspace(scratchpad.id)))
    #expect(!store.state.demoBorrowed)
    #expect(store.state.practices.contains(.borrowDismiss))

    await store.send(.stepSelected(.floating))
    await store.send(.demoShortcutPerformed(.cycleNextWindow))
    #expect(store.state.demoLastShortcut == .cycleNextWindow)

    await store.send(.demoShortcutPerformed(.borrowWorkspace(scratchpad.id)))
    #expect(store.state.demoBorrowPendingWorkspaceID == scratchpad.id)
    await store.send(.demoBorrowChordKey(.edge(.left)))
    #expect(store.state.demoBorrowed)

    let floatingBundleID = try #require(store.state.demoPrimarySlot?.bundleId)
    await store.send(.demoShortcutPerformed(.toggleFloating))
    #expect(store.state.demoLayoutMode == .floating)
    #expect(
      store.state.draft.workspace(id: host.id)?.apps.first {
        $0.bundleIdentifier == floatingBundleID
      }?.layout == .floating
    )
    await store.send(.demoLayoutModeChanged(.unmanaged))
    #expect(store.state.practices.contains(.ignore))
    await store.send(.demoLayoutModeChanged(.tiled))
    #expect(store.state.practices.contains(.tiledHandling))

    await store.send(.stepSelected(.focusAndCycling))
    #expect(store.state.demoBorrowed)
    let selectionBeforeCycle = try #require(store.state.demoSelectedSlot)
    await store.send(.demoTileTapped(.host, selectionBeforeCycle))
    #expect(store.state.demoFocusedBlock == .host)
    await store.send(.demoShortcutPerformed(.cycleNextWindow))
    #expect(store.state.demoSelectedSlot != selectionBeforeCycle)
    #expect(store.state.demoLastShortcut == .cycleNextWindow)
    await store.send(.demoShortcutPerformed(.toggleOrientation))
    #expect(store.state.practices.contains(.orientation))
  }

  @Test
  func `global hotkeys are routed into onboarding instead of the live workspace`() async {
    let app = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let workspace = Workspace(name: "Build", apps: [AppAssignment(app)])
    let profile = Profile(name: "Default", workspaces: [workspace])
    let config = AppConfig(profiles: [profile], activeProfileId: profile.id)
    var state = AppFeature.State()
    state.$config.withLock { $0 = config }
    state.onboarding.isPresented = true
    state.onboarding.step = .floating
    state.onboarding.draft = config
    state.onboarding.demoActiveWorkspaceID = workspace.id
    state.onboarding.demoLayoutTree = BSPNode<SlotID>.synthesizedTemplate(
      tiledBundleIds: [app.bundleIdentifier]
    )
    state.onboarding.demoSelectedSlot = state.onboarding.demoLayoutTree?.windows.first
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.borrowChord.setArmed = { _ in }
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.hotKeys(.actionTriggered(.toggleFloating)))
    await store.receive {
      guard case .onboarding(.demoShortcutPerformed(.toggleFloating)) = $0 else { return false }
      return true
    }

    #expect(store.state.onboarding.demoLayoutMode == .floating)
    #expect(store.state.onboarding.draft.workspace(id: workspace.id)?.apps.first?.layout == .floating)
    #expect(store.state.config.workspace(id: workspace.id)?.apps.first?.layout == .tiled)
  }

  @Test
  func `borrow direction chord is routed into the onboarding preview`() async {
    let host = Workspace(name: "Build")
    let scratchpad = Workspace(name: "Terminal", kind: .scratchpad)
    let profile = Profile(name: "Default", workspaces: [host, scratchpad])
    let config = AppConfig(profiles: [profile], activeProfileId: profile.id)
    var state = AppFeature.State()
    state.$config.withLock { $0 = config }
    state.onboarding.isPresented = true
    state.onboarding.step = .borrow
    state.onboarding.draft = config
    state.onboarding.demoActiveWorkspaceID = host.id
    state.onboarding.demoBorrowWorkspaceID = scratchpad.id
    state.onboarding.demoBorrowPendingWorkspaceID = scratchpad.id
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.borrowChord.setArmed = { _ in }
      $0.onboardingProgress.save = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.activation(.borrowChordKey(.edge(.right))))
    await store.receive {
      guard case .onboarding(.demoBorrowChordKey(.edge(.right))) = $0 else { return false }
      return true
    }

    #expect(store.state.onboarding.demoBorrowed)
    #expect(store.state.onboarding.demoBorrowEdge == .right)
    #expect(store.state.activation.borrowCapture == nil)
  }

  @Test
  func `AI recommendation stays a proposal until the user applies it`() async {
    let managedApp = MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
    let workspace = Workspace(name: "Focus", apps: [
      AppAssignment(bundleIdentifier: managedApp.bundleIdentifier, name: managedApp.name)
    ])
    let profile = Profile(name: "Default", workspaces: [workspace])
    let app = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.runningApps = [app, managedApp]
    state.aiRecommendationAvailability = .available
    state.roleDescription = "Developer"
    state.recurringWork = "Build features and handle brief support chat"
    let recommendation = OnboardingRecommendation(
      workspaces: [
        .init(name: "Development", kind: .normal),
        .init(name: "Support", kind: .scratchpad),
      ],
      assignments: [
        .init(bundleIdentifier: app.bundleIdentifier, workspaceName: "Development"),
        .init(bundleIdentifier: managedApp.bundleIdentifier, workspaceName: "Development"),
      ],
    )
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.onboardingProgress.save = { _ in }
      $0.onboardingRecommendations.recommend = { apps, context in
        #expect(Set(apps.map(\.bundleIdentifier)) == Set([app, managedApp].map(\.bundleIdentifier)))
        #expect(context.role == "Developer")
        #expect(context.contextStyle == .focused)
        #expect(context.displays == [
          OnboardingRecommendationDisplay(
            name: "Test Display",
            usableWidth: 1920,
            usableHeight: 1080,
            isPrimary: true,
          )
        ])
        return recommendation
      }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.aiRecommendationButtonTapped)
    await store.receive(\.aiRecommendationResponse)
    #expect(store.state.destination(for: app.bundleIdentifier) == .unassigned)
    #expect(store.state.aiRecommendationChangeCount == 2)

    await store.send(.aiRecommendationApplyButtonTapped)
    #expect(store.state.normalWorkspaces.map(\.name) == ["Development"])
    #expect(store.state.scratchpads.map(\.name) == ["Support"])
    let developmentID = store.state.normalWorkspaces[0].id
    #expect(store.state.destination(for: app.bundleIdentifier) == .workspace(developmentID))
    #expect(store.state.destination(for: managedApp.bundleIdentifier) == .workspace(developmentID))
    #expect(store.state.aiRecommendation == nil)
  }

  @Test
  func `external AI prompt and pasted result use the same draft review flow`() async {
    let app = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let workspace = Workspace(name: "Main")
    let profile = Profile(name: "Default", workspaces: [workspace])
    var state = OnboardingFeature.State()
    state.draft = AppConfig(profiles: [profile], activeProfileId: profile.id)
    state.runningApps = [app]
    state.roleDescription = "Developer"
    state.recurringWork = "I build product features and review changes."
    let copiedPrompt = LockIsolated<String?>(nil)
    let recommendation = OnboardingRecommendation(
      workspaces: [.init(name: "Build", kind: .normal)],
      assignments: [.init(bundleIdentifier: app.bundleIdentifier, workspaceName: "Build")],
    )
    let store = TestStore(initialState: state) {
      OnboardingFeature()
    } withDependencies: {
      $0.clipboard.writeString = { value in
        copiedPrompt.setValue(value)
        return true
      }
      $0.clipboard.readString = { "pasted result" }
      $0.onboardingProgress.save = { _ in }
      $0.onboardingRecommendations.makeExternalPrompt = { apps, context in
        #expect(apps == [app])
        #expect(context.role == "Developer")
        #expect(context.displays.first?.usableWidth == 1920)
        #expect(context.displays.first?.usableHeight == 1080)
        return "generated prompt"
      }
      $0.onboardingRecommendations.parseExternalResponse = { response, apps in
        #expect(response == "pasted result")
        #expect(apps == [app])
        return recommendation
      }
    }
    store.exhaustivity = .off

    await store.send(.externalAIPromptCopyButtonTapped)
    #expect(copiedPrompt.value == "generated prompt")
    #expect(store.state.externalAIPromptCopied)

    await store.send(.externalAIResponsePasteButtonTapped)
    #expect(store.state.aiRecommendation == recommendation)
    #expect(store.state.destination(for: app.bundleIdentifier) == .unassigned)
  }

  @Test
  func `external AI prompt supplies display constraints and general app reasoning`() {
    let context = OnboardingRecommendationContext(
      role: "Researcher",
      recurringWork: "Compare sources, synthesize findings, and coordinate reviews.",
      contextStyle: .focused,
      prefersScratchpads: true,
      displays: [
        OnboardingRecommendationDisplay(
          name: "Built-in Retina Display",
          usableWidth: 1440,
          usableHeight: 820,
          isPrimary: true,
        )
      ],
    )
    let prompt = OnboardingRecommendationClient.liveValue.makeExternalPrompt(
      [MacApp(bundleIdentifier: "com.example.Canvas", name: "Canvas")],
      context,
    )

    #expect(prompt.contains("1 display"))
    #expect(prompt.contains("usable work area 1440 × 820 points"))
    #expect(prompt.contains("likely interaction shape"))
    #expect(prompt.contains("sustained canvas or quick glance"))
    #expect(prompt.contains("scratchpad preference permits them but does not require one"))
    #expect(!prompt.contains("Slack"))
  }

  @Test
  func `external AI parser accepts fenced JSON and rejects duplicate app placements`() throws {
    let xcode = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let messages = MacApp(bundleIdentifier: "com.apple.MobileSMS", name: "Messages")
    let response = """
      Here is the result:
      ```json
      {
        "workspaces": [
          {
            "name": "Build",
            "kind": "workspace",
            "bundleIdentifiers": ["com.apple.dt.Xcode"]
          },
          {
            "name": "Team pulse",
            "kind": "workspace",
            "bundleIdentifiers": ["com.apple.MobileSMS"]
          },
          {
            "name": "Quick question",
            "kind": "scratchpad",
            "bundleIdentifiers": ["com.apple.dt.Xcode"]
          }
        ]
      }
      ```
      """

    let recommendation = try OnboardingRecommendationClient.liveValue.parseExternalResponse(
      response,
      [xcode, messages],
    )

    #expect(recommendation.workspaces.map(\.name) == ["Build", "Team pulse", "Quick question"])
    #expect(recommendation.assignments == [
      .init(bundleIdentifier: messages.bundleIdentifier, workspaceName: "Team pulse")
    ])
  }

  @Test
  func `AI recommendations keep scratchpads to one app`() throws {
    let xcode = MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
    let safari = MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari")
    let terminal = MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal")
    let notes = MacApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    let response = """
      {
        "workspaces": [
          {"name":"Build","kind":"workspace","bundleIdentifiers":["com.apple.dt.Xcode"]},
          {"name":"Research","kind":"workspace","bundleIdentifiers":["com.apple.Safari"]},
          {"name":"Quick tool","kind":"scratchpad","bundleIdentifiers":["com.apple.Terminal","com.apple.Notes"]}
        ]
      }
      """

    let recommendation = try OnboardingRecommendationClient.liveValue.parseExternalResponse(
      response,
      [xcode, safari, terminal, notes],
    )

    #expect(recommendation.assignments.contains(
      .init(bundleIdentifier: terminal.bundleIdentifier, workspaceName: "Quick tool")
    ))
    #expect(!recommendation.assignments.contains(where: {
      $0.bundleIdentifier == notes.bundleIdentifier
    }))
  }

  @Test
  func `apply refuses to overwrite A config changed outside onboarding`() async {
    let baselineWorkspace = Workspace(name: "Focus")
    let baselineProfile = Profile(name: "Default", workspaces: [baselineWorkspace])
    let baseline = AppConfig(profiles: [baselineProfile], activeProfileId: baselineProfile.id)
    var draft = baseline
    draft.profiles[0].name = "Guided Setup"
    var latest = baseline
    latest.profiles[0].name = "Edited in config.toml"

    var initialState = AppFeature.State()
    initialState.$config.withLock { $0 = latest }
    initialState.onboarding.baseline = baseline
    initialState.onboarding.draft = draft
    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.onboarding(.delegate(.applyRequested(
      baseline: baseline,
      draft: draft,
      activateFirstWorkspace: false,
    ))))
    await store.receive {
      guard case .onboarding(.configurationConflictDetected(let received)) = $0 else {
        return false
      }
      return received == latest
    }

    #expect(store.state.config == latest)
    #expect(store.state.onboarding.configurationConflict)
    #expect(store.state.onboarding.conflictingConfig == latest)
  }
}
