// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation

// MARK: - HookEditorFeature

@Reducer
public struct HookEditorFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public enum Mode: Equatable, Sendable {
    case add
    case edit(HookLocator)
  }

  public struct ArgumentRow: Equatable, Identifiable, Sendable {
    public init(id: UUID, value: String) {
      self.id = id
      self.value = value
    }

    public var id: UUID
    public var value: String
  }

  public struct EnvironmentRow: Equatable, Identifiable, Sendable {
    public init(id: UUID, key: String, value: String) {
      self.id = id
      self.key = key
      self.value = value
    }

    public var id: UUID
    public var key: String
    public var value: String
  }

  public struct Draft: Equatable, Sendable {

    // MARK: Lifecycle

    public init(
      id: String,
      event: HookEvent,
      enabled: Bool,
      executable: String,
      arguments: [ArgumentRow],
      timeoutMs: Int,
      workingDirectory: String,
      environment: [EnvironmentRow],
    ) {
      self.id = id
      self.event = event
      self.enabled = enabled
      self.executable = executable
      self.arguments = arguments
      self.timeoutMs = timeoutMs
      self.workingDirectory = workingDirectory
      self.environment = environment
    }

    // MARK: Public

    public var id: String
    public var event: HookEvent
    public var enabled: Bool
    public var executable: String
    public var arguments: [ArgumentRow]
    public var timeoutMs: Int
    public var workingDirectory: String
    public var environment: [EnvironmentRow]

    public var definition: HookDefinition {
      HookDefinition(
        id: id,
        event: event,
        enabled: enabled,
        command: [executable] + arguments.map(\.value),
        timeoutMs: timeoutMs,
        workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory,
        environment: Dictionary(
          environment.map { ($0.key, $0.value) },
          uniquingKeysWith: { _, newest in newest },
        ),
      )
    }

  }

  public struct ValidationIssue: Equatable, Hashable, Sendable {

    // MARK: Lifecycle

    public init(field: Field, code: Code, message: String) {
      self.field = field
      self.code = code
      self.message = message
    }

    // MARK: Public

    public enum Field: Equatable, Hashable, Sendable {
      case id
      case executable
      case argument(UUID)
      case timeoutMs
      case workingDirectory
      case environment(UUID)
      case testWorkspace
    }

    public enum Code: Equatable, Hashable, Sendable {
      case definition(HookValidationIssue.Code)
      case duplicateEnvironmentKey
      case noActiveProfile
      case noWorkspace
      case staleDefinition
    }

    public var field: Field
    public var code: Code
    public var message: String

  }

  public enum TestStatus: Equatable, Sendable {
    case idle
    case running(UUID)
    case succeeded(stdout: String, stderr: String)
    case failed(message: String, stdout: String, stderr: String)
    case cancelled
  }

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init(
      mode: Mode,
      baseline: AppConfig,
      hook: HookDefinition,
      makeUUID: () -> UUID,
    ) {
      self.mode = mode
      self.baseline = baseline
      draft = Draft(
        id: hook.id,
        event: hook.event,
        enabled: hook.enabled,
        executable: hook.command.first ?? "",
        arguments: hook.command.dropFirst().map {
          ArgumentRow(id: makeUUID(), value: $0)
        },
        timeoutMs: hook.timeoutMs,
        workingDirectory: hook.workingDirectory ?? "",
        environment: hook.environment.sorted(by: { $0.key < $1.key }).map {
          EnvironmentRow(id: makeUUID(), key: $0.key, value: $0.value)
        },
      )
      testWorkspaceID = baseline.activeProfile?.workspaces.first {
        $0.kind == .normal
      }?.id
    }

    // MARK: Public

    public var mode: Mode
    public var baseline: AppConfig
    public var draft: Draft
    public var testWorkspaceID: Workspace.ID?
    public var testStatus = TestStatus.idle
    public var showsValidation = false
    public var showsTestValidation = false
    public var saveError: String?

    public var testWorkspaces: [Workspace] {
      Array((baseline.activeProfile?.workspaces ?? []).filter { $0.kind == .normal })
    }

    public var validationIssues: [ValidationIssue] {
      let targetIndex: Int
      var hooks = baseline.hooks
      switch mode {
      case .add:
        targetIndex = hooks.endIndex
        hooks.append(draft.definition)

      case .edit(let locator):
        guard hooks.indices.contains(locator.offset), hooks[locator.offset] == locator.expected else {
          return [ValidationIssue(
            field: .id,
            code: .staleDefinition,
            message: String(localized: "The hook changed while it was being edited"),
          )]
        }
        targetIndex = locator.offset
        hooks[targetIndex] = draft.definition
      }

      var issues = HookDefinition.validate(hooks).detailedIssues
        .filter { $0.hookIndex == targetIndex }
        .map(localIssue)

      let groupedEnvironment = Dictionary(grouping: draft.environment, by: \.key)
      for row in draft.environment where (groupedEnvironment[row.key]?.count ?? 0) > 1 {
        issues.append(ValidationIssue(
          field: .environment(row.id),
          code: .duplicateEnvironmentKey,
          message: String(localized: "Environment variable names must be unique"),
        ))
      }
      return issues
    }

    public var testValidationIssues: [ValidationIssue] {
      var issues = validationIssues
      guard baseline.activeProfile != nil else {
        issues.append(ValidationIssue(
          field: .testWorkspace,
          code: .noActiveProfile,
          message: String(localized: "A profile is required to run this hook"),
        ))
        return issues
      }
      if
        draft.event == .workspaceActivated,
        !testWorkspaces.contains(where: { $0.id == testWorkspaceID })
      {
        issues.append(ValidationIssue(
          field: .testWorkspace,
          code: .noWorkspace,
          message: String(localized: "Choose a workspace for the test event"),
        ))
      }
      return issues
    }

    // MARK: Private

    private func localIssue(_ issue: HookValidationIssue) -> ValidationIssue {
      let field: ValidationIssue.Field =
        switch issue.field {
        case .id:
          .id

        case .command:
          if let argument = draft.arguments.first(where: { $0.value.utf8.contains(0) }) {
            .argument(argument.id)
          } else {
            .executable
          }

        case .timeoutMs:
          .timeoutMs

        case .workingDirectory:
          .workingDirectory

        case .environment(let key):
          draft.environment.first(where: { $0.key == key }).map {
            .environment($0.id)
          } ?? .executable
        }
      return ValidationIssue(
        field: field,
        code: .definition(issue.code),
        message: issue.message,
      )
    }

  }

  public enum Action {
    case argumentAddButtonTapped
    case argumentDeleteButtonTapped(UUID)
    case argumentValueChanged(UUID, String)
    case cancelButtonTapped
    case cancelTestButtonTapped
    case enabledChanged(Bool)
    case environmentAddButtonTapped
    case environmentDeleteButtonTapped(UUID)
    case environmentKeyChanged(UUID, String)
    case environmentValueChanged(UUID, String)
    case eventChanged(HookEvent)
    case executableChanged(String)
    case idChanged(String)
    case saveButtonTapped
    case testButtonTapped
    case testResponse(UUID, HookExecutionResult)
    case testWorkspaceChanged(Workspace.ID?)
    case timeoutChanged(Int)
    case workingDirectoryChanged(String)
    case delegate(Delegate)

    // MARK: Public

    public enum Delegate: Equatable {
      case cancelRequested
      case saveRequested(
        mode: Mode,
        baseline: AppConfig,
        definition: HookDefinition,
      )
    }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .argumentAddButtonTapped:
        resetTest(&state)
        state.draft.arguments.append(ArgumentRow(id: uuid(), value: ""))
        return .cancel(id: CancelID.test)

      case .argumentDeleteButtonTapped(let id):
        resetTest(&state)
        state.draft.arguments.removeAll { $0.id == id }
        return .cancel(id: CancelID.test)

      case .argumentValueChanged(let id, let value):
        resetTest(&state)
        state.draft.arguments[id: id]?.value = value
        return .cancel(id: CancelID.test)

      case .enabledChanged(let enabled):
        resetTest(&state)
        state.draft.enabled = enabled
        return .cancel(id: CancelID.test)

      case .environmentAddButtonTapped:
        resetTest(&state)
        state.draft.environment.append(EnvironmentRow(id: uuid(), key: "", value: ""))
        return .cancel(id: CancelID.test)

      case .environmentDeleteButtonTapped(let id):
        resetTest(&state)
        state.draft.environment.removeAll { $0.id == id }
        return .cancel(id: CancelID.test)

      case .environmentKeyChanged(let id, let key):
        resetTest(&state)
        state.draft.environment[id: id]?.key = key
        return .cancel(id: CancelID.test)

      case .environmentValueChanged(let id, let value):
        resetTest(&state)
        state.draft.environment[id: id]?.value = value
        return .cancel(id: CancelID.test)

      case .eventChanged(let event):
        resetTest(&state)
        state.draft.event = event
        if
          event == .workspaceActivated,
          !state.testWorkspaces.contains(where: { $0.id == state.testWorkspaceID })
        {
          state.testWorkspaceID = state.testWorkspaces.first?.id
        }
        return .cancel(id: CancelID.test)

      case .executableChanged(let executable):
        resetTest(&state)
        state.draft.executable = executable
        return .cancel(id: CancelID.test)

      case .idChanged(let id):
        resetTest(&state)
        state.draft.id = id
        return .cancel(id: CancelID.test)

      case .testWorkspaceChanged(let workspaceID):
        resetTest(&state)
        state.testWorkspaceID = workspaceID
        return .cancel(id: CancelID.test)

      case .timeoutChanged(let timeoutMs):
        resetTest(&state)
        state.draft.timeoutMs = timeoutMs
        return .cancel(id: CancelID.test)

      case .workingDirectoryChanged(let directory):
        resetTest(&state)
        state.draft.workingDirectory = directory
        return .cancel(id: CancelID.test)

      case .saveButtonTapped:
        state.showsValidation = true
        state.showsTestValidation = false
        state.saveError = nil
        guard state.validationIssues.isEmpty else { return .none }
        return .send(.delegate(.saveRequested(
          mode: state.mode,
          baseline: state.baseline,
          definition: state.draft.definition,
        )))

      case .cancelButtonTapped:
        return .concatenate(
          .cancel(id: CancelID.test),
          .send(.delegate(.cancelRequested)),
        )

      case .testButtonTapped:
        state.showsValidation = false
        state.showsTestValidation = true
        guard
          state.testValidationIssues.isEmpty,
          let invocation = testInvocation(state: state, occurredAt: now)
        else { return .none }
        let runID = uuid()
        let definition = state.draft.definition
        state.testStatus = .running(runID)
        return .run { [hookRunner] send in
          let result = await hookRunner.run(definition, invocation)
          await send(.testResponse(runID, result))
        }
        .cancellable(id: CancelID.test, cancelInFlight: true)

      case .cancelTestButtonTapped:
        guard case .running = state.testStatus else { return .none }
        state.testStatus = .cancelled
        return .cancel(id: CancelID.test)

      case .testResponse(let runID, let result):
        guard case .running(runID) = state.testStatus else { return .none }
        state.testStatus =
          switch result {
          case .success(let stdout, let stderr):
            .succeeded(stdout: stdout, stderr: stderr)
          case .failure(let message, let stdout, let stderr):
            .failed(message: message, stdout: stdout, stderr: stderr)
          case .cancelled:
            .cancelled
          }
        return .none

      case .delegate:
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.date.now) var now
  @Dependency(\.hookRunner) var hookRunner
  @Dependency(\.uuid) var uuid

  // MARK: Private

  private enum CancelID { case test }

  private func resetTest(_ state: inout State) {
    state.showsValidation = false
    state.showsTestValidation = false
    state.saveError = nil
    state.testStatus = .idle
  }

  private func testInvocation(state: State, occurredAt: Date) -> HookInvocation? {
    guard let profile = state.baseline.activeProfile else { return nil }
    let workspace: Workspace? =
      if state.draft.event == .workspaceActivated {
        state.testWorkspaces.first { $0.id == state.testWorkspaceID }
      } else {
        nil
      }
    if state.draft.event == .workspaceActivated, workspace == nil { return nil }
    return HookInvocation(
      event: state.draft.event,
      occurredAt: occurredAt,
      profile: .init(profile),
      workspace: workspace.map(HookInvocation.WorkspaceSnapshot.init),
    )
  }

}

extension [HookEditorFeature.ArgumentRow] {
  fileprivate subscript(id id: UUID) -> Element? {
    get { first { $0.id == id } }
    set {
      guard let index = firstIndex(where: { $0.id == id }), let newValue else { return }
      self[index] = newValue
    }
  }
}

extension [HookEditorFeature.EnvironmentRow] {
  fileprivate subscript(id id: UUID) -> Element? {
    get { first { $0.id == id } }
    set {
      guard let index = firstIndex(where: { $0.id == id }), let newValue else { return }
      self[index] = newValue
    }
  }
}
