// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct NotesView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var newTask = ""
  var body: some View {
    DemoWindow {
      DemoTitle("Launch checklist", symbol: "checklist", accent: .orange, subtitle: "Notes")
      Spacer()
    } content: {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          StoryHeading("FOLLOW-UP", "Before we share it.", "Keep the next small steps beside the work.")
          VStack(spacing: 18) {
            ForEach(session.story.tasks) { item in
              ChecklistRow(item: item) {
                session.update { story in
                  guard let index = story.tasks.firstIndex(where: { $0.id == item.id }) else { return }
                  story.tasks[index].done.toggle()
                }
              }
            }
          }
          Divider()
          HStack(alignment: .top) {
            Image(systemName: "plus.circle").foregroundStyle(.orange).padding(.top, 5)
            TextField("Add a task", text: $newTask).textFieldStyle(.plain)
              .font(.system(size: 17)).accessibilityIdentifier("notes.newTask")
              .onSubmit { addTask() }
            Button("Add") { addTask() }.disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("notes.add")
          }.padding(13).background(Color.orange.opacity(0.055), in: .rect(cornerRadius: 10))
          Text("A good follow-up is small enough to do next.").font(.system(size: 14)).foregroundStyle(.secondary)
        }.padding(26)
      }.background(Color(nsColor: .textBackgroundColor))
    } status: {
      StoryStatus("Saved locally", error: session.error)
      Spacer()
      Text("\(session.story.tasks.filter(\.done).count) of \(session.story.tasks.count) done")
    }.onAppear { session.start() }
  }
  private func addTask() {
    let text = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    session.update { story in
      story.tasks.append(StoryTask(id: (story.tasks.map(\.id).max() ?? 0) + 1, text: text, done: false))
    }; newTask = ""
  }
}
private struct ChecklistRow: View {
  let item: StoryTask
  let toggle: () -> Void
  var body: some View {
    Button(action: toggle) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? Color.orange : Color.secondary)
        Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? Color.secondary : Color.primary)
        Spacer(minLength: 0)
      }.font(.system(size: 18)).frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(.plain).accessibilityIdentifier("notes.task.\(item.id)")
  }
}
