import Foundation

/// Wire format shared between the Tatami app (server) and the `tatami` CLI binary.
/// Serialized over a Unix domain socket; encoded as one JSON document per line.
public enum CLIMessage {
  public static let socketPath = "/tmp/tatami.socket"

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
