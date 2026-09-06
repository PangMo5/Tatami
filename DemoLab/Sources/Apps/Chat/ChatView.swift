// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct ChatView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var message = ""
  var body: some View {
    DemoWindow {
      DemoTitle("# launch", symbol: "bubble.left.and.bubble.right", accent: .indigo, subtitle: "Team / 2 members")
      Spacer()
    } content: {
      HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 20) {
          Text("TEAM").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
          Label("launch", systemImage: "number").font(.system(size: 15, weight: .semibold))
          Label("general", systemImage: "number").foregroundStyle(.secondary)
          Spacer()
          Label("Mina", systemImage: "circle.fill").font(.system(size: 13)).foregroundStyle(.green)
        }.padding(24).frame(width: 160).background(.quaternary.opacity(0.4))
        Divider()
        VStack(spacing: 0) {
          ScrollViewReader { proxy in
            ScrollView {
              VStack(alignment: .leading, spacing: 30) {
                StoryHeading("LAUNCH / WEBSITE", "Keep the conversation here.")
                ForEach(session.story.messages) { item in ChatMessageRow(message: item).id(item.id) }
              }.padding(32).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
            }.onChange(of: session.story.messages.count) { _, _ in
              if let id = session.story.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
          }
          Divider()
          HStack {
            TextField("Message #launch", text: $message).textFieldStyle(.plain)
              .font(.system(size: 18)).accessibilityIdentifier("chat.message")
              .onSubmit { send() }
            Button("Send", systemImage: "arrow.up") { send() }
              .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("chat.send")
          }.padding(18).background(Color.indigo.opacity(0.035))
        }.background(Color(nsColor: .textBackgroundColor))
      }
    } status: {
      StoryStatus("Local demo conversation", error: session.error)
      Spacer()
      Text("\(session.story.messages.count) messages")
    }.onAppear { session.start() }
  }
  private func send() {
    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    session.update { story in
      story.messages.append(StoryMessage(id: (story.messages.map(\.id).max() ?? 0) + 1, author: "You", text: text))
    }; message = ""
  }
}
private struct ChatMessageRow: View {
  let message: StoryMessage
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(message.author == "You" ? "Y" : "M").font(.system(size: 15, weight: .semibold))
        .frame(width: 38, height: 38).background(message.author == "You" ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12), in: .rect(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 8) {
        Text(message.author).font(.system(size: 15, weight: .semibold))
        Text(message.text).font(.system(size: 18)).lineSpacing(5)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
