// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Sharing

extension Reducer {
  /// Apply the same opt-out policy to destructive native alerts. Errors and
  /// informational alerts never participate. Suppression is committed only
  /// when the user chooses the destructive button of the currently shown alert.
  func persistentConfirmations<AlertAction: Equatable>(
    config: KeyPath<State, Shared<AppConfig>>,
    alert: KeyPath<State, AlertState<AlertAction>?>,
    action: CaseKeyPath<Action, PresentationAction<AlertAction>>,
    suppress: WritableKeyPath<State, Bool>,
    kind: @escaping (AlertAction) -> ConfirmationKind?,
  ) -> some Reducer<State, Action> {
    PersistentConfirmations(base: self, config: config, alert: alert, action: action, suppress: suppress, kind: kind)
  }
}

// MARK: - PersistentConfirmations

private struct PersistentConfirmations<Base: Reducer, AlertAction: Equatable>: Reducer {

  // MARK: Internal

  let base: Base
  let config: KeyPath<Base.State, Shared<AppConfig>>
  let alert: KeyPath<Base.State, AlertState<AlertAction>?>
  let action: CaseKeyPath<Base.Action, PresentationAction<AlertAction>>
  let suppress: WritableKeyPath<Base.State, Bool>
  let kind: (AlertAction) -> ConfirmationKind?

  func reduce(into state: inout Base.State, action incoming: Base.Action) -> Effect<Base.Action> {
    let path = AnyCasePath(action)
    let previous = state[keyPath: alert]
    if
      case .presented(let chosen) = path.extract(from: incoming),
      destructiveAction(previous) == chosen, state[keyPath: suppress],
      let category = kind(chosen)
    {
      state[keyPath: config].withLock { $0.settings.confirmations[category] = false }
    }
    let effect = base._reduce(into: &state, action: incoming)
    let current = state[keyPath: alert]
    if previous?.id != current?.id { state[keyPath: suppress] = false }
    if
      previous?.id != current?.id,
      let chosen = destructiveAction(current),
      let category = kind(chosen),
      !state[keyPath: config].wrappedValue.settings.confirmations[category]
    {
      return .merge(effect, .send(path.embed(.presented(chosen))))
    }
    return effect
  }

  // MARK: Private

  private func destructiveAction(_ alert: AlertState<AlertAction>?) -> AlertAction? {
    guard let button = alert?.buttons.first(where: { $0.role == .destructive }) else { return nil }
    switch button.action.type {
    case .send(let action),
         .animatedSend(let action, _): return action
    }
  }

}
