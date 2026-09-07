// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import DemoAppKit
import SwiftUI

struct ReviewView: View {
  let context: DemoRenderContext
  @State private var session = StorySession()
  @State private var comment = ""
  var body: some View {
    DemoWindow {
      DemoTitle("Launch copy", symbol: "checkmark.bubble", accent: .purple, subtitle: "Review / Website")
      Spacer()
      Button("Check copy") { session.update { $0.checks = $0.evaluateCopy() } }
        .accessibilityIdentifier("review.check")
      Button {
        session.update { $0.approved = true }
      } label: { Text(session.story.approved ? LocalizedStringResource("Approved") : LocalizedStringResource("Approve")) }
      .disabled(session.story.checks.isEmpty || session.story.checks.contains { !$0.passed } || session.story.approved)
        .accessibilityIdentifier("review.approve")
    } content: {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          StoryHeading("READY FOR REVIEW", "A small change. A clearer idea.", "The saved draft from Editor, ready for a second look.")
          DraftPreview(headline: session.story.headline, description: session.story.body)
          if !session.story.checks.isEmpty { CopyChecksView(session.story.checks) }
          Divider()
          Text("REVIEW NOTE").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
          if !session.story.reviewComment.isEmpty {
            Label(session.story.reviewComment, systemImage: "bubble.left.fill")
              .font(.system(size: 17)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.purple.opacity(0.06), in: .rect(cornerRadius: 10))
          }
          HStack {
            TextField("Leave a review note", text: $comment).textFieldStyle(.roundedBorder)
              .accessibilityIdentifier("review.comment")
              .onSubmit { submit() }
            Button("Add note") { submit() }.disabled(comment.trimmingCharacters(in: .whitespaces).isEmpty)
              .accessibilityIdentifier("review.submit")
          }.controlSize(.large)
        }.padding(32)
      }.background(Color(nsColor: .textBackgroundColor))
    } status: {
      StoryStatus(session.story.approved ? "Approved for the launch page" : "Reviewing revision \(session.story.revision)", error: session.error)
      Spacer()
      Text("Local review")
    }.onAppear { session.start() }
  }
  private func submit() {
    let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    session.update { $0.reviewComment = text }; comment = ""
  }
}
private struct DraftPreview: View {
  let headline: String
  let description: String
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("WEBSITE PREVIEW").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      Text(headline).font(.system(size: 32, weight: .bold)).tracking(-0.6)
      Text(description).font(.system(size: 18)).foregroundStyle(.secondary).lineSpacing(5)
    }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.purple.opacity(0.045), in: .rect(cornerRadius: 14))
  }
}
