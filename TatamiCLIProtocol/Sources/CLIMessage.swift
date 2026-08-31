// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Wire format shared between the Tatami app (server) and the `tatami` CLI binary.
/// Serialized over a Unix domain socket; encoded as one JSON document per line.
public enum CLIMessage {
  public enum Command: String, Codable, Sendable, Equatable {
    case version
    case listWorkspaces = "list-workspaces"
    case listApps = "list-apps"
    case activate
    case dispatchDomainCommand = "dispatch-domain-command"
    case listProfiles = "list-profiles"
    case renameProfile = "rename-profile"
    case duplicateProfile = "duplicate-profile"
    case renameWorkspace = "rename-workspace"
    case duplicateWorkspace = "duplicate-workspace"
    case listHooks = "list-hooks"
  }

  public enum OutputFormat: String, Codable, Sendable, Equatable {
    case plain
    case json
  }

  public enum Option: String, Sendable {
    case name
    case profile
  }

  public struct Request: Codable, Sendable, Equatable {

    // MARK: Lifecycle

    public init(
      command: Command,
      arguments: [String] = [],
      options: [String: String] = [:],
      outputFormat: OutputFormat = .plain,
    ) {
      self.command = command
      self.arguments = arguments
      self.options = options
      self.outputFormat = outputFormat
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      command = try container.decode(Command.self, forKey: .command)
      arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
      options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
      outputFormat = try container.decodeIfPresent(OutputFormat.self, forKey: .outputFormat) ?? .plain
    }

    // MARK: Public

    public let command: Command
    public let arguments: [String]
    public let options: [String: String]
    public let outputFormat: OutputFormat

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case command
      case arguments
      case options
      case outputFormat
    }

  }

  public struct ProfileInfo: Codable, Sendable, Equatable {
    public init(id: UUID, name: String, isActive: Bool) {
      self.id = id
      self.name = name
      self.isActive = isActive
    }

    public let id: UUID
    public let name: String
    public let isActive: Bool
  }

  public struct WorkspaceInfo: Codable, Sendable, Equatable {
    public init(id: UUID, name: String, profileId: UUID, profileName: String, kind: String) {
      self.id = id
      self.name = name
      self.profileId = profileId
      self.profileName = profileName
      self.kind = kind
    }

    public let id: UUID
    public let name: String
    public let profileId: UUID
    public let profileName: String
    public let kind: String
  }

  public struct AppInfo: Codable, Sendable, Equatable {
    public init(bundleIdentifier: String, name: String, layout: String, autoOpen: Bool) {
      self.bundleIdentifier = bundleIdentifier
      self.name = name
      self.layout = layout
      self.autoOpen = autoOpen
    }

    public let bundleIdentifier: String
    public let name: String
    public let layout: String
    public let autoOpen: Bool
  }

  public struct HookInfo: Codable, Sendable, Equatable {
    public init(id: String, event: String, enabled: Bool, valid: Bool) {
      self.id = id
      self.event = event
      self.enabled = enabled
      self.valid = valid
    }

    public let id: String
    public let event: String
    public let enabled: Bool
    public let valid: Bool
  }

  public enum DomainTarget: String, Codable, Sendable, Equatable {
    case workspace
    case profile
  }

  /// Stable internal routes behind the public domain-oriented CLI commands.
  /// The `tatami` executable exposes these only through typed subcommands; it
  /// deliberately has no generic route/action escape hatch.
  public enum DomainCommand: String, Codable, CaseIterable, Hashable, Sendable {
    case profileActivate = "profile.activate"

    case workspaceActivate = "workspace.activate"
    case workspaceNext = "workspace.next"
    case workspacePrevious = "workspace.previous"
    case workspaceRecent = "workspace.recent"
    case workspaceMoveAppNext = "workspace.move-app.next"
    case workspaceMoveAppPrevious = "workspace.move-app.previous"
    case workspaceAssignAppTo = "workspace.assign-app.to"
    case workspaceAssignAppNext = "workspace.assign-app.next"
    case workspaceAssignAppPrevious = "workspace.assign-app.previous"
    case workspaceAssignAppRecent = "workspace.assign-app.recent"
    case workspaceBorrowFrom = "workspace.borrow.from"
    case workspaceBorrowNext = "workspace.borrow.next"
    case workspaceBorrowPrevious = "workspace.borrow.previous"
    case workspaceBorrowRecent = "workspace.borrow.recent"
    case workspaceDismissBorrow = "workspace.dismiss-borrow"

    case windowFocusLeft = "window.focus.left"
    case windowFocusRight = "window.focus.right"
    case windowFocusUp = "window.focus.up"
    case windowFocusDown = "window.focus.down"
    case windowCycleNext = "window.cycle.next"
    case windowCyclePrevious = "window.cycle.previous"
    case windowResizeGrow = "window.resize.grow"
    case windowResizeShrink = "window.resize.shrink"
    case windowSwapLeft = "window.swap.left"
    case windowSwapRight = "window.swap.right"
    case windowSwapUp = "window.swap.up"
    case windowSwapDown = "window.swap.down"
    case windowToggleFullscreen = "window.toggle-fullscreen"
    case windowToggleFloating = "window.toggle-floating"
    case windowToggleSharedFloating = "window.toggle-shared-floating"

    case displayFocusNext = "display.focus.next"
    case displayFocusPrevious = "display.focus.previous"

    case layoutToggleOrientation = "layout.toggle-orientation"
    case layoutBalance = "layout.balance"
    case layoutToggleTiling = "layout.toggle-tiling"

    case appToggleWorkspace = "app.toggle-workspace"
    case appToggleShared = "app.toggle-shared"

    // MARK: Public

    public var target: DomainTarget? {
      switch self {
      case .profileActivate:
        .profile
      case .workspaceActivate,
           .workspaceAssignAppTo,
           .workspaceBorrowFrom:
        .workspace
      default:
        nil
      }
    }
  }

  public enum DispatchStatus: String, Codable, Sendable, Equatable {
    /// The shared Tatami dispatcher accepted the command. Window-manager
    /// work can still become a no-op when live focus/topology has changed.
    case accepted
    /// The reducer's activation pipeline reported terminal success.
    case completed
  }

  public struct DomainCommandResult: Codable, Sendable, Equatable {
    public init(
      command: DomainCommand,
      title: String,
      status: DispatchStatus,
    ) {
      self.command = command
      self.title = title
      self.status = status
    }

    public let command: DomainCommand
    public let title: String
    public let status: DispatchStatus
  }

  public struct MutationInfo: Codable, Sendable, Equatable {
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }

    public let id: String
    public let name: String
  }

  public struct Response: Codable, Sendable, Equatable {

    // MARK: Lifecycle

    public init(
      success: Bool,
      output: String? = nil,
      error: String? = nil,
      outputFormat: OutputFormat = .plain,
    ) {
      self.success = success
      self.output = output
      self.error = error
      self.outputFormat = outputFormat
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      success = try container.decode(Bool.self, forKey: .success)
      output = try container.decodeIfPresent(String.self, forKey: .output)
      error = try container.decodeIfPresent(String.self, forKey: .error)
      outputFormat = try container.decodeIfPresent(OutputFormat.self, forKey: .outputFormat)
        ?? .plain
    }

    // MARK: Public

    public let success: Bool
    public let output: String?
    public let error: String?
    /// Explicit capability marker. Older apps omit it and decode as `.plain`,
    /// letting a newer CLI reject accidental plain text for `--json`.
    public let outputFormat: OutputFormat

    public static func ok(
      _ output: String? = nil,
      outputFormat: OutputFormat = .plain,
    ) -> Response {
      Response(success: true, output: output, outputFormat: outputFormat)
    }

    public static func failure(_ error: String) -> Response {
      Response(success: false, error: error)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case success
      case output
      case error
      case outputFormat
    }

  }

  /// Unix-domain socket in the per-user temp directory
  /// (`DARWIN_USER_TEMP_DIR`, mode 0700). A fixed path in world-writable
  /// `/tmp` lets any local user pre-create the file. The sticky bit then
  /// makes the server's `unlink` fail and `bind` error out (a CLI-server
  /// DoS). The per-user dir is stable across processes of the same user,
  /// so the app and the CLI resolve the same path, and it's short enough
  /// for `sun_path`'s 104-byte limit.
  public static var socketPath: String {
    if
      let override = ProcessInfo.processInfo.environment["TATAMI_SOCKET_PATH"],
      !override.isEmpty
    {
      return override
    }
    return FileManager.default.temporaryDirectory.path + "/tatami.socket"
  }
}
