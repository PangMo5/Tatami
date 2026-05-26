import Foundation

/// Wire format shared between the Tatami app (server) and the `tatami` CLI binary.
/// Serialized over a Unix domain socket; encoded as JSON.
public enum CLIMessage {
  public static let socketPath = "/tmp/tatami.socket"

  public struct Request: Codable, Sendable, Equatable {
    public let command: String
    public let arguments: [String]

    public init(command: String, arguments: [String] = []) {
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
  }
}
