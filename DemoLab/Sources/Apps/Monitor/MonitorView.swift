// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct MonitorView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var hooks = HookSession()
  @State private var automation = false
  var body: some View {
    DemoWindow {
      DemoTitle(automation ? "Workspace status" : "Launch status", symbol: automation ? "bolt" : "checkmark.seal", accent: .green)
      Spacer()
      Button { automation.toggle() } label: { Text(automation ? LocalizedStringResource("Project") : LocalizedStringResource("Hooks")) }.accessibilityIdentifier("monitor.mode")
    } content: {
      if automation {
        HookMonitor(workspace:hooks.workspace,hud:hooks.hud)
      } else {
        ProjectMonitor(story:session.story)
      }
    } status: {
      StoryStatus(automation ? "Updated by actual Tatami hooks" : "Synced with the saved draft", error: automation ? hooks.error : session.error)
    }.onAppear {session.start();hooks.start()}
  }
}
private struct HookMonitor:View {
  let workspace:HookActivity;let hud:HookActivity
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(workspace.workspace.isEmpty ? workspace.profile : workspace.workspace).font(.system(size:25,weight:.semibold))
      Label(workspace.profile,systemImage:"rectangle.stack").foregroundStyle(.secondary)
      Divider()
      Text(hud.title.isEmpty ? workspace.event : hud.title).font(.system(size:16,weight:.medium))
      Text(hud.subtitle.isEmpty ? String(localized: "Waiting for the next action…") : hud.subtitle).font(.system(size:13)).foregroundStyle(.secondary).lineLimit(3)
    }.padding(22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(nsColor:.textBackgroundColor))
  }
}
private struct ProjectMonitor:View {
  let story:LaunchStory
  var body: some View {
    VStack(alignment:.leading,spacing:18) {
      Text(story.approved ? LocalizedStringResource("Ready to share") : LocalizedStringResource("Work in progress")).font(.system(size:22,weight:.semibold))
      Label("Draft · revision \(story.revision)",systemImage:"doc.text")
      Label { Text(story.checks.isEmpty ? LocalizedStringResource("Copy checks pending") : LocalizedStringResource("\(story.checks.filter(\.passed).count) / 3 checks passed")) } icon: { Image(systemName:"checkmark.circle") }
        .foregroundStyle(story.checks.count == 3 && story.checks.allSatisfy(\.passed) ? Color.green : Color.secondary)
      Label { Text(story.approved ? LocalizedStringResource("Review approved") : LocalizedStringResource("Waiting for review")) } icon: { Image(systemName:story.approved ? "checkmark.seal.fill" : "clock") }
        .foregroundStyle(story.approved ? Color.green : Color.secondary)
    }.font(.system(size:15)).padding(22).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Color(nsColor:.textBackgroundColor))
  }
}
