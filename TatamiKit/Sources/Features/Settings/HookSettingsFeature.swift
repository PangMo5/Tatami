// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Perception
import Sharing

// MARK: - HookLocator

public struct HookLocator: Equatable, Hashable, Sendable {
  public init(offset: Int, expected: HookDefinition) {
    self.offset = offset
    self.expected = expected
  }

  public var offset: Int
  public var expected: HookDefinition
}

// MARK: - HookSettingsFeature

@Reducer
public struct HookSettingsFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public enum Mutation: Equatable, Sendable {
    case add
    case delete(HookLocator)
    case edit(HookLocator)
    case setEnabled(HookLocator, Bool)
  }

  public struct MutationFailure: Equatable, Error, Sendable {
    public init(kind: Kind, message: String) {
      self.kind = kind
      self.message = message
    }

    public enum Kind: Equatable, Sendable {
      case staleConfiguration
      case writeFailed
    }

    public var kind: Kind
    public var message: String
  }

  public struct Row: Equatable, Identifiable, Sendable {

    // MARK: Lifecycle

    public init(
      id: UUID,
      locator: HookLocator,
      validationIssues: [HookValidationIssue],
    ) {
      self.id = id
      self.locator = locator
      self.validationIssues = validationIssues
    }

    // MARK: Public

    public var id: UUID
    public var locator: HookLocator
    public var validationIssues: [HookValidationIssue]

    public var definition: HookDefinition {
      locator.expected
    }

    public var isValid: Bool {
      validationIssues.isEmpty
    }

  }

  @ObservableState
  public struct State: Equatable {
    public init() { }

    @Shared(.tatamiConfig) public var config
    public var rows = [Row]()
    public var mutationInFlight: Mutation?
    @Presents public var editor: HookEditorFeature.State?
    @Presents public var alert: AlertState<Action.Alert>?
  }

  public enum Action {
    case addButtonTapped
    case alert(PresentationAction<Alert>)
    case configurationChanged
    case deleteButtonTapped(HookLocator)
    case editButtonTapped(HookLocator)
    case editor(PresentationAction<HookEditorFeature.Action>)
    case enabledChanged(HookLocator, Bool)
    case mutationResponse(Mutation, Result<Void, MutationFailure>)
    case task

    public enum Alert: Equatable {
      case confirmDelete(HookLocator)
      case dismiss
    }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        reconcileRows(state: &state)
        let sharedConfig = state.$config
        return .run { send in
          for await _ in Perceptions({ sharedConfig.wrappedValue.hooks }) {
            await send(.configurationChanged)
          }
        }
        .cancellable(id: CancelID.observation, cancelInFlight: true)

      case .configurationChanged:
        reconcileRows(state: &state)
        return .none

      case .addButtonTapped:
        guard state.mutationInFlight == nil else { return .none }
        let baseline = state.config
        let hook = HookDefinition(
          id: availableID(in: baseline.hooks),
          event: .workspaceActivated,
          command: [],
        )
        state.editor = HookEditorFeature.State(
          mode: .add,
          baseline: baseline,
          hook: hook,
          makeUUID: { uuid() },
        )
        return .none

      case .editButtonTapped(let locator):
        guard state.mutationInFlight == nil else { return .none }
        guard isCurrent(locator, in: state.config) else {
          presentStaleAlert(state: &state)
          reconcileRows(state: &state)
          return .none
        }
        state.editor = HookEditorFeature.State(
          mode: .edit(locator),
          baseline: state.config,
          hook: locator.expected,
          makeUUID: { uuid() },
        )
        return .none

      case .deleteButtonTapped(let locator):
        guard state.mutationInFlight == nil else { return .none }
        guard isCurrent(locator, in: state.config) else {
          presentStaleAlert(state: &state)
          reconcileRows(state: &state)
          return .none
        }
        state.alert = AlertState {
          TextState("Delete hook \"\(locator.expected.id)\"?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmDelete(locator)) {
            TextState("Delete")
          }
          ButtonState(role: .cancel, action: .dismiss) {
            TextState("Cancel")
          }
        } message: {
          TextState("The hook will no longer run for future events.")
        }
        return .none

      case .alert(.presented(.confirmDelete(let locator))):
        guard state.mutationInFlight == nil else { return .none }
        let baseline = state.config
        guard isCurrent(locator, in: baseline) else {
          presentStaleAlert(state: &state)
          reconcileRows(state: &state)
          return .none
        }
        var updated = baseline
        updated.hooks.remove(at: locator.offset)
        let mutation = Mutation.delete(locator)
        state.alert = nil
        state.mutationInFlight = mutation
        return persist(updated, baseline: baseline, config: state.$config, mutation: mutation)

      case .enabledChanged(let locator, let enabled):
        guard state.mutationInFlight == nil else { return .none }
        let baseline = state.config
        guard isCurrent(locator, in: baseline) else {
          presentStaleAlert(state: &state)
          reconcileRows(state: &state)
          return .none
        }
        guard locator.expected.enabled != enabled else { return .none }
        var updated = baseline
        updated.hooks[locator.offset].enabled = enabled
        let mutation = Mutation.setEnabled(locator, enabled)
        state.mutationInFlight = mutation
        return persist(updated, baseline: baseline, config: state.$config, mutation: mutation)

      case .editor(.presented(.delegate(.cancelRequested))):
        state.editor = nil
        return .none

      case .editor(.presented(.delegate(.saveRequested(
        mode: let mode,
        baseline: let baseline,
        definition: let definition,
      )))):
        guard state.mutationInFlight == nil else { return .none }
        var updated = baseline
        let targetIndex: Int
        let mutation: Mutation
        switch mode {
        case .add:
          targetIndex = updated.hooks.endIndex
          updated.hooks.append(definition)
          mutation = .add

        case .edit(let locator):
          guard isCurrent(locator, in: baseline) else {
            presentStaleAlert(state: &state)
            return .none
          }
          targetIndex = locator.offset
          updated.hooks[targetIndex] = definition
          mutation = .edit(locator)
        }
        let candidateIssues = HookDefinition.validate(updated.hooks).detailedIssues
          .filter { $0.hookIndex == targetIndex }
        guard candidateIssues.isEmpty else { return .none }

        state.mutationInFlight = mutation
        return persist(updated, baseline: baseline, config: state.$config, mutation: mutation)

      case .mutationResponse(let mutation, .success):
        guard state.mutationInFlight == mutation else { return .none }
        state.mutationInFlight = nil
        errorReporter.resolve("ConfigSave")
        switch mutation {
        case .add,
             .edit:
          state.editor = nil
        case .delete,
             .setEnabled:
          break
        }
        reconcileRows(state: &state)
        return .none

      case .mutationResponse(let mutation, .failure(let failure)):
        guard state.mutationInFlight == mutation else { return .none }
        state.mutationInFlight = nil
        errorReporter.report(
          "ConfigSave",
          String(localized: "config.toml could not be saved"),
          failure.message,
        )
        switch mutation {
        case .add,
             .edit:
          state.editor?.saveError = failure.message

        case .delete,
             .setEnabled:
          if failure.kind == .staleConfiguration {
            presentStaleAlert(state: &state)
          } else {
            presentSaveFailedAlert(failure.message, state: &state)
          }
        }
        reconcileRows(state: &state)
        return .none

      case .alert,
           .editor:
        return .none
      }
    }
    .ifLet(\.$editor, action: \.editor) {
      HookEditorFeature()
    }
    .ifLet(\.$alert, action: \.alert)
  }

  // MARK: Internal

  @Dependency(\.configPersistence) var configPersistence
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.uuid) var uuid

  // MARK: Private

  private enum CancelID { case observation }

  private static func mutationFailure(_ error: any Error) -> MutationFailure {
    let kind: MutationFailure.Kind =
      if let error = error as? ConfigPersistenceError {
        switch error {
        case .changedInMemory,
             .changedOnDisk,
             .transactionExpired:
          .staleConfiguration
        case .outcomeUnknown:
          .writeFailed
        }
      } else {
        .writeFailed
      }
    return MutationFailure(kind: kind, message: ErrorReportClient.describe(error))
  }

  private func availableID(in hooks: [HookDefinition]) -> String {
    let ids = Set(hooks.map(\.id))
    if !ids.contains("hook") { return "hook" }
    var suffix = 2
    while ids.contains("hook-\(suffix)") { suffix += 1 }
    return "hook-\(suffix)"
  }

  private func isCurrent(_ locator: HookLocator, in config: AppConfig) -> Bool {
    config.hooks.indices.contains(locator.offset)
      && config.hooks[locator.offset] == locator.expected
  }

  private func persist(
    _ updated: AppConfig,
    baseline: AppConfig,
    config: Shared<AppConfig>,
    mutation: Mutation,
  ) -> Effect<Action> {
    .run { [configPersistence] send in
      do {
        let revision = try configPersistence.captureRevision(baseline)
        try configPersistence.commit(
          config,
          baseline,
          revision,
          updated,
          { true },
        )
        await send(.mutationResponse(mutation, .success(())))
      } catch {
        await send(.mutationResponse(
          mutation,
          .failure(Self.mutationFailure(error)),
        ))
      }
    }
  }

  private func presentStaleAlert(state: inout State) {
    state.alert = AlertState {
      TextState("Configuration changed")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
    } message: {
      TextState("The hook was not changed. Review the latest configuration and try again.")
    }
  }

  private func presentSaveFailedAlert(_ message: String, state: inout State) {
    state.alert = AlertState {
      TextState("Hook could not be saved")
    } actions: {
      ButtonState(role: .cancel, action: .dismiss) { TextState("OK") }
    } message: {
      TextState(message)
    }
  }

  private func reconcileRows(state: inout State) {
    let hooks = state.config.hooks
    let validation = HookDefinition.validate(hooks)
    var unusedRows = Array(state.rows.enumerated())
    var rows = [Row]()
    rows.reserveCapacity(hooks.count)

    for (offset, definition) in hooks.enumerated() {
      let matchIndex = unusedRows.firstIndex { $0.element.locator.expected == definition }
        ?? unusedRows.firstIndex { $0.element.locator.offset == offset }
      let rowID: UUID =
        if let matchIndex {
          unusedRows.remove(at: matchIndex).element.id
        } else {
          uuid()
        }
      rows.append(Row(
        id: rowID,
        locator: HookLocator(offset: offset, expected: definition),
        validationIssues: validation.detailedIssues.filter { $0.hookIndex == offset },
      ))
    }
    state.rows = rows
  }

}
