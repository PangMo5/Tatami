// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - HookEvent

/// Stable lifecycle events that can launch a configured hook.
public enum HookEvent: String, Codable, Sendable, CaseIterable {
  /// Tatami finished restoring its startup profile for this process.
  case tatamiLaunched
  /// The active profile selection changed. `previousProfile` is nil at startup.
  case profileChanged
  /// A workspace activation published its visible state on a display.
  case workspaceActivated
}

// MARK: - HookDefinition

/// One direct executable invocation persisted in `config.toml`.
///
/// `command` is argv, not a shell command: element zero is the executable and
/// every remaining element is passed as one argument. A shell must be opted
/// into explicitly (for example, `["/bin/zsh", "-lc", "..."]`).
public struct HookDefinition: Hashable, Sendable, Codable, Identifiable {

  // MARK: Lifecycle

  public init(
    id: String,
    event: HookEvent,
    enabled: Bool = true,
    command: [String],
    timeoutMs: Int = 5_000,
    workingDirectory: String? = nil,
    environment: [String: String] = [:],
  ) {
    self.id = id
    self.event = event
    self.enabled = enabled
    self.command = command
    self.timeoutMs = timeoutMs
    self.workingDirectory = workingDirectory
    self.environment = environment
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    event = try container.decode(HookEvent.self, forKey: .event)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    command = try container.decode([String].self, forKey: .command)
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 5_000
    workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
    environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
  }

  // MARK: Public

  public var id: String
  public var event: HookEvent
  public var enabled: Bool
  public var command: [String]
  public var timeoutMs: Int
  public var workingDirectory: String?
  public var environment: [String: String]

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case id
    case event
    case enabled
    case command
    case timeoutMs
    case workingDirectory
    case environment
  }

}

// MARK: - HookInvocation

/// A small, versioned event envelope written to a hook's standard input.
public struct HookInvocation: Hashable, Sendable, Codable {

  // MARK: Lifecycle

  public init(
    schemaVersion: Int = 1,
    event: HookEvent,
    occurredAt: Date,
    profile: ProfileSnapshot,
    previousProfile: ProfileSnapshot? = nil,
    workspace: WorkspaceSnapshot? = nil,
    display: DisplaySnapshot? = nil,
  ) {
    self.schemaVersion = schemaVersion
    self.event = event
    self.occurredAt = occurredAt
    self.profile = profile
    self.previousProfile = previousProfile
    self.workspace = workspace
    self.display = display
  }

  // MARK: Public

  public struct ProfileSnapshot: Hashable, Sendable, Codable {
    public init(id: UUID, name: String) {
      self.id = id
      self.name = name
    }

    public init(_ profile: Profile) {
      self.init(id: profile.id, name: profile.name)
    }

    public var id: UUID
    public var name: String
  }

  public struct WorkspaceSnapshot: Hashable, Sendable, Codable {
    public init(id: UUID, name: String, kind: WorkspaceKind) {
      self.id = id
      self.name = name
      self.kind = kind
    }

    public init(_ workspace: Workspace) {
      self.init(id: workspace.id, name: workspace.name, kind: workspace.kind)
    }

    public var id: UUID
    public var name: String
    public var kind: WorkspaceKind
  }

  public struct DisplaySnapshot: Hashable, Sendable, Codable {
    public init(uuid: String?, name: String) {
      self.uuid = uuid
      self.name = name
    }

    public init(_ display: DisplayName) {
      self.init(uuid: display.uuid, name: display.name)
    }

    public var uuid: String?
    public var name: String
  }

  public var schemaVersion: Int
  public var event: HookEvent
  public var occurredAt: Date
  public var profile: ProfileSnapshot
  public var previousProfile: ProfileSnapshot?
  public var workspace: WorkspaceSnapshot?
  public var display: DisplaySnapshot?

}

// MARK: - HookValidationIssue

public struct HookValidationIssue: Equatable, Hashable, Sendable {

  // MARK: Lifecycle

  public init(
    hookIndex: Int,
    field: Field,
    code: Code,
    message: String,
  ) {
    self.hookIndex = hookIndex
    self.field = field
    self.code = code
    self.message = message
  }

  // MARK: Public

  public enum Field: Equatable, Hashable, Sendable {
    case id
    case command
    case timeoutMs
    case workingDirectory
    case environment(key: String)
  }

  public enum Code: Equatable, Hashable, Sendable {
    case emptyID
    case invalidID
    case duplicateID
    case emptyCommand
    case nulCommand
    case timeoutOutOfRange
    case invalidWorkingDirectory
    case invalidEnvironment
  }

  public let hookIndex: Int
  public let field: Field
  public let code: Code
  public let message: String

}

// MARK: - HookConfigurationValidation

public struct HookConfigurationValidation: Equatable, Sendable {
  public init(
    validHooks: [HookDefinition],
    issues: [String],
    detailedIssues: [HookValidationIssue] = [],
  ) {
    self.validHooks = validHooks
    self.issues = issues
    self.detailedIssues = detailedIssues
  }

  public var validHooks: [HookDefinition]
  public var issues: [String]
  public var detailedIssues: [HookValidationIssue]
}

extension HookDefinition {
  /// Validate semantics that Codable cannot express without silently repairing
  /// user input. Invalid entries stay visible in the config but never execute.
  public static func validate(_ hooks: [HookDefinition]) -> HookConfigurationValidation {
    let duplicateIDs = Set(
      Dictionary(grouping: hooks, by: \.id)
        .filter { $0.value.count > 1 }
        .keys
    )
    var validHooks = [HookDefinition]()
    var issues = [String]()
    var detailedIssues = [HookValidationIssue]()

    for (hookIndex, hook) in hooks.enumerated() {
      let issueStartIndex = detailedIssues.endIndex
      func appendIssue(
        field: HookValidationIssue.Field,
        code: HookValidationIssue.Code,
        message: String,
      ) {
        detailedIssues.append(HookValidationIssue(
          hookIndex: hookIndex,
          field: field,
          code: code,
          message: message,
        ))
        if !issues.contains(message) { issues.append(message) }
      }

      if hook.id.isEmpty {
        appendIssue(
          field: .id,
          code: .emptyID,
          message: "A hook id cannot be empty",
        )
      }
      if hook.id.count > 64 || !hook.id.unicodeScalars.allSatisfy(isValidIDScalar) {
        appendIssue(
          field: .id,
          code: .invalidID,
          message: "Hook \"\(hook.id)\" has an invalid id (use ASCII letters, numbers, '.', '_' or '-')",
        )
      }
      if duplicateIDs.contains(hook.id) {
        appendIssue(
          field: .id,
          code: .duplicateID,
          message: "Hook id \"\(hook.id)\" is duplicated",
        )
      }
      if hook.command.first?.isEmpty != false {
        appendIssue(
          field: .command,
          code: .emptyCommand,
          message: "Hook \"\(hook.id)\" has an empty command",
        )
      }
      if hook.command.contains(where: { $0.utf8.contains(0) }) {
        appendIssue(
          field: .command,
          code: .nulCommand,
          message: "Hook \"\(hook.id)\" has a command argument containing NUL",
        )
      }
      if !(100 ... 300_000).contains(hook.timeoutMs) {
        appendIssue(
          field: .timeoutMs,
          code: .timeoutOutOfRange,
          message: "Hook \"\(hook.id)\" timeoutMs must be between 100 and 300000",
        )
      }
      if
        let directory = hook.workingDirectory,
        !(directory.hasPrefix("/") || directory.hasPrefix("~/"))
      {
        appendIssue(
          field: .workingDirectory,
          code: .invalidWorkingDirectory,
          message: "Hook \"\(hook.id)\" workingDirectory must be absolute or start with ~/",
        )
      }
      for (key, value) in hook.environment.sorted(by: { $0.key < $1.key })
        where !isValidEnvironmentKey(key) || value.utf8.contains(0)
      {
        appendIssue(
          field: .environment(key: key),
          code: .invalidEnvironment,
          message: "Hook \"\(hook.id)\" has an invalid environment entry \"\(key)\"",
        )
      }

      if detailedIssues.endIndex == issueStartIndex {
        validHooks.append(hook)
      }
    }
    return HookConfigurationValidation(
      validHooks: validHooks,
      issues: issues,
      detailedIssues: detailedIssues,
    )
  }
}

private func isValidIDScalar(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 45,
       46,
       48 ... 57,
       65 ... 90,
       95,
       97 ... 122:
    true
  default:
    false
  }
}

private func isValidEnvironmentKey(_ key: String) -> Bool {
  guard let first = key.unicodeScalars.first else { return false }
  let isInitial = first == "_" || (65 ... 90).contains(first.value)
    || (97 ... 122).contains(first.value)
  guard isInitial else { return false }
  return key.unicodeScalars.dropFirst().allSatisfy { scalar in
    scalar == "_" || (48 ... 57).contains(scalar.value)
      || (65 ... 90).contains(scalar.value) || (97 ... 122).contains(scalar.value)
  }
}
