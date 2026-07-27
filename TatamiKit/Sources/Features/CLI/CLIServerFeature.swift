import ComposableArchitecture
import Foundation
import Sharing
import TatamiCLIProtocol

/// Hosts the CLI socket server and translates incoming requests into
/// reducer actions / dependency calls. The reducer holds nothing other
/// than @Shared(.tatamiConfig); read-only queries are answered inside an
/// effect, while `activate` is routed up to the parent as a delegate
/// action so it drives the same activation pipeline as hotkeys.
@Reducer
public struct CLIServerFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var isRunning = false

    public init() {}
  }

  public enum Action {
    case start
    case startCompleted(Result<Void, Error>)
    case incomingRequest(CLIMessage.Request, reply: @Sendable (CLIMessage.Response) -> Void)
    case delegate(Delegate)

    /// Requests the parent must route into other features. The CLI's
    /// `activate` used to call `WorkspaceManagerClient` + a fresh
    /// `BSPNode.build` directly, bypassing the activation reducer — which
    /// left session trees, persisted layouts, mirrors, and
    /// `activeWorkspacesByDisplay` anchored to the outgoing workspace.
    public enum Delegate: Equatable {
      case activateRequested(Workspace.ID)
    }

    public static func == (lhs: Action, rhs: Action) -> Bool {
      switch (lhs, rhs) {
      case (.start, .start): true
      case (.startCompleted(let l), .startCompleted(let r)):
        // `Error` isn't Equatable; compare by Result case so a success and a
        // failure don't collapse to equal (which silently broke exhaustive
        // `TestStore` assertions and `_printChanges` diffing on this case).
        switch (l, r) {
        case (.success, .success), (.failure, .failure): true
        default: false
        }
      case (.incomingRequest(let lhsReq, _), .incomingRequest(let rhsReq, _)):
        lhsReq == rhsReq
      case (.delegate(let lhs), .delegate(let rhs)): lhs == rhs
      default: false
      }
    }
  }

  @Dependency(\.socketServer) var socketServer
  @Dependency(\.errorReporter) var errorReporter

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .start:
        guard !state.isRunning else { return .none }
        state.isRunning = true
        return .merge(
          .run { [client = socketServer] send in
            do {
              try await client.start(CLIMessage.socketPath)
              await send(.startCompleted(.success(())))
            } catch {
              await send(.startCompleted(.failure(error)))
            }
          },
          .run { [client = socketServer] send in
            for await incoming in client.requests() {
              await send(.incomingRequest(incoming.request, reply: incoming.reply))
            }
          }
        )

      case .startCompleted(.success):
        errorReporter.resolve("CLI")
        return .none

      case .startCompleted(.failure(let error)):
        state.isRunning = false
        errorReporter.report(
          "CLI",
          String(
            localized: "Command-line server failed to start — `tatami` CLI won't respond"
          ),
          ErrorReportClient.describe(error)
        )
        return .none

      case .incomingRequest(let request, let reply):
        if request.command == .activate {
          guard let key = request.arguments.first else {
            return .run { _ in
              reply(.failure("Missing workspace name. Usage: tatami activate <workspace>"))
            }
          }
          guard let workspace = state.config.activeProfile?.workspaces
            .first(where: { workspaceMatches($0, key) })
          else {
            return .run { _ in reply(.failure("Workspace not found: \(key)")) }
          }
          // Acknowledge immediately (the CLI's 5 s reply window must not
          // wait on the activation's tile pass) and hand the switch to
          // the activation reducer via the parent.
          return .merge(
            .run { _ in reply(.ok("Activating: \(workspace.name)")) },
            .send(.delegate(.activateRequested(workspace.id)))
          )
        }
        let config = state.config
        return .run { _ in
          reply(Self.handle(request: request, config: config))
        }

      case .delegate:
        return .none
      }
    }
  }

  /// Read-only CLI queries. `activate` never reaches here — it is routed
  /// through the reducer (see `Delegate.activateRequested`).
  static func handle(
    request: CLIMessage.Request,
    config: AppConfig
  ) -> CLIMessage.Response {
    switch request.command {
    case .version:
      return .ok("tatami \(TatamiKit.version)")

    case .listWorkspaces:
      let names = config.activeProfile?.workspaces.map(\.name) ?? []
      return .ok(names.joined(separator: "\n"))

    case .listApps:
      guard let key = request.arguments.first else {
        return .failure("Missing workspace name. Usage: tatami list-apps <workspace>")
      }
      guard let workspace = config.activeProfile?.workspaces
        .first(where: { workspaceMatches($0, key) })
      else {
        return .failure("Workspace not found: \(key)")
      }
      let names = workspace.apps.map(\.bundleIdentifier).joined(separator: "\n")
      return .ok(names)

    case .activate:
      return .failure("Internal routing error")
    }
  }
}

private func workspaceMatches(_ workspace: Workspace, _ key: String) -> Bool {
  workspace.name == key || workspace.id.uuidString == key
}
