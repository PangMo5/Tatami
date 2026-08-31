// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import TatamiCLIProtocol
import YYJSON

// MARK: - CLIReply

/// A one-shot socket reply lease. Mutations claim the live connection before
/// committing state; the socket cannot time out after that claim and then
/// report failure for a mutation that still lands.
public struct CLIReply: Sendable {

  // MARK: Lifecycle

  public init(_ send: @escaping @Sendable (CLIMessage.Response) -> Void) {
    let state = LocalCLIReplyState(send: send)
    claimOperation = { state.claim() }
    finishOperation = { state.finish($0) }
    respondOperation = { state.respond($0) }
  }

  init(
    claim: @escaping @Sendable () -> Bool,
    finish: @escaping @Sendable (CLIMessage.Response) -> Void,
    respond: @escaping @Sendable (CLIMessage.Response) -> Bool,
  ) {
    claimOperation = claim
    finishOperation = finish
    respondOperation = respond
  }

  init(
    claim: @escaping @Sendable () -> Bool,
    finish: @escaping @Sendable (CLIMessage.Response) -> Void,
  ) {
    claimOperation = claim
    finishOperation = finish
    respondOperation = { response in
      guard claim() else { return false }
      finish(response)
      return true
    }
  }

  // MARK: Public

  @discardableResult
  public func claim() -> Bool {
    claimOperation()
  }

  public func finish(_ response: CLIMessage.Response) {
    finishOperation(response)
  }

  @discardableResult
  public func send(_ response: CLIMessage.Response) -> Bool {
    respondOperation(response)
  }

  // MARK: Private

  private let claimOperation: @Sendable () -> Bool
  private let finishOperation: @Sendable (CLIMessage.Response) -> Void
  private let respondOperation: @Sendable (CLIMessage.Response) -> Bool

}

// MARK: - CLIServerFeature

/// Hosts the CLI socket server and translates incoming requests into
/// reducer actions / dependency calls. The reducer holds nothing other
/// than @Shared(.tatamiConfig); read-only queries are answered inside an
/// effect, while `activate` is routed up to the parent as a delegate
/// action so it drives the same activation pipeline as hotkeys.
@Reducer
public struct CLIServerFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init() { }

    @Shared(.tatamiConfig) public var config
    public var isRunning = false
  }

  public enum Action {
    case start
    case startCompleted(Result<Void, Error>)
    case incomingRequest(CLIMessage.Request, reply: CLIReply)
    case duplicationPrepared(
      baseline: AppConfig,
      updated: AppConfig,
      configRevision: Data?,
      newWorkspaceIDs: [Workspace.ID],
      response: CLIMessage.Response,
      reply: CLIReply,
      layoutCopied: Bool,
      layoutTimedOut: Bool,
    )
    case delegate(Delegate)

    // MARK: Public

    /// Requests the parent must route into other features. The CLI's
    /// `activate` used to call `WorkspaceManagerClient` + a fresh
    /// `BSPNode.build` directly, bypassing the activation reducer — which
    /// left session trees, persisted layouts, mirrors, and
    /// `activeWorkspacesByDisplay` anchored to the outgoing workspace.
    public enum Delegate: Equatable {
      case activateProfileRequested(
        Profile.ID,
        complete: @Sendable (_ error: String?) -> Void,
      )
      case activateWorkspaceRequested(
        Workspace.ID,
        complete: @Sendable (_ error: String?) -> Void,
      )
      /// Routes a typed domain command through `AppFeature.route`, the same
      /// dispatcher used by keyboard shortcuts and gestures. Completion means
      /// the command was accepted, not that every later AX/window operation
      /// reached a terminal state.
      case dispatchDomainCommandRequested(
        HotKeyAction,
        complete: @Sendable (_ error: String?) -> Void,
      )
      case configurationChanged

      // MARK: Public

      public static func ==(lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (
          .activateProfileRequested(let lhsID, _),
          .activateProfileRequested(let rhsID, _),
        ):
          lhsID == rhsID
        case (
          .activateWorkspaceRequested(let lhsID, _),
          .activateWorkspaceRequested(let rhsID, _),
        ):
          lhsID == rhsID
        case (
          .dispatchDomainCommandRequested(let lhsAction, _),
          .dispatchDomainCommandRequested(let rhsAction, _),
        ):
          lhsAction == rhsAction
        case (.configurationChanged, .configurationChanged):
          true
        default:
          false
        }
      }
    }

    public static func ==(lhs: Action, rhs: Action) -> Bool {
      switch (lhs, rhs) {
      case (.start, .start): true

      case (.startCompleted(let l), .startCompleted(let r)):
        // `Error` isn't Equatable; compare by Result case so a success and a
        // failure don't collapse to equal (which silently broke exhaustive
        // `TestStore` assertions and `_printChanges` diffing on this case).
        switch (l, r) {
        case (.success, .success),
             (.failure, .failure): true
        default: false
        }

      case (.incomingRequest(let lhsReq, _), .incomingRequest(let rhsReq, _)):
        lhsReq == rhsReq

      case (
        .duplicationPrepared(
          let lhsBaseline,
          let lhsUpdated,
          let lhsRevision,
          let lhsIDs,
          let lhsResponse,
          _,
          let lhsCopied,
          let lhsTimedOut,
        ),
        .duplicationPrepared(
          let rhsBaseline,
          let rhsUpdated,
          let rhsRevision,
          let rhsIDs,
          let rhsResponse,
          _,
          let rhsCopied,
          let rhsTimedOut,
        ),
      ):
        lhsBaseline == rhsBaseline
          && lhsUpdated == rhsUpdated
          && lhsRevision == rhsRevision
          && lhsIDs == rhsIDs
          && lhsResponse == rhsResponse
          && lhsCopied == rhsCopied
          && lhsTimedOut == rhsTimedOut

      case (.delegate(let lhs), .delegate(let rhs)): lhs == rhs

      default: false
      }
    }
  }

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
          },
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
          ErrorReportClient.describe(error),
        )
        return .none

      case .incomingRequest(let request, let reply):
        switch request.command {
        case .dispatchDomainCommand:
          do {
            let resolved = try resolveDomainCommand(request: request, config: state.config)
            let action = resolved.action
            guard action.isAvailable(in: state.config) else {
              return replyEffect(
                reply,
                .failure(
                  "Command is not available in the active configuration: "
                    + resolved.command.rawValue
                ),
              )
            }
            let title = String(localized: action.title(in: state.config))
            switch (resolved.command, action) {
            case (.profileActivate, .activateProfile(let profileId)):
              let profileName = state.config.profiles.first(where: { $0.id == profileId })?.name
                ?? title
              let completed = response(
                plain: "Activated profile: \(profileName)",
                value: CLIMessage.DomainCommandResult(
                  command: resolved.command,
                  title: title,
                  status: .completed,
                ),
                format: request.outputFormat,
              )
              guard reply.claim() else { return .none }
              return .send(.delegate(.activateProfileRequested(
                profileId,
                complete: { error in
                  reply.finish(error.map(CLIMessage.Response.failure) ?? completed)
                },
              )))

            case (.workspaceActivate, .activateWorkspace(let workspaceId)):
              guard let workspace = state.config.workspace(id: workspaceId) else {
                return replyEffect(reply, .failure("The requested workspace no longer exists"))
              }
              guard workspace.kind != .scratchpad else {
                return replyEffect(
                  reply,
                  .failure("Scratchpads are borrow-only and cannot be activated from the CLI"),
                )
              }
              let completed = response(
                plain: "Activated workspace: \(workspace.name)",
                value: CLIMessage.DomainCommandResult(
                  command: resolved.command,
                  title: title,
                  status: .completed,
                ),
                format: request.outputFormat,
              )
              guard reply.claim() else { return .none }
              return .send(.delegate(.activateWorkspaceRequested(
                workspaceId,
                complete: { error in
                  reply.finish(error.map(CLIMessage.Response.failure) ?? completed)
                },
              )))

            default:
              guard let hotKeyAction = action.hotKeyAction else {
                return replyEffect(reply, .failure("The `none` action cannot be dispatched"))
              }
              let accepted = response(
                plain: "Accepted: \(title)",
                value: CLIMessage.DomainCommandResult(
                  command: resolved.command,
                  title: title,
                  status: .accepted,
                ),
                format: request.outputFormat,
              )
              guard reply.claim() else { return .none }
              return .send(.delegate(.dispatchDomainCommandRequested(
                hotKeyAction,
                complete: { error in
                  reply.finish(error.map(CLIMessage.Response.failure) ?? accepted)
                },
              )))
            }
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .activate:
          guard let key = request.arguments.first else {
            return replyEffect(
              reply,
              .failure("Missing workspace name. Usage: tatami activate <workspace>"),
            )
          }
          do {
            let (_, workspace) = try resolveWorkspace(
              key,
              profileKey: request.option(.profile),
              config: state.config,
            )
            guard workspace.kind != .scratchpad else {
              return replyEffect(
                reply,
                .failure("Scratchpads are borrow-only and cannot be activated from the CLI"),
              )
            }
            let response = response(
              plain: "Activating: \(workspace.name)",
              value: CLIMessage.MutationInfo(
                id: workspace.id.uuidString,
                name: workspace.name,
              ),
              format: request.outputFormat,
            )
            guard reply.claim() else { return .none }
            return .send(.delegate(.activateWorkspaceRequested(
              workspace.id,
              complete: { error in
                reply.finish(error.map(CLIMessage.Response.failure) ?? response)
              },
            )))
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .renameProfile:
          guard request.arguments.count >= 2 else {
            return replyEffect(
              reply,
              .failure("Usage: tatami profile rename <profile> <new-name>"),
            )
          }
          let newName = request.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
          guard !newName.isEmpty else {
            return replyEffect(reply, .failure("Profile name cannot be empty"))
          }
          do {
            let baseline = state.config
            let configRevision = try configPersistence.captureRevision(baseline)
            let profile = try resolveProfile(request.arguments[0], config: baseline)
            var updated = baseline
            updated.mutateProfile(profile.id) { $0.name = newName }
            if
              let failure = commitConfig(
                updated,
                baseline: baseline,
                configRevision: configRevision,
                config: state.$config,
                reserve: { reply.claim() },
              )
            {
              reply.send(.failure(failure))
              return .none
            }
            let response = response(
              plain: "Renamed profile to: \(newName)",
              value: CLIMessage.MutationInfo(id: profile.id.uuidString, name: newName),
              format: request.outputFormat,
            )
            reply.finish(response)
            return .send(.delegate(.configurationChanged))
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .duplicateProfile:
          guard let key = request.arguments.first else {
            return replyEffect(
              reply,
              .failure("Usage: tatami profile duplicate <profile> [--name <new-name>]"),
            )
          }
          let requestedName = request.option(.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
          if let requestedName, requestedName.isEmpty {
            return replyEffect(reply, .failure("Profile name cannot be empty"))
          }
          do {
            let baseline = state.config
            let configRevision = try configPersistence.captureRevision(baseline)
            let profile = try resolveProfile(key, config: baseline)
            var updated = baseline
            guard let duplicated = updated.duplicateProfile(profile.id) else {
              return replyEffect(reply, .failure("Profile no longer exists: \(key)"))
            }
            if let requestedName {
              updated.mutateProfile(duplicated.profileId) { $0.name = requestedName }
            }
            guard
              let clone = updated.profiles.first(where: { $0.id == duplicated.profileId })
            else {
              return replyEffect(reply, .failure("Profile no longer exists: \(key)"))
            }
            let response = response(
              plain: "Duplicated profile: \(clone.name)",
              value: CLIMessage.MutationInfo(
                id: clone.id.uuidString,
                name: clone.name,
              ),
              format: request.outputFormat,
            )
            return prepareDuplication(
              baseline: baseline,
              updated: updated,
              configRevision: configRevision,
              layoutMapping: duplicated.workspaceIdMap,
              response: response,
              reply: reply,
            )
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .renameWorkspace:
          guard request.arguments.count >= 2 else {
            return replyEffect(
              reply,
              .failure(
                "Usage: tatami workspace rename <workspace> <new-name> [--profile <profile>]"
              ),
            )
          }
          let newName = request.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
          guard !newName.isEmpty else {
            return replyEffect(reply, .failure("Workspace name cannot be empty"))
          }
          do {
            let baseline = state.config
            let configRevision = try configPersistence.captureRevision(baseline)
            let (_, workspace) = try resolveWorkspace(
              request.arguments[0],
              profileKey: request.option(.profile),
              config: baseline,
            )
            var updated = baseline
            updated.mutateWorkspace(workspace.id) { $0.name = newName }
            if
              let failure = commitConfig(
                updated,
                baseline: baseline,
                configRevision: configRevision,
                config: state.$config,
                reserve: { reply.claim() },
              )
            {
              reply.send(.failure(failure))
              return .none
            }
            let response = response(
              plain: "Renamed workspace to: \(newName)",
              value: CLIMessage.MutationInfo(id: workspace.id.uuidString, name: newName),
              format: request.outputFormat,
            )
            reply.finish(response)
            return .send(.delegate(.configurationChanged))
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .duplicateWorkspace:
          guard let key = request.arguments.first else {
            return replyEffect(
              reply,
              .failure(
                "Usage: tatami workspace duplicate <workspace> [--profile <profile>] [--name <new-name>]"
              ),
            )
          }
          let requestedName = request.option(.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
          if let requestedName, requestedName.isEmpty {
            return replyEffect(reply, .failure("Workspace name cannot be empty"))
          }
          do {
            let baseline = state.config
            let configRevision = try configPersistence.captureRevision(baseline)
            let (_, workspace) = try resolveWorkspace(
              key,
              profileKey: request.option(.profile),
              config: baseline,
            )
            var updated = baseline
            guard let duplicateID = updated.duplicateWorkspace(workspace.id) else {
              return replyEffect(reply, .failure("Workspace no longer exists: \(key)"))
            }
            if let requestedName {
              updated.mutateWorkspace(duplicateID) { $0.name = requestedName }
            }
            guard let duplicate = updated.workspace(id: duplicateID) else {
              return replyEffect(reply, .failure("Workspace no longer exists: \(key)"))
            }
            let response = response(
              plain: "Duplicated workspace: \(duplicate.name)",
              value: CLIMessage.MutationInfo(
                id: duplicate.id.uuidString,
                name: duplicate.name,
              ),
              format: request.outputFormat,
            )
            return prepareDuplication(
              baseline: baseline,
              updated: updated,
              configRevision: configRevision,
              layoutMapping: [workspace.id: duplicateID],
              response: response,
              reply: reply,
            )
          } catch {
            return replyEffect(reply, .failure(String(describing: error)))
          }

        case .version,
             .listProfiles,
             .listWorkspaces,
             .listApps,
             .listHooks:
          let config = state.config
          return .run { _ in
            reply.send(Self.handle(request: request, config: config))
          }
        }

      case .duplicationPrepared(
        let baseline,
        let updated,
        let configRevision,
        let newWorkspaceIDs,
        let response,
        let reply,
        let layoutCopied,
        let layoutTimedOut,
      ):
        if layoutTimedOut {
          return replyEffect(
            reply,
            .failure("Saved layout duplication timed out; configuration was not changed"),
          )
        }
        guard layoutCopied else {
          return replyEffect(
            reply,
            .failure("Saved layout could not be duplicated; configuration was not changed"),
          )
        }
        // The persistence transaction reserves the still-live socket slot only
        // after coordination and temp-file preparation, immediately before its
        // atomic exchange.
        if
          let failure = commitConfig(
            updated,
            baseline: baseline,
            configRevision: configRevision,
            config: state.$config,
            reserve: { reply.claim() },
          )
        {
          reply.send(.failure(failure))
          // An indeterminate exchange may already have published the config.
          // Preserve its layouts so a watcher/relaunch cannot expose a clone
          // whose copied layout was deleted by error handling.
          return failure.hasPrefix("Command outcome is unknown")
            ? .none
            : clearLayouts(newWorkspaceIDs)
        }
        reply.finish(response)
        return .send(.delegate(.configurationChanged))

      case .delegate:
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(\.socketServer) var socketServer
  @Dependency(\.configPersistence) var configPersistence
  @Dependency(\.errorReporter) var errorReporter
  @Dependency(\.layoutStore) var layoutStore

  /// Read-only CLI queries. `activate` never reaches here — it is routed
  /// through the reducer (see `Delegate.activateRequested`).
  static func handle(
    request: CLIMessage.Request,
    config: AppConfig,
  ) -> CLIMessage.Response {
    switch request.command {
    case .version:
      return response(
        plain: "tatami \(TatamiKit.version)",
        value: VersionInfo(version: TatamiKit.version),
        format: request.outputFormat,
      )

    case .listProfiles:
      let activeID = config.activeProfile?.id
      let values = config.profiles.map {
        CLIMessage.ProfileInfo(id: $0.id, name: $0.name, isActive: $0.id == activeID)
      }
      return response(
        plain: config.profiles.map(\.name).joined(separator: "\n"),
        value: values,
        format: request.outputFormat,
      )

    case .listWorkspaces:
      do {
        let profile = try request.option(.profile)
          .map { try resolveProfile($0, config: config) }
          ?? config.activeProfile.orThrow(CLIResolveError.noActiveProfile)
        let values = profile.workspaces.map {
          CLIMessage.WorkspaceInfo(
            id: $0.id,
            name: $0.name,
            profileId: profile.id,
            profileName: profile.name,
            kind: $0.kind.rawValue,
          )
        }
        return response(
          plain: profile.workspaces.map(\.name).joined(separator: "\n"),
          value: values,
          format: request.outputFormat,
        )
      } catch {
        return .failure(String(describing: error))
      }

    case .listApps:
      guard let key = request.arguments.first else {
        return .failure("Missing workspace name. Usage: tatami list-apps <workspace>")
      }
      do {
        let (_, workspace) = try resolveWorkspace(
          key,
          profileKey: request.option(.profile),
          config: config,
        )
        let values = workspace.apps.map {
          CLIMessage.AppInfo(
            bundleIdentifier: $0.bundleIdentifier,
            name: $0.name,
            layout: $0.layout.rawValue,
            autoOpen: $0.autoOpen,
          )
        }
        return response(
          plain: workspace.apps.map(\.bundleIdentifier).joined(separator: "\n"),
          value: values,
          format: request.outputFormat,
        )
      } catch {
        return .failure(String(describing: error))
      }

    case .listHooks:
      let validation = HookDefinition.validate(config.hooks)
      let validIDs = Set(validation.validHooks.map(\.id))
      let values = config.hooks.map {
        CLIMessage.HookInfo(
          id: $0.id,
          event: $0.event.rawValue,
          enabled: $0.enabled,
          valid: validIDs.contains($0.id),
        )
      }
      let plain = values.map {
        "\($0.id)\t\($0.event)\t\($0.enabled ? "enabled" : "disabled")"
          + ($0.valid ? "" : "\tinvalid")
      }.joined(separator: "\n")
      return response(plain: plain, value: values, format: request.outputFormat)

    case .activate,
         .dispatchDomainCommand,
         .renameProfile,
         .duplicateProfile,
         .renameWorkspace,
         .duplicateWorkspace:
      return .failure("Internal routing error")
    }
  }

  // MARK: Private

  /// Durably replace the captured file revision, then publish the same value
  /// through the custom shared key without issuing a second write.
  private func commitConfig(
    _ updated: AppConfig,
    baseline: AppConfig,
    configRevision: Data?,
    config: Shared<AppConfig>,
    reserve: @escaping @Sendable () -> Bool,
  ) -> String? {
    do {
      try configPersistence.commit(config, baseline, configRevision, updated, reserve)
      errorReporter.resolve("ConfigSave")
      return nil
    } catch {
      errorReporter.report(
        "ConfigSave",
        String(localized: "config.toml could not be saved"),
        ErrorReportClient.describe(error),
      )
      if case ConfigPersistenceError.outcomeUnknown = error {
        return "Command outcome is unknown; inspect config.toml before retrying: \(ErrorReportClient.describe(error))"
      }
      return "config.toml could not be saved: \(ErrorReportClient.describe(error))"
    }
  }

  private func prepareDuplication(
    baseline: AppConfig,
    updated: AppConfig,
    configRevision: Data?,
    layoutMapping: [Workspace.ID: Workspace.ID],
    response: CLIMessage.Response,
    reply: CLIReply,
  ) -> Effect<Action> {
    .run { [layoutStore] send in
      let (events, continuation) = AsyncStream<LayoutCopyOutcome>.makeStream()
      let copyTask = Task {
        let copied = await layoutStore.copyLayouts(layoutMapping)
        continuation.yield(.completed(copied))
        return copied
      }
      let timeoutTask = Task {
        do {
          try await Task.sleep(for: .seconds(4))
          continuation.yield(.timedOut)
        } catch { }
      }
      var iterator = events.makeAsyncIterator()
      let outcome = await iterator.next() ?? .timedOut
      continuation.finish()

      let layoutCopied: Bool
      let layoutTimedOut: Bool
      switch outcome {
      case .completed(let copied):
        timeoutTask.cancel()
        layoutCopied = copied
        layoutTimedOut = false

      case .timedOut:
        copyTask.cancel()
        // A synchronous filesystem write may not observe task cancellation.
        // If it completes later, remove its unreachable destination snapshots.
        _ = Task {
          if await copyTask.value {
            _ = await layoutStore.removeLayouts(Array(layoutMapping.values))
          }
        }
        layoutCopied = false
        layoutTimedOut = true
      }
      await send(.duplicationPrepared(
        baseline: baseline,
        updated: updated,
        configRevision: configRevision,
        newWorkspaceIDs: Array(layoutMapping.values),
        response: response,
        reply: reply,
        layoutCopied: layoutCopied,
        layoutTimedOut: layoutTimedOut,
      ))
    }
  }

  private func clearLayouts(_ workspaceIDs: [Workspace.ID]) -> Effect<Action> {
    .run { [layoutStore] _ in
      _ = await layoutStore.removeLayouts(workspaceIDs)
    }
  }

}

// MARK: - ResolvedCLIDomainCommand

private struct ResolvedCLIDomainCommand {
  let command: CLIMessage.DomainCommand
  let action: GestureAction
}

// MARK: - CLIDomainCommandResolveError

private enum CLIDomainCommandResolveError: Error, CustomStringConvertible {
  case missingCommand
  case missingTarget(command: CLIMessage.DomainCommand, target: CLIMessage.DomainTarget)
  case tooManyArguments(String)
  case unexpectedTarget(command: CLIMessage.DomainCommand)
  case profileOptionNotAllowed(command: CLIMessage.DomainCommand)
  case unknownCommand(String)
  case inactiveBorrowProfile(String)
  case invalidRoute(CLIMessage.DomainCommand)

  // MARK: Internal

  var description: String {
    switch self {
    case .missingCommand:
      "Missing internal domain command"
    case .missingTarget(let command, let target):
      "Command `\(command.rawValue)` requires a \(target.rawValue) name or UUID"
    case .tooManyArguments(let command):
      "Command `\(command)` accepts at most one workspace/profile target"
    case .unexpectedTarget(let command):
      "Command `\(command.rawValue)` does not accept a target"
    case .profileOptionNotAllowed(let command):
      "Command `\(command.rawValue)` does not accept --profile"
    case .unknownCommand(let command):
      "Unknown internal domain command: \(command)"
    case .inactiveBorrowProfile(let profile):
      "Borrow can only target a workspace in the active profile; `\(profile)` is inactive"
    case .invalidRoute(let command):
      "Invalid internal domain command mapping: \(command.rawValue)"
    }
  }
}

private func resolveDomainCommand(
  request: CLIMessage.Request,
  config: AppConfig,
) throws -> ResolvedCLIDomainCommand {
  guard let rawCommand = request.arguments.first else {
    throw CLIDomainCommandResolveError.missingCommand
  }
  guard let command = CLIMessage.DomainCommand(rawValue: rawCommand) else {
    throw CLIDomainCommandResolveError.unknownCommand(rawCommand)
  }
  guard request.arguments.count <= 2 else {
    throw CLIDomainCommandResolveError.tooManyArguments(rawCommand)
  }
  let targetKey = request.arguments.dropFirst().first
  let profileKey = request.option(.profile)

  func requireTarget(_ kind: CLIMessage.DomainTarget) throws -> String {
    guard let targetKey else {
      throw CLIDomainCommandResolveError.missingTarget(command: command, target: kind)
    }
    return targetKey
  }

  let workspaceId: Workspace.ID?
  let profileId: Profile.ID?
  switch command.target {
  case .workspace:
    if command == .workspaceBorrowFrom, profileKey != nil {
      throw CLIDomainCommandResolveError.profileOptionNotAllowed(command: command)
    }
    let (profile, workspace) = try resolveWorkspace(
      try requireTarget(.workspace),
      profileKey: profileKey,
      config: config,
    )
    if command == .workspaceBorrowFrom, profile.id != config.activeProfile?.id {
      throw CLIDomainCommandResolveError.inactiveBorrowProfile(profile.name)
    }
    workspaceId = workspace.id
    profileId = nil

  case .profile:
    guard profileKey == nil else {
      throw CLIDomainCommandResolveError.profileOptionNotAllowed(command: command)
    }
    workspaceId = nil
    profileId = try resolveProfile(try requireTarget(.profile), config: config).id

  case nil:
    guard targetKey == nil else {
      throw CLIDomainCommandResolveError.unexpectedTarget(command: command)
    }
    guard profileKey == nil else {
      throw CLIDomainCommandResolveError.profileOptionNotAllowed(command: command)
    }
    workspaceId = nil
    profileId = nil
  }

  guard
    let action = GestureAction.cliAction(
      for: command,
      workspaceId: workspaceId,
      profileId: profileId,
    )
  else {
    throw CLIDomainCommandResolveError.invalidRoute(command)
  }
  return ResolvedCLIDomainCommand(command: command, action: action)
}

// MARK: - LayoutCopyOutcome

private enum LayoutCopyOutcome: Sendable {
  case completed(Bool)
  case timedOut
}

// MARK: - VersionInfo

private struct VersionInfo: Codable {
  var version: String
}

// MARK: - CLIResolveError

private enum CLIResolveError: Error, CustomStringConvertible {
  case ambiguousProfile(String, [Profile])
  case ambiguousWorkspace(String, [Workspace])
  case noActiveProfile
  case profileNotFound(String)
  case workspaceNotFound(String)

  // MARK: Internal

  var description: String {
    switch self {
    case .ambiguousProfile(let key, let profiles):
      let candidates = profiles.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
      return "Profile name is ambiguous: \(key). Candidates: \(candidates)"

    case .ambiguousWorkspace(let key, let workspaces):
      let candidates = workspaces.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
      return "Workspace name is ambiguous: \(key). Candidates: \(candidates)"

    case .noActiveProfile:
      return "No active profile"

    case .profileNotFound(let key):
      return "Profile not found: \(key)"

    case .workspaceNotFound(let key):
      return "Workspace not found: \(key)"
    }
  }
}

private func resolveProfile(_ key: String, config: AppConfig) throws -> Profile {
  if
    let id = UUID(uuidString: key),
    let profile = config.profiles.first(where: { $0.id == id })
  {
    return profile
  }
  let matches = config.profiles.filter { $0.name == key }
  guard matches.count <= 1 else { throw CLIResolveError.ambiguousProfile(key, matches) }
  guard let profile = matches.first else { throw CLIResolveError.profileNotFound(key) }
  return profile
}

private func resolveWorkspace(
  _ key: String,
  profileKey: String?,
  config: AppConfig,
) throws -> (Profile, Workspace) {
  if let id = UUID(uuidString: key), profileKey == nil {
    for profile in config.profiles {
      if let workspace = profile.workspaces[id: id] { return (profile, workspace) }
    }
    // A valid UUID string can also be a user-chosen workspace name. Prefer a
    // globally unique ID when it exists, then fall through to the ordinary
    // active-profile name lookup instead of making that name unaddressable.
  }
  let profile = try profileKey
    .map { try resolveProfile($0, config: config) }
    ?? config.activeProfile.orThrow(CLIResolveError.noActiveProfile)
  if let id = UUID(uuidString: key), let workspace = profile.workspaces[id: id] {
    return (profile, workspace)
  }
  let matches = profile.workspaces.filter { $0.name == key }
  guard matches.count <= 1 else { throw CLIResolveError.ambiguousWorkspace(key, Array(matches)) }
  guard let workspace = matches.first else { throw CLIResolveError.workspaceNotFound(key) }
  return (profile, workspace)
}

private func response(
  plain: String,
  value: some Encodable,
  format: CLIMessage.OutputFormat,
) -> CLIMessage.Response {
  guard format == .json else { return .ok(plain) }
  do {
    let data = try YYJSONEncoder().encode(value)
    return .ok(String(decoding: data, as: UTF8.self), outputFormat: .json)
  } catch {
    return .failure("Could not encode JSON response: \(error)")
  }
}

private func replyEffect(
  _ reply: CLIReply,
  _ response: CLIMessage.Response,
) -> Effect<CLIServerFeature.Action> {
  .run { _ in reply.send(response) }
}

private func finishReplyEffect(
  _ reply: CLIReply,
  _ response: CLIMessage.Response,
) -> Effect<CLIServerFeature.Action> {
  .run { _ in reply.finish(response) }
}

extension CLIMessage.Request {
  fileprivate func option(_ option: CLIMessage.Option) -> String? {
    options[option.rawValue]
  }
}

extension Optional {
  fileprivate func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
    guard let self else { throw error() }
    return self
  }
}

// MARK: - LocalCLIReplyState

private final class LocalCLIReplyState: @unchecked Sendable {

  // MARK: Lifecycle

  init(send: @escaping @Sendable (CLIMessage.Response) -> Void) {
    self.send = send
  }

  // MARK: Internal

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !claimed, send != nil else { return false }
    claimed = true
    return true
  }

  func finish(_ response: CLIMessage.Response) {
    lock.lock()
    let send = claimed ? send : nil
    self.send = nil
    lock.unlock()
    send?(response)
  }

  func respond(_ response: CLIMessage.Response) -> Bool {
    lock.lock()
    guard let send else {
      lock.unlock()
      return false
    }
    claimed = true
    self.send = nil
    lock.unlock()
    send(response)
    return true
  }

  // MARK: Private

  private let lock = NSLock()
  private var claimed = false
  private var send: (@Sendable (CLIMessage.Response) -> Void)?

}
