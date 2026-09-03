// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import TatamiKit

@MainActor
struct HookIntegrationTests {

  // MARK: Internal

  @Test
  func `manual profile change emits exactly one hook event`() async {
    let first = Profile(name: "Default")
    let second = Profile(name: "Dual")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [first, second],
      activeProfileId: first.id,
    ))

    await store.send(.activateProfile(second.id, focus: nil)) {
      $0.$config.withLock { $0.activeProfileId = second.id }
    }
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .profileChanged
        && invocation.profile.id == second.id
        && invocation.previousProfile?.id == first.id
        && invocation.occurredAt == date
    }
    await store.finish()
    #expect(invocations.value.count == 1)
  }

  @Test
  func `deleting the active profile keeps its snapshot in the change hook`() async {
    let first = Profile(name: "Default")
    let second = Profile(name: "Dual")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [first, second],
      activeProfileId: first.id,
    ))

    await store.send(.workspaceList(.deleteProfileRequested(first.id)))
    await store.send(.workspaceList(.alert(.presented(.confirmProfileDeletion(first.id)))))
    await store.finish()

    #expect(store.state.config.activeProfileId == second.id)
    #expect(invocations.value.count == 1)
    #expect(invocations.value.first?.profile.id == second.id)
    #expect(invocations.value.first?.previousProfile?.id == first.id)
  }

  @Test
  func `activating the current profile does not emit A change`() async {
    let profile = Profile(name: "Default")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))

    await store.send(.activateProfile(profile.id, focus: nil))
    await store.finish()
    #expect(invocations.value.isEmpty)
  }

  @Test
  func `automatic profile change emits exactly one hook event`() async {
    let first = Profile(name: "Default")
    let second = Profile(name: "Dual")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [first, second],
      activeProfileId: second.id,
    ))

    await store.send(.activation(.delegate(.profileAutoActivated(
      previous: first.id,
      current: second.id,
    ))))
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .profileChanged
        && invocation.profile.id == second.id
        && invocation.previousProfile?.id == first.id
    }
    await store.finish()
    #expect(invocations.value.count == 1)
  }

  @Test
  func `startup profile selection emits one event with no previous profile`() async {
    let profile = Profile(name: "Default")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      activeProfileId: profile.id,
    ))

    await store.send(.startupProfileRestored) {
      $0.didRestoreStartupProfile = true
    }
    await store.send(.cli(.startCompleted(.success(())))) {
      $0.didCompleteCLIStart = true
      $0.didPublishTatamiLaunched = true
    }
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .profileChanged
        && invocation.profile.id == profile.id
        && invocation.previousProfile == nil
    }
    await store.finish()
    #expect(invocations.value.count == 1)
  }

  @Test
  func `completed workspace activation emits display context`() async {
    let workspace = Workspace(name: "Work")
    let profile = Profile(name: "Default", workspaces: [workspace])
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let (store, invocations, _) = makeStore(
      AppConfig(
        profiles: [profile],
        activeProfileId: profile.id,
      ),
      activationGeneration: 1,
    )

    await store.send(.activation(.activationCompleted(
      workspaceId: workspace.id,
      display: display,
      generation: 1,
    )))
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .workspaceActivated
        && invocation.profile.id == profile.id
        && invocation.workspace?.id == workspace.id
        && invocation.display == .init(display)
    }
    await store.finish()
    #expect(invocations.value.count == 1)
  }

  @Test
  func `presented action HUD emits its effective external presentation once`() async {
    let profile = Profile(name: "Default")
    let hook = HookDefinition(
      id: "external-hud",
      event: .hud,
      command: ["/usr/bin/true"],
    )
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      hooks: [hook],
      activeProfileId: profile.id,
    ))
    let presentation = ActionHUDPresentation(
      title: "Borrow Work",
      symbolIconName: "rectangle.split.2x1",
      subtitle: "press a direction",
      subtitleSymbolIconName: "link",
      durationMs: 8_000,
      position: .bottomTrailing,
      size: .large,
      display: display,
    )

    await store.send(.actionHUDPresented(presentation))
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .hud
        && invocation.profile == .init(profile)
        && invocation.display == .init(display)
        && invocation.hud == .init(
          title: presentation.title,
          symbolIconName: presentation.symbolIconName,
          subtitle: presentation.subtitle,
          subtitleSymbolIconName: presentation.subtitleSymbolIconName,
          durationMs: presentation.durationMs,
          position: presentation.position,
          size: presentation.size,
        )
    }
    await store.finish()

    #expect(invocations.value.count == 1)
  }

  @Test
  func `ordinary Borrow return HUD hook does not claim workspace chain provenance`() async {
    let profile = Profile(name: "Default")
    let hook = HookDefinition(
      id: "external-hud",
      event: .hud,
      command: ["/usr/bin/true"],
    )
    let display = DisplayName(uuid: "display-a", name: "Built-in")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      hooks: [hook],
      activeProfileId: profile.id,
    ))
    let presentation = ActionHUDPresentation(
      title: "AI",
      symbolIconName: "brain.head.profile",
      subtitle: "Returned Calendar",
      subtitleSymbolIconName: nil,
      durationMs: 1_800,
      position: .top,
      size: .standard,
      display: display,
    )

    await store.send(.actionHUDPresented(presentation))
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .hud
        && invocation.hud?.title == presentation.title
        && invocation.hud?.subtitle == presentation.subtitle
        && invocation.hud?.subtitleSymbolIconName == nil
    }
    await store.finish()

    #expect(invocations.value.count == 1)
  }

  @Test
  func `workspace-chain HUD hooks retain each affected display`() async {
    let profile = Profile(name: "Default")
    let hook = HookDefinition(
      id: "external-hud",
      event: .hud,
      command: ["/usr/bin/true"],
    )
    let displayA = DisplayName(uuid: "display-a", name: "Built-in")
    let displayB = DisplayName(uuid: "display-b", name: "AirPlay")
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      hooks: [hook],
      activeProfileId: profile.id,
    ))
    let presentations = [
      ActionHUDPresentation(
        title: "Slack",
        symbolIconName: "ellipsis.bubble.fill",
        subtitle: "Coding",
        subtitleSymbolIconName: "link",
        durationMs: 1_800,
        position: .top,
        size: .standard,
        display: displayB,
      ),
      ActionHUDPresentation(
        title: "Code",
        symbolIconName: "swift",
        subtitle: "Coding",
        subtitleSymbolIconName: "link",
        durationMs: 1_800,
        position: .top,
        size: .standard,
        display: displayA,
      ),
    ]

    for presentation in presentations {
      await store.send(.actionHUDPresented(presentation))
      await store.receive {
        guard case .hooks(.emit(let invocation)) = $0 else { return false }
        return invocation.event == .hud
          && invocation.display == presentation.display.map(HookInvocation.DisplaySnapshot.init)
          && invocation.hud?.title == presentation.title
          && invocation.hud?.subtitle == presentation.subtitle
          && invocation.hud?.subtitleSymbolIconName == "link"
      }
    }
    await store.finish()

    #expect(invocations.value.map(\.display?.uuid) == [displayB.uuid, displayA.uuid])
    #expect(invocations.value.map(\.display?.name) == [displayB.name, displayA.name])
  }

  @Test
  func `hook failure HUD suppresses recursive HUD hook publication`() async {
    let profile = Profile(name: "Default")
    let shared = Shared(value: AppConfig(
      profiles: [profile],
      hooks: [HookDefinition(
        id: "external-hud",
        event: .hud,
        command: ["/usr/bin/false"],
      )],
      activeProfileId: profile.id,
    ))
    let state = AppFeature.State()
    state.$config = shared
    state.activation.$config = shared
    state.hooks.$config = shared
    let requests = LockIsolated<[ActionHUDRequest]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.workspaceHUD.showAction = { request in
        requests.withValue { $0.append(request) }
      }
    }
    store.exhaustivity = .off

    await store.send(.errorReportEvent(.reported(ErrorReport(
      domain: "Hook:external-hud",
      message: "Hook failed",
      detail: "Exited with status 1",
    ))))
    await store.finish()

    #expect(requests.value.count == 1)
    #expect(requests.value.first?.emitsHookEvent == false)
  }

  @Test
  func `CLI readiness publishes tatami launched once before startup profile changed`() async {
    let profile = Profile(name: "Default")
    let profileHook = HookDefinition(
      id: "profile",
      event: .profileChanged,
      command: ["/usr/bin/true"],
    )
    let launchHook = HookDefinition(
      id: "launch",
      event: .tatamiLaunched,
      command: ["/usr/bin/true"],
    )
    let (store, invocations, _) = makeStore(AppConfig(
      profiles: [profile],
      hooks: [profileHook, launchHook],
      activeProfileId: profile.id,
    ))

    await store.send(.startupProfileRestored) {
      $0.didRestoreStartupProfile = true
    }
    await store.send(.cli(.startCompleted(.success(())))) {
      $0.didCompleteCLIStart = true
      $0.didPublishTatamiLaunched = true
    }
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .tatamiLaunched
        && invocation.occurredAt == date
        && invocation.profile == .init(profile)
        && invocation.previousProfile == nil
        && invocation.workspace == nil
        && invocation.display == nil
    }
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .profileChanged
        && invocation.profile == .init(profile)
        && invocation.previousProfile == nil
        && invocation.workspace == nil
        && invocation.display == nil
    }
    await store.receive {
      guard case .activation(.activateInitial) = $0 else { return false }
      return true
    }
    await store.send(.cli(.startCompleted(.success(()))))
    await store.send(.startupProfileRestored)
    await store.finish()

    #expect(invocations.value.count { $0.event == .tatamiLaunched } == 1)
    #expect(invocations.value.count { $0.event == .profileChanged } == 1)
    #expect(invocations.value.map(\.event) == [.tatamiLaunched, .profileChanged])
  }

  @Test
  func `disabled or invalid launch hooks do not run and later additions are not replayed`() async {
    let profile = Profile(name: "Default")
    let disabled = HookDefinition(
      id: "disabled-launch",
      event: .tatamiLaunched,
      enabled: false,
      command: ["/usr/bin/true"],
    )
    let invalid = HookDefinition(
      id: "invalid-launch",
      event: .tatamiLaunched,
      command: [],
    )
    let (store, invocations, shared) = makeStore(AppConfig(
      profiles: [profile],
      hooks: [disabled, invalid],
      activeProfileId: profile.id,
    ))

    await store.send(.startupProfileRestored) {
      $0.didRestoreStartupProfile = true
    }
    await store.send(.cli(.startCompleted(.success(())))) {
      $0.didCompleteCLIStart = true
      $0.didPublishTatamiLaunched = true
    }
    shared.withLock {
      $0.hooks.append(HookDefinition(
        id: "added-later",
        event: .tatamiLaunched,
        command: ["/usr/bin/true"],
      ))
    }
    await store.send(.cli(.startCompleted(.success(()))))
    await store.send(.startupProfileRestored)
    await store.finish()

    #expect(invocations.value.filter { $0.event == .tatamiLaunched }.isEmpty)
  }

  @Test
  func `CLI startup failure still publishes tatami launched alongside its report`() async {
    struct CLIStartFailure: Error { }

    let profile = Profile(name: "Default")
    let launchHook = HookDefinition(
      id: "launch",
      event: .tatamiLaunched,
      command: ["/usr/bin/true"],
    )
    let reportedDomains = LockIsolated<[String]>([])
    let (store, invocations, _) = makeStore(
      AppConfig(
        profiles: [profile],
        hooks: [launchHook],
        activeProfileId: profile.id,
      ),
      reportedDomains: reportedDomains,
    )

    await store.send(.startupProfileRestored) {
      $0.didRestoreStartupProfile = true
    }
    await store.send(.cli(.startCompleted(.failure(CLIStartFailure())))) {
      $0.didCompleteCLIStart = true
      $0.didPublishTatamiLaunched = true
    }
    await store.receive {
      guard case .hooks(.emit(let invocation)) = $0 else { return false }
      return invocation.event == .tatamiLaunched
    }
    await store.receive {
      guard case .activation(.activateInitial) = $0 else { return false }
      return true
    }
    await store.finish()

    #expect(reportedDomains.value.contains("CLI"))
    #expect(invocations.value.count { $0.event == .tatamiLaunched } == 1)
  }

  @Test
  func `missing active profile reports the broken launch invariant`() async {
    let launchHook = HookDefinition(
      id: "launch",
      event: .tatamiLaunched,
      command: ["/usr/bin/true"],
    )
    let reportedDomains = LockIsolated<[String]>([])
    let (store, invocations, _) = makeStore(
      AppConfig(profiles: [], hooks: [launchHook]),
      reportedDomains: reportedDomains,
    )

    await store.send(.startupProfileRestored) {
      $0.didRestoreStartupProfile = true
    }
    await store.send(.cli(.startCompleted(.success(())))) {
      $0.didCompleteCLIStart = true
      $0.didPublishTatamiLaunched = true
    }
    await store.finish()

    #expect(reportedDomains.value.contains("StartupHooks"))
    #expect(invocations.value.isEmpty)
  }

  // MARK: Private

  private let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore(
    _ config: AppConfig,
    activationGeneration: UInt64? = nil,
    reportedDomains: LockIsolated<[String]>? = nil,
  ) -> (TestStoreOf<AppFeature>, LockIsolated<[HookInvocation]>, Shared<AppConfig>) {
    var config = config
    if config.hooks.isEmpty {
      config.hooks = [
        HookDefinition(
          id: "integration",
          event: .profileChanged,
          command: ["/usr/bin/true"],
        ),
        HookDefinition(
          id: "integration-workspace",
          event: .workspaceActivated,
          command: ["/usr/bin/true"],
        ),
      ]
    }
    let shared = Shared(value: config)
    var state = AppFeature.State()
    state.$config = shared
    state.activation.$config = shared
    state.cli.$config = shared
    state.hooks.$config = shared
    state.hotKeys.$config = shared
    state.workspaceList.$config = shared
    if let activationGeneration {
      state.activation.isActivating = true
      state.activation.activationGeneration = activationGeneration
      state.activation.activeActivationGeneration = activationGeneration
    }
    let invocations = LockIsolated<[HookInvocation]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = date
      $0.displays.all = { [] }
      $0.errorReporter.report = { domain, _, _ in
        reportedDomains?.withValue { $0.append(domain) }
      }
      $0.hotKeys.register = { _ in }
      $0.hookRunner.run = { _, invocation in
        invocations.withValue { $0.append(invocation) }
        return .success(stdout: "", stderr: "")
      }
      $0.profileSessionStore.saveActiveProfileId = { _ in }
      $0.profileSessionStore.saveWorkspaceState = { _, _ in }
      $0.windowObserver.observe = { _ in }
    }
    store.exhaustivity = .off
    return (store, invocations, shared)
  }

}
