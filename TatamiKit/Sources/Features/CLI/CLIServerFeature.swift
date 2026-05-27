import AppKit
import ComposableArchitecture
import CoreGraphics
import Foundation
import Sharing
import TatamiCLIProtocol

/// Hosts the CLI socket server and translates incoming requests into
/// reducer actions / dependency calls. The reducer holds nothing other
/// than @Shared(.tatamiConfig); all routing happens inside an effect.
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

    public static func == (lhs: Action, rhs: Action) -> Bool {
      switch (lhs, rhs) {
      case (.start, .start): true
      case (.startCompleted, .startCompleted): true
      case (.incomingRequest(let lhsReq, _), .incomingRequest(let rhsReq, _)):
        lhsReq == rhsReq
      default: false
      }
    }
  }

  @Dependency(\.socketServer) var socketServer
  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler

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
        return .none

      case .startCompleted(.failure(let error)):
        state.isRunning = false
        print("[Tatami] socket server failed to start: \(error)")
        return .none

      case .incomingRequest(let request, let reply):
        let config = state.config
        let manager = workspaceManager
        let tiler = windowTiler
        return .run { _ in
          let response = await Self.handle(
            request: request,
            config: config,
            manager: manager,
            tiler: tiler
          )
          reply(response)
        }
      }
    }
  }

  static func handle(
    request: CLIMessage.Request,
    config: AppConfig,
    manager: WorkspaceManagerClient,
    tiler: WindowTilerClient
  ) async -> CLIMessage.Response {
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
      guard let key = request.arguments.first else {
        return .failure("Missing workspace name. Usage: tatami activate <workspace>")
      }
      guard let workspace = config.activeProfile?.workspaces
        .first(where: { workspaceMatches($0, key) })
      else {
        return .failure("Workspace not found: \(key)")
      }
      await manager.activate(
        ActivationRequest(
          workspace: workspace,
          floatingApps: config.floatingApps,
          targetDisplay: workspace.displayHint,
          setFocus: true,
          mouseHidesOnFocus: config.settings.mouseHidesOnFocus
        )
      )
      let bundleIds = workspace.apps.map(\.bundleIdentifier)
      let settings = config.settings
      let targetDisplay = workspace.displayHint
      let frames = await MainActor.run { () -> [WindowKey: CGRect] in
        let keys = discoverWindowKeys(forBundleIds: bundleIds)
        let tree = BSPNode<WindowKey>.build(
          keys,
          in: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        return WorkspaceActivationFeature.computeFrames(
          tree: tree,
          settings: settings,
          targetDisplay: targetDisplay
        )
      }
      if !frames.isEmpty {
        await tiler.apply(
          FrameApplication(windowFrames: frames, targetDisplay: targetDisplay)
        )
      }
      return .ok("Activated: \(workspace.name)")
    }
  }
}

private func workspaceMatches(_ workspace: Workspace, _ key: String) -> Bool {
  workspace.name == key || workspace.id.uuidString == key
}
