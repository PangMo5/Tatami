// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct EditorView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var headline = LaunchStory().headline
  @State private var description = LaunchStory().body
  var body: some View {
    DemoWindow {
      DemoTitle("Launch page", symbol: "doc.text", accent: .blue, subtitle: "Copy / Draft")
      Spacer()
      Button("Save") {
        session.update { story in
          story.headline = headline; story.body = description
          story.revision += 1; story.approved = false; story.checks = []
        }
      }.keyboardShortcut("s").accessibilityIdentifier("editor.save")
    } content: {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          StoryHeading("WEBSITE / LAUNCH", "Make room for better work.", "A short introduction for people meeting the product for the first time.")
          DraftFields(headline: $headline, description: $description)
          Divider()
          HStack {
            Label("Plain language", systemImage: "text.bubble")
            Spacer()
            Label("One clear idea", systemImage: "scope")
          }.font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(32)
      }.background(Color(nsColor: .textBackgroundColor))
    } status: {
      StoryStatus(headline == session.story.headline && description == session.story.body ? "All changes saved" : "Unsaved changes", error: session.error)
      Spacer()
      Text("Revision \(session.story.revision)")
    }
    .onAppear {
      session.start(); headline = session.story.headline; description = session.story.body
    }
  }
}

private struct DraftFields: View {
  @Binding var headline: String
  @Binding var description: String
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("HEADLINE").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        Spacer()
        Text("\(headline.count) / 40").font(.system(size: 12, design: .monospaced))
          .foregroundStyle(headline.count > 40 ? Color.orange : Color.secondary)
      }
      TextField("Headline", text: $headline, axis: .vertical)
        .textFieldStyle(.plain).font(.system(size: 28, weight: .semibold))
        .padding(16).background(Color.blue.opacity(0.045), in: .rect(cornerRadius: 10))
        .accessibilityIdentifier("editor.headline")
      Text("DESCRIPTION").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 14)
      TextEditor(text: $description).font(.system(size: 18)).lineSpacing(6)
        .scrollContentBackground(.hidden).frame(minHeight: 185)
        .accessibilityIdentifier("editor.description")
    }
  }
}
