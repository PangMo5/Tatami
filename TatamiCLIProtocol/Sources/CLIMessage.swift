import Foundation

/// Wire format shared between the Tatami app (server) and the `tatami` CLI binary.
/// Serialized over a Unix domain socket; encoded as one JSON document per line.
public enum CLIMessage {
  /// Unix-domain socket in the per-user temp directory
  /// (`DARWIN_USER_TEMP_DIR`, mode 0700). A fixed path in world-writable
  /// `/tmp` let any local user pre-create the file — the sticky bit then
  /// makes the server's `unlink` fail and `bind` error out (a CLI-server
  /// DoS). The per-user dir is stable across processes of the same user,
  /// so the app and the CLI resolve the same path, and it's short enough
  /// for `sun_path`'s 104-byte limit.
  public static let socketPath: String =
    FileManager.default.temporaryDirectory.path + "/tatami.socket"

  public enum Command: String, Codable, Sendable, Equatable {
    case version
    case listWorkspaces = "list-workspaces"
    case listApps = "list-apps"
    case activate
  }

  public struct Request: Codable, Sendable, Equatable {
    public let command: Command
    public let arguments: [String]

    public init(command: Command, arguments: [String] = []) {
      self.command = command
      self.arguments = arguments
    }
  }

  public struct Response: Codable, Sendable, Equatable {
    public let success: Bool
    public let output: String?
    public let error: String?

    public init(success: Bool, output: String? = nil, error: String? = nil) {
      self.success = success
      self.output = output
      self.error = error
    }

    public static func ok(_ output: String? = nil) -> Response {
      Response(success: true, output: output)
    }

    public static func failure(_ error: String) -> Response {
      Response(success: false, error: error)
    }
  }
}
