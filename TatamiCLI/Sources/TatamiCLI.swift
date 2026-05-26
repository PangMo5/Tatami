import ArgumentParser
import Foundation
import TatamiCLIProtocol

@main
struct TatamiCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tatami",
    abstract: "Tatami CLI — interact with the Tatami workspace manager.",
    version: "0.0.1",
    subcommands: [Version.self]
  )
}

extension TatamiCLI {
  struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print Tatami CLI version."
    )

    func run() throws {
      print("tatami 0.0.1")
      print("socket: \(CLIMessage.socketPath)")
    }
  }
}
