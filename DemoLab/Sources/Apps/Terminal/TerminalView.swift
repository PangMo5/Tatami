// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct TerminalView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var command = ""
  @State private var running = false
  @State private var exitCode: Int32 = 0
  @State private var output = "Launch tools\n\n  check copy       Validate the saved draft\n  tatami …         Run the real Tatami CLI\n  focus-session    Run the workspace setup script\n  set-spacing 24   Edit the live TOML configuration\n"
  var body: some View {
    DemoWindow {
      DemoTitle("Terminal", symbol: "terminal", accent: .graphite, subtitle: "Local automation")
      Spacer()
      Text(running ? "Running" : "Ready").foregroundStyle(.secondary)
    } content: {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text(output).font(.system(size: 17, design: .monospaced)).lineSpacing(6)
              .foregroundStyle(Color(white: 0.9)).textSelection(.enabled)
            HStack {
              Text("launch ❯").foregroundStyle(Color(red:0.91,green:0.80,blue:0.59))
              TextField("command", text: $command).textFieldStyle(.plain).foregroundStyle(.white)
                .accessibilityIdentifier("terminal.command").onSubmit { submit() }.disabled(running)
            }.font(.system(size: 17, design: .monospaced)).id("prompt")
          }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("terminal.output")
          .onChange(of: output) { _, _ in proxy.scrollTo("prompt", anchor: .bottom) }
      }.background(Color(red: 0.10, green: 0.10, blue: 0.11))
    } status: {
      StoryStatus(running ? "Command in progress" : "Exit \(exitCode)", error: session.error)
    }.onAppear { session.start() }
  }
  private func submit() {
    let entered=command.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !entered.isEmpty, !running else {return}
    command="";running=true
    output += "\nlaunch ❯ \(entered)\n"
    let resultFile=DemoControl.directory.appendingPathComponent("terminal-result.json")
    do {
      if FileManager.default.fileExists(atPath:resultFile.path) {try FileManager.default.removeItem(at:resultFile)}
    } catch {output += "\(error)\n";running=false;return}
    Task {
      defer {running=false}
      do {
        let result:TerminalResult
        if entered == "check copy" {
          session.update {$0.checks=$0.evaluateCopy()}
          let checks=session.story.checks
          let text="Reading saved revision \(session.story.revision)\n\n" + checks.map {"\($0.passed ? "✓" : "✕") \($0.title)"}.joined(separator:"\n") + "\n\n\(checks.filter(\.passed).count) of 3 checks passed.\n"
          result=TerminalResult(command:entered,output:text,exitCode:checks.allSatisfy(\.passed) ? 0 : 1)
          try JSONEncoder().encode(result).write(to:resultFile,options:.atomic)
        } else {
          result=try await DemoCommandRunner.run(entered)
        }
        output += result.output + "\n";exitCode=result.exitCode
      } catch {output += "\(error)\n";exitCode=1}
    }
  }
}
