// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import Foundation
import TatamiCLIProtocol

@main
struct TatamiCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tatami",
    abstract: "Tatami CLI — interact with the Tatami workspace manager.",
    // Read from the Info.plist section embedded in the binary (see Project.swift),
    // so `--version` tracks the app's marketing version without a hardcoded string.
    version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
    subcommands: [
      Version.self,
      ListWorkspaces.self,
      ListApps.self,
      Activate.self,
    ]
  )
}

extension TatamiCLI {
  struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print Tatami app version (queries the running app)."
    )

    func run() throws {
      try dispatch(CLIMessage.Request(command: .version))
    }
  }

  struct ListWorkspaces: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list-workspaces",
      abstract: "List workspace names in the active profile."
    )

    func run() throws {
      try dispatch(CLIMessage.Request(command: .listWorkspaces))
    }
  }

  struct ListApps: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list-apps",
      abstract: "List bundle IDs assigned to a workspace."
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    func run() throws {
      try dispatch(CLIMessage.Request(command: .listApps, arguments: [workspace]))
    }
  }

  struct Activate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate a workspace (show its apps, hide others)."
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    func run() throws {
      try dispatch(CLIMessage.Request(command: .activate, arguments: [workspace]))
    }
  }
}

private func dispatch(_ request: CLIMessage.Request) throws {
  let response: CLIMessage.Response
  do {
    response = try SocketClient.send(request)
  } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    throw ExitCode.failure
  }

  if let output = response.output, !output.isEmpty {
    print(output)
  }
  if response.success {
    return
  } else {
    if let error = response.error {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
    }
    throw ExitCode.failure
  }
}
