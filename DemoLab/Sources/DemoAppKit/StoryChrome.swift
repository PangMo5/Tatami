// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

public struct StoryHeading: View {
  let eyebrow: String
  let title: String
  let subtitle: String
  public init(_ eyebrow: String, _ title: String, _ subtitle: String = "") {
    self.eyebrow = eyebrow; self.title = title; self.subtitle = subtitle
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.7)
      if !subtitle.isEmpty { Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

public struct StoryStatus: View {
  let text: String
  let error: String
  public init(_ text: String, error: String = "") { self.text = text; self.error = error }
  public var body: some View {
    Label(error.isEmpty ? text : error, systemImage: error.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
      .foregroundStyle(error.isEmpty ? Color.secondary : Color.red).lineLimit(1)
  }
}

public struct CopyChecksView: View {
  let checks: [CopyCheck]
  public init(_ checks: [CopyCheck]) { self.checks = checks }
  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(checks) { check in
        Label(check.title, systemImage: check.passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
          .foregroundStyle(check.passed ? Color.green : Color.orange)
          .font(.system(size: 15, weight: .medium))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
