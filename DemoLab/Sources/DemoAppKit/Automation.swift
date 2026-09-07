// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation

public struct DemoCLIContext: Codable, Sendable {
  public let executable: String
  public let socket: String
  public let automationExecutable: String
  public let config: String
  public init(executable:String,socket:String,automationExecutable:String,config:String) {
    self.executable=executable;self.socket=socket;self.automationExecutable=automationExecutable;self.config=config
  }
  public static var file: URL { DemoControl.directory.appendingPathComponent("cli-context.json") }
}
public struct TerminalResult: Codable, Sendable {
  public let command: String
  public let output: String
  public let exitCode: Int32
  public init(command:String,output:String,exitCode:Int32) {self.command=command;self.output=output;self.exitCode=exitCode}
}

public enum DemoCommandRunner {
  public static func run(_ command:String) async throws -> TerminalResult {
    let context=try JSONDecoder().decode(DemoCLIContext.self,from:Data(contentsOf:DemoCLIContext.file))
    let resultFile=DemoControl.directory.appendingPathComponent("terminal-result.json")
    return try await Task.detached {
      let words=command.split(separator:" ").map(String.init)
      let executable:URL
      let arguments:[String]
      if words.first == "tatami" {
        executable=URL(fileURLWithPath:context.executable)
        arguments=Array(words.dropFirst())
      } else if words.first == "focus-session", words.count == 1 {
        executable=URL(fileURLWithPath:context.automationExecutable)
        arguments=["focus-session"]
      } else if words.first == "set-spacing", words.count == 2, let gap=Int(words[1]), (4...40).contains(gap) {
        executable=URL(fileURLWithPath:context.automationExecutable)
        arguments=["set-spacing", String(gap)]
      } else {
        return TerminalResult(command:command,output:"Available: tatami <arguments>, focus-session, set-spacing <4...40>",exitCode:64)
      }
      let process=Process();process.executableURL=executable;process.arguments=arguments
      var env=ProcessInfo.processInfo.environment
      env["TATAMI_SOCKET_PATH"]=context.socket;env["TATAMI_CLI"]=context.executable;env["DEMO_CONFIG"]=context.config
      process.environment=env
      let output=Pipe();process.standardOutput=output;process.standardError=output;process.standardInput=FileHandle.nullDevice
      try process.run()
      let data=output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let result=TerminalResult(command:command,output:String(decoding:data,as:UTF8.self),exitCode:process.terminationStatus)
      try JSONEncoder().encode(result).write(to:resultFile,options:.atomic)
      return result
    }.value
  }
}

public struct HookActivity: Codable, Sendable {
  public var event: String
  public var profile: String
  public var workspace: String
  public var title: String
  public var subtitle: String
  public init(event:String="Waiting for an event",profile:String="",workspace:String="",title:String="",subtitle:String="") {
    self.event=event;self.profile=profile;self.workspace=workspace;self.title=title;self.subtitle=subtitle
  }
}
@MainActor @Observable
public final class HookSession {
  public var workspace = HookActivity()
  public var hud = HookActivity()
  public var error = ""
  @ObservationIgnored private var observation: NSObjectProtocol?
  public init() {}
  public static let changed=Notification.Name("dev.PangMo5.DemoLab.hookChanged")
  public func start() {
    refresh()
    guard observation == nil else {return}
    observation=DistributedNotificationCenter.default().addObserver(forName:Self.changed,object:nil,queue:.main) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }
  public func refresh() {
    do {
      for (name,isHUD) in [("workspace-hook.json",false),("hud-hook.json",true)] {
        let file=DemoControl.directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:file.path) else {continue}
        let value=try JSONDecoder().decode(HookActivity.self,from:Data(contentsOf:file))
        if isHUD {hud=value} else {workspace=value}
      }
      error=""
    } catch {self.error=String(describing:error)}
  }
}
