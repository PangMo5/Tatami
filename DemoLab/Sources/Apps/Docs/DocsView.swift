// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct DocsView: View {
  let context: DemoRenderContext
  @State private var page = "brief"
  @State private var query = ""
  var body: some View {
    DemoWindow {
      DemoTitle("Launch brief", symbol: "book.closed", accent: .teal, subtitle: "Reference")
      Spacer()
      TextField("Find in brief", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 170)
        .accessibilityIdentifier("docs.search")
    } content: {
      HStack(spacing: 0) {
        BriefSidebar(page: $page)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 30) {
            if !query.isEmpty && !"headline short content 40 characters calmer work description screenshot".localizedCaseInsensitiveContains(query) {
              StoryHeading("SEARCH", "No matches.", "Try headline, content, or screenshot.")
            } else if page == "brief" && query.isEmpty {
              StoryHeading("PROJECT / LAUNCH", "A calmer way to work.", "The product should feel useful before it feels complicated.")
              BriefSection("01", "Who is this for?", "People who switch between writing, reviewing and talking to their team. Their tools change with the task.")
              BriefSection("02", "What should they understand?", "A workspace brings together the apps and layout for one task. Switch away, then return to the place you left.")
              BriefSection("03", "What should we show?", "A real piece of work moving from draft to review. Keep the tools visible and let the workflow explain itself.")
            } else {
              StoryHeading("CONTENT / DIRECTION", "Say one thing clearly.", "A short headline, followed by a concrete explanation.")
              BriefSection("01", "Keep it short", "Use no more than 40 characters. Lead with the benefit, then explain workspaces in the description.")
              VStack(alignment: .leading, spacing: 12) {
                Text("SUGGESTED HEADLINE").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("A calmer way to work.").font(.system(size: 27, weight: .semibold))
              }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.teal.opacity(0.08), in: .rect(cornerRadius: 12))
              BriefSection("02", "Show the result", "Let readers see the draft, the review and the saved layout. A quiet moment of real work says more than a list of shortcuts.")
              BriefSection("03", "Before you share", "Check the copy, request a review, and add one clear product screenshot.")
            }
          }.padding(30)
        }.accessibilityIdentifier("docs.article").background(Color(nsColor: .textBackgroundColor))
      }
    } status: {
      StoryStatus("Launch brief / Team reference")
      Spacer()
      Text(page == "brief" && query.isEmpty ? "Overview" : "Content direction")
    }.onAppear { if context.ordinal % 2 == 1 { page = "content" } }
  }
}
private struct BriefSidebar: View {
  @Binding var page: String
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("REFERENCE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
      Button { page = "brief" } label: { Label("Overview", systemImage: "doc.text") }
        .accessibilityIdentifier("docs.overview")
      Button { page = "content" } label: { Label("Content", systemImage: "text.alignleft") }
        .accessibilityIdentifier("docs.content")
      Spacer()
    }.buttonStyle(.plain).font(.system(size: 14)).padding(18)
      .frame(width: 145).frame(maxHeight: .infinity).background(.quaternary.opacity(0.4))
  }
}
private struct BriefSection: View {
  let number: String; let title: String; let text: String
  init(_ number: String, _ title: String, _ text: String) { self.number = number; self.title = title; self.text = text }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(number)  /  \(title)").font(.system(size: 19, weight: .semibold))
      Text(text).font(.system(size: 16)).foregroundStyle(.secondary).lineSpacing(5)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
