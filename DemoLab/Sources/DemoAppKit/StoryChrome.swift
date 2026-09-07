// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

public struct StoryHeading: View {
  let eyebrow: LocalizedStringResource
  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource?
  public init(_ eyebrow: LocalizedStringResource, _ title: LocalizedStringResource, _ subtitle: LocalizedStringResource? = nil) {
    self.eyebrow = eyebrow; self.title = title; self.subtitle = subtitle
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(eyebrow).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
      Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.7)
      if let subtitle { Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

public struct StoryStatus: View {
  let text: LocalizedStringResource
  let error: String
  public init(_ text: LocalizedStringResource, error: String = "") { self.text = text; self.error = error }
  public var body: some View {
    Label {
      if error.isEmpty { Text(text) } else { Text(error) }
    } icon: { Image(systemName: error.isEmpty ? "checkmark.circle" : "exclamationmark.triangle") }
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
