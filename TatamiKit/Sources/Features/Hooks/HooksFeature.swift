// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Perception
import Sharing

// MARK: - HooksFeature

@Reducer
public struct HooksFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init() { }

    @Shared(.tatamiConfig) public var config

    var activeDefinitions = [String: HookDefinition]()
    var activeGenerationsByHookID = [String: Set<UInt64>]()
    var failingHookIDs = Set<String>()
    var latestGenerationByHookID = [String: UInt64]()
  }

  public enum Action {
    case configurationChanged
    case emit(HookInvocation)
    case hookFinished(id: String, generation: UInt64, HookExecutionResult)
    case start
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .start:
        let sharedConfig = state.$config
        return .run { send in
          for await _ in Perceptions({ sharedConfig.wrappedValue.hooks }) {
            await send(.configurationChanged)
          }
        }
        .cancellable(id: CancelID.configuration, cancelInFlight: true)

      case .configurationChanged:
        // Observer delivery may lag behind newer file changes or lifecycle
        // events. Always reconcile the current Shared value, never a captured
        // historical hooks array.
        let reconciliation = reconcile(state.config.hooks, state: &state)
        return .merge(reconciliation.cancellations.map { .cancel(id: $0) })

      case .emit(let invocation):
        // Reconcile from the same config snapshot used to select matching
        // hooks. This closes the observer race where a new definition could
        // be launched and then cancelled by its delayed change notification.
        let reconciliation = reconcile(state.config.hooks, state: &state)
        let matching = reconciliation.validation.validHooks.filter {
          $0.enabled && $0.event == invocation.event
        }
        var effects = reconciliation.cancellations.map { Effect<Action>.cancel(id: $0) }
        for hook in matching {
          state.latestGenerationByHookID[hook.id, default: 0] &+= 1
          let generation = state.latestGenerationByHookID[hook.id, default: 0]
          state.activeGenerationsByHookID[hook.id, default: []].insert(generation)
          effects.append(
            .run { [hookRunner] send in
              let result = await hookRunner.run(hook, invocation)
              await send(.hookFinished(id: hook.id, generation: generation, result))
            }
            // Every published lifecycle event gets its own execution. The
            // generation keeps diagnostics ordered without dropping events;
            // only a definition change/removal cancels active executions.
            .cancellable(id: HookRunID(id: hook.id, generation: generation))
          )
        }
        return .merge(effects)

      case .hookFinished(let id, let generation, .success(let stdout, let stderr)):
        removeActiveGeneration(id: id, generation: generation, state: &state)
        logOutput(id: id, stdout: stdout, stderr: stderr)
        guard state.latestGenerationByHookID[id] == generation else { return .none }
        state.failingHookIDs.remove(id)
        errorReporter.resolve(runtimeDomain(id))
        return .none

      case .hookFinished(let id, let generation, .failure(let message, let stdout, let stderr)):
        removeActiveGeneration(id: id, generation: generation, state: &state)
        logFailure(id: id, message: message, stdout: stdout, stderr: stderr)
        guard state.latestGenerationByHookID[id] == generation else { return .none }
        state.failingHookIDs.insert(id)
        let detail = firstDiagnostic(message: message, stderr: stderr, stdout: stdout)
        errorReporter.report(
          runtimeDomain(id),
          String(localized: "Hook \"\(id)\" failed"),
          detail,
        )
        return .none

      case .hookFinished(let id, let generation, .cancelled):
        removeActiveGeneration(id: id, generation: generation, state: &state)
        guard state.latestGenerationByHookID[id] == generation else { return .none }
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.debugLog) var debugLog
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.hookRunner) var hookRunner

  // MARK: Private

  private enum CancelID { case configuration }

  private struct HookRunID: Hashable {
    var id: String
    var generation: UInt64
  }

  private struct Reconciliation {
    var validation: HookConfigurationValidation
    var cancellations: [HookRunID]
  }

  private func reconcile(
    _ hooks: [HookDefinition],
    state: inout State,
  ) -> Reconciliation {
    let validation = HookDefinition.validate(hooks)
    reportValidation(validation)
    let nextDefinitions = Dictionary(
      uniqueKeysWithValues: validation.validHooks
        .filter(\.enabled)
        .map { ($0.id, $0) }
    )
    let knownIDs = Set(state.activeDefinitions.keys)
      .union(state.activeGenerationsByHookID.keys)
      .union(state.failingHookIDs)
    let invalidatedIDs = knownIDs.filter {
      state.activeDefinitions[$0] != nextDefinitions[$0]
    }
    var cancellations = [HookRunID]()
    for id in invalidatedIDs {
      state.latestGenerationByHookID[id, default: 0] &+= 1
      for generation in state.activeGenerationsByHookID.removeValue(forKey: id) ?? [] {
        cancellations.append(HookRunID(id: id, generation: generation))
      }
    }
    let retiredFailures = state.failingHookIDs.intersection(invalidatedIDs)
    state.failingHookIDs.subtract(retiredFailures)
    state.activeDefinitions = nextDefinitions
    for id in retiredFailures {
      errorReporter.resolve(runtimeDomain(id))
    }
    return Reconciliation(validation: validation, cancellations: cancellations)
  }

  private func removeActiveGeneration(
    id: String,
    generation: UInt64,
    state: inout State,
  ) {
    state.activeGenerationsByHookID[id]?.remove(generation)
    if state.activeGenerationsByHookID[id]?.isEmpty == true {
      state.activeGenerationsByHookID[id] = nil
    }
  }

  private func reportValidation(_ validation: HookConfigurationValidation) {
    guard let issue = validation.issues.first else {
      errorReporter.resolve("Hooks")
      return
    }
    errorReporter.report(
      "Hooks",
      String(localized: "Hook configuration is invalid"),
      String(issue.prefix(200)),
    )
  }

  private func logOutput(id: String, stdout: String, stderr: String) {
    guard debugLog.isEnabled() else { return }
    if !stdout.isEmpty { debugLog.log("Hook", "\(id) stdout: \(stdout)") }
    if !stderr.isEmpty { debugLog.log("Hook", "\(id) stderr: \(stderr)") }
  }

  private func logFailure(id: String, message: String, stdout: String, stderr: String) {
    guard debugLog.isEnabled() else { return }
    debugLog.log("Hook", "\(id) failed: \(message)")
    logOutput(id: id, stdout: stdout, stderr: stderr)
  }

}

private func runtimeDomain(_ id: String) -> String {
  "Hook:\(id)"
}

private func firstDiagnostic(message: String, stderr: String, stdout: String) -> String {
  let source = stderr.isEmpty ? (stdout.isEmpty ? message : stdout) : stderr
  let line = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? message
  return String(line.prefix(200))
}
