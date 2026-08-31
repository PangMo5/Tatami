// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import Foundation
import TatamiCLIProtocol

// MARK: - TatamiCLI

@main
struct TatamiCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tatami",
    abstract: "Tatami CLI for controlling the Tatami workspace manager.",
    // Read from the Info.plist section embedded in the binary (see Project.swift),
    // so `--version` tracks the app's marketing version without a hardcoded string.
    version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
    subcommands: [
      Version.self,
      ListWorkspaces.self,
      ListApps.self,
      Activate.self,
      ProfileCommand.self,
      WorkspaceCommand.self,
      WindowCommand.self,
      DisplayCommand.self,
      LayoutCommand.self,
      AppCommand.self,
      HookCommand.self,
    ],
  )
}

// MARK: - OutputOptions

struct OutputOptions: ParsableArguments {
  @Flag(name: .long, help: "Print stable JSON output.")
  var json = false

  var format: CLIMessage.OutputFormat {
    json ? .json : .plain
  }
}

// MARK: - FixedDomainCommand

private protocol FixedDomainCommand: ParsableCommand {
  static var domainCommand: CLIMessage.DomainCommand { get }

  var output: OutputOptions { get }
}

extension FixedDomainCommand {
  func run() throws {
    try dispatchDomainCommand(Self.domainCommand, output: output)
  }
}

// MARK: - AdjacentDirection

enum AdjacentDirection: String, ExpressibleByArgument {
  case next
  case previous
}

// MARK: - CardinalDirection

enum CardinalDirection: String, ExpressibleByArgument {
  case left
  case right
  case up
  case down
}

// MARK: - ResizeDirection

enum ResizeDirection: String, ExpressibleByArgument {
  case grow
  case shrink
}

extension TatamiCLI {
  struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print Tatami app version (queries the running app)."
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(command: .version, outputFormat: output.format))
    }
  }

  struct ListWorkspaces: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list-workspaces",
      abstract: "List workspace names in the active profile.",
      shouldDisplay: false,
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(command: .listWorkspaces, outputFormat: output.format))
    }
  }

  struct ListApps: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list-apps",
      abstract: "List bundle IDs assigned to a workspace.",
      shouldDisplay: false,
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .listApps,
        arguments: [workspace],
        outputFormat: output.format,
      ))
    }
  }

  struct Activate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Activate a workspace (show its apps, hide others).",
      shouldDisplay: false,
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .activate,
        arguments: [workspace],
        outputFormat: output.format,
      ))
    }
  }

  struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "profile",
      abstract: "Inspect and manage profiles.",
      subcommands: [
        ProfileList.self,
        ProfileActivate.self,
        ProfileRename.self,
        ProfileDuplicate.self,
      ],
    )
  }

  struct ProfileList: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List profiles.",
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(command: .listProfiles, outputFormat: output.format))
    }
  }

  struct ProfileActivate: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "activate",
      abstract: "Activate a profile.",
    )

    @Argument(help: "Profile name or UUID.")
    var profile: String

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatchDomainCommand(.profileActivate, target: profile, output: output)
    }
  }

  struct ProfileRename: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rename",
      abstract: "Rename a profile.",
    )

    @Argument(help: "Profile name or UUID.")
    var profile: String

    @Argument(help: "New profile name.")
    var newName: String

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .renameProfile,
        arguments: [profile, newName],
        outputFormat: output.format,
      ))
    }
  }

  struct ProfileDuplicate: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "duplicate",
      abstract: "Duplicate a profile with fresh identifiers.",
    )

    @Argument(help: "Profile name or UUID.")
    var profile: String

    @Option(name: .long, help: "Name for the duplicate.")
    var name: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .duplicateProfile,
        arguments: [profile],
        options: optionValues(name: name),
        outputFormat: output.format,
      ))
    }
  }

  struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "workspace",
      abstract: "Inspect and manage workspaces.",
      subcommands: [
        WorkspaceList.self,
        WorkspaceApps.self,
        WorkspaceActivate.self,
        WorkspaceRename.self,
        WorkspaceDuplicate.self,
        WorkspaceNext.self,
        WorkspacePrevious.self,
        WorkspaceRecent.self,
        WorkspaceMoveApp.self,
        WorkspaceAssignApp.self,
        WorkspaceBorrow.self,
        WorkspaceDismissBorrow.self,
      ],
    )
  }

  struct WorkspaceList: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List workspaces in a profile.",
    )

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .listWorkspaces,
        options: optionValues(profile: profile),
        outputFormat: output.format,
      ))
    }
  }

  struct WorkspaceApps: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "apps",
      abstract: "List apps assigned to a workspace.",
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .listApps,
        arguments: [workspace],
        options: optionValues(profile: profile),
        outputFormat: output.format,
      ))
    }
  }

  struct WorkspaceActivate: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "activate",
      abstract: "Activate a workspace.",
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatchDomainCommand(
        .workspaceActivate,
        target: workspace,
        profile: profile,
        output: output,
      )
    }
  }

  struct WorkspaceRename: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rename",
      abstract: "Rename a workspace.",
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @Argument(help: "New workspace name.")
    var newName: String

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .renameWorkspace,
        arguments: [workspace, newName],
        options: optionValues(profile: profile),
        outputFormat: output.format,
      ))
    }
  }

  struct WorkspaceDuplicate: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "duplicate",
      abstract: "Duplicate a workspace with a fresh identifier.",
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @Option(name: .long, help: "Name for the duplicate.")
    var name: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(
        command: .duplicateWorkspace,
        arguments: [workspace],
        options: optionValues(profile: profile, name: name),
        outputFormat: output.format,
      ))
    }
  }

  struct WorkspaceNext: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "next",
      abstract: "Switch to the next workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceNext

    @OptionGroup var output: OutputOptions
  }

  struct WorkspacePrevious: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "previous",
      abstract: "Switch to the previous workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspacePrevious

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceRecent: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "recent",
      abstract: "Switch to the most recent workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceRecent

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceMoveApp: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "move-app",
      abstract: "Move the focused app to an adjacent workspace and switch.",
    )

    @Argument(help: "Direction: next or previous.")
    var direction: AdjacentDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .next: .workspaceMoveAppNext
        case .previous: .workspaceMoveAppPrevious
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct WorkspaceAssignApp: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "assign-app",
      abstract: "Assign the focused app to a workspace and switch.",
      subcommands: [
        WorkspaceAssignAppTo.self,
        WorkspaceAssignAppNext.self,
        WorkspaceAssignAppPrevious.self,
        WorkspaceAssignAppRecent.self,
      ],
    )
  }

  struct WorkspaceAssignAppTo: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "to",
      abstract: "Assign to a named workspace.",
    )

    @Argument(help: "Workspace name or UUID.")
    var workspace: String

    @Option(name: .long, help: "Profile name or UUID (defaults to active).")
    var profile: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatchDomainCommand(
        .workspaceAssignAppTo,
        target: workspace,
        profile: profile,
        output: output,
      )
    }
  }

  struct WorkspaceAssignAppNext: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "next",
      abstract: "Assign to the next workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceAssignAppNext

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceAssignAppPrevious: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "previous",
      abstract: "Assign to the previous workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceAssignAppPrevious

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceAssignAppRecent: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "recent",
      abstract: "Assign to the most recent workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceAssignAppRecent

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceBorrow: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "borrow",
      abstract: "Borrow a workspace from the active profile.",
      subcommands: [
        WorkspaceBorrowFrom.self,
        WorkspaceBorrowNext.self,
        WorkspaceBorrowPrevious.self,
        WorkspaceBorrowRecent.self,
      ],
    )
  }

  struct WorkspaceBorrowFrom: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "from",
      abstract: "Borrow a named workspace from the active profile.",
    )

    @Argument(help: "Workspace name or UUID in the active profile.")
    var workspace: String

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatchDomainCommand(.workspaceBorrowFrom, target: workspace, output: output)
    }
  }

  struct WorkspaceBorrowNext: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "next",
      abstract: "Borrow the next workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceBorrowNext

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceBorrowPrevious: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "previous",
      abstract: "Borrow the previous workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceBorrowPrevious

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceBorrowRecent: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "recent",
      abstract: "Borrow the most recent workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceBorrowRecent

    @OptionGroup var output: OutputOptions
  }

  struct WorkspaceDismissBorrow: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "dismiss-borrow",
      abstract: "Dismiss Borrow on the pointer display.",
    )
    static let domainCommand = CLIMessage.DomainCommand.workspaceDismissBorrow

    @OptionGroup var output: OutputOptions
  }

  struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "window",
      abstract: "Focus, cycle, resize, swap, and change window layout.",
      subcommands: [
        WindowFocus.self,
        WindowCycle.self,
        WindowResize.self,
        WindowSwap.self,
        WindowToggleFullscreen.self,
        WindowToggleFloating.self,
        WindowToggleSharedFloating.self,
      ],
    )
  }

  struct WindowFocus: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "focus",
      abstract: "Focus a neighboring tiled window.",
    )

    @Argument(help: "Direction: left, right, up, or down.")
    var direction: CardinalDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .left: .windowFocusLeft
        case .right: .windowFocusRight
        case .up: .windowFocusUp
        case .down: .windowFocusDown
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct WindowCycle: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "cycle",
      abstract: "Cycle through visible windows.",
    )

    @Argument(help: "Direction: next or previous.")
    var direction: AdjacentDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .next: .windowCycleNext
        case .previous: .windowCyclePrevious
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct WindowResize: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "resize",
      abstract: "Grow or shrink the focused window.",
    )

    @Argument(help: "Direction: grow or shrink.")
    var direction: ResizeDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .grow: .windowResizeGrow
        case .shrink: .windowResizeShrink
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct WindowSwap: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "swap",
      abstract: "Swap the focused window directionally.",
    )

    @Argument(help: "Direction: left, right, up, or down.")
    var direction: CardinalDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .left: .windowSwapLeft
        case .right: .windowSwapRight
        case .up: .windowSwapUp
        case .down: .windowSwapDown
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct WindowToggleFullscreen: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-fullscreen",
      abstract: "Toggle Tatami layout fullscreen for the focused window.",
    )
    static let domainCommand = CLIMessage.DomainCommand.windowToggleFullscreen

    @OptionGroup var output: OutputOptions
  }

  struct WindowToggleFloating: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-floating",
      abstract: "Toggle floating layout for the focused app.",
    )
    static let domainCommand = CLIMessage.DomainCommand.windowToggleFloating

    @OptionGroup var output: OutputOptions
  }

  struct WindowToggleSharedFloating: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-shared-floating",
      abstract: "Toggle Shared Apps floating layout for the focused app.",
    )
    static let domainCommand = CLIMessage.DomainCommand.windowToggleSharedFloating

    @OptionGroup var output: OutputOptions
  }

  struct DisplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "display",
      abstract: "Move focus between displays.",
      subcommands: [DisplayFocus.self],
    )
  }

  struct DisplayFocus: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "focus",
      abstract: "Focus the workspace on an adjacent display.",
    )

    @Argument(help: "Direction: next or previous.")
    var direction: AdjacentDirection

    @OptionGroup var output: OutputOptions

    func run() throws {
      let command: CLIMessage.DomainCommand =
        switch direction {
        case .next: .displayFocusNext
        case .previous: .displayFocusPrevious
        }
      try dispatchDomainCommand(command, output: output)
    }
  }

  struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "layout",
      abstract: "Edit the active BSP layout and global tiling state.",
      subcommands: [
        LayoutToggleOrientation.self,
        LayoutBalance.self,
        LayoutToggleTiling.self,
      ],
    )
  }

  struct LayoutToggleOrientation: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-orientation",
      abstract: "Toggle the focused split orientation.",
    )
    static let domainCommand = CLIMessage.DomainCommand.layoutToggleOrientation

    @OptionGroup var output: OutputOptions
  }

  struct LayoutBalance: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "balance",
      abstract: "Rebalance the active layout.",
    )
    static let domainCommand = CLIMessage.DomainCommand.layoutBalance

    @OptionGroup var output: OutputOptions
  }

  struct LayoutToggleTiling: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-tiling",
      abstract: "Pause or resume Tatami tiling globally.",
    )
    static let domainCommand = CLIMessage.DomainCommand.layoutToggleTiling

    @OptionGroup var output: OutputOptions
  }

  struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "app",
      abstract: "Change membership for the focused app.",
      subcommands: [AppToggleWorkspace.self, AppToggleShared.self],
    )
  }

  struct AppToggleWorkspace: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-workspace",
      abstract: "Add or remove the focused app in the active workspace.",
    )
    static let domainCommand = CLIMessage.DomainCommand.appToggleWorkspace

    @OptionGroup var output: OutputOptions
  }

  struct AppToggleShared: FixedDomainCommand {
    static let configuration = CommandConfiguration(
      commandName: "toggle-shared",
      abstract: "Add or remove the focused app in Shared Apps.",
    )
    static let domainCommand = CLIMessage.DomainCommand.appToggleShared

    @OptionGroup var output: OutputOptions
  }

  struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "hook",
      abstract: "Inspect configured hooks.",
      subcommands: [HookList.self],
    )
  }

  struct HookList: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List hooks and their validation status.",
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
      try dispatch(CLIMessage.Request(command: .listHooks, outputFormat: output.format))
    }
  }
}

private func optionValues(profile: String? = nil, name: String? = nil) -> [String: String] {
  var options = [String: String]()
  if let profile { options[CLIMessage.Option.profile.rawValue] = profile }
  if let name { options[CLIMessage.Option.name.rawValue] = name }
  return options
}

private func dispatchDomainCommand(
  _ command: CLIMessage.DomainCommand,
  target: String? = nil,
  profile: String? = nil,
  output: OutputOptions,
) throws {
  var arguments = [command.rawValue]
  if let target { arguments.append(target) }
  try dispatch(CLIMessage.Request(
    command: .dispatchDomainCommand,
    arguments: arguments,
    options: optionValues(profile: profile),
    outputFormat: output.format,
  ))
}

private func dispatch(_ request: CLIMessage.Request) throws {
  let response: CLIMessage.Response
  do {
    response = try SocketClient.send(request)
  } catch {
    writeError(String(describing: error), format: request.outputFormat)
    throw ExitCode.failure
  }

  if response.success {
    if request.outputFormat == .json {
      guard
        response.outputFormat == .json,
        let output = response.output,
        let data = output.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
      else {
        writeError(
          "The running Tatami app does not support JSON output; update and relaunch Tatami",
          format: .json,
        )
        throw ExitCode.failure
      }
      print(output)
    } else if let output = response.output, !output.isEmpty {
      print(output)
    }
    return
  }
  writeError(response.error ?? "Unknown Tatami CLI error", format: request.outputFormat)
  throw ExitCode.failure
}

// MARK: - CLIErrorOutput

private struct CLIErrorOutput: Encodable {
  var error: String
}

private func writeError(_ message: String, format: CLIMessage.OutputFormat) {
  let text: String =
    if
      format == .json,
      let data = try? JSONEncoder().encode(CLIErrorOutput(error: message))
    {
      String(decoding: data, as: UTF8.self)
    } else {
      message
    }
  FileHandle.standardError.write(Data("\(text)\n".utf8))
}
