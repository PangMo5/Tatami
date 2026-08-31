// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing

/// Builds the active set of hotkey bindings from the config and pipes
/// fire events back as actions.
@Reducer
public struct HotKeysFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config
    public init() {}

    // Derived from the config — see `AppConfig.hotKeyBindings`, shared with
    // the recorders' conflict detection so the two never disagree.
    public var bindings: [HotKeyBinding] { config.hotKeyBindings }
  }

  public enum Action {
    case onAppear
    case refreshBindings
    case actionTriggered(HotKeyAction)
  }

  @Dependency(\.hotKeys) var hotKeys

  /// `HotKeysCenter.events` is a single-consumer stream; `cancelInFlight`
  /// makes a repeated `.onAppear` replace the subscription instead of
  /// adding a second consumer (which traps in AsyncStream).
  private enum CancelID { case events }

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        let bindings = state.bindings
        return .merge(
          .run { [client = hotKeys] _ in
            await client.register(bindings)
          },
          .run { [client = hotKeys] send in
            for await event in client.events() {
              await send(.actionTriggered(event))
            }
          }
          .cancellable(id: CancelID.events, cancelInFlight: true)
        )

      case .refreshBindings:
        let bindings = state.bindings
        return .run { [client = hotKeys] _ in
          await client.register(bindings)
        }

      case .actionTriggered:
        return .none
      }
    }
  }
}
