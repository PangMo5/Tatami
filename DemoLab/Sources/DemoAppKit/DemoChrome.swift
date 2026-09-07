// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - Accent bridging

extension Color {
  public init(_ accent: DemoAccent) {
    self.init(.sRGB, red: accent.red, green: accent.green, blue: accent.blue, opacity: 1)
  }
}

// MARK: - DemoWindow

/// The standard three-band layout every demo app uses: a toolbar, the content,
/// and an optional status bar.
///
/// The look is deliberately plain — system materials, semantic colors, system
/// typography, SF Symbols. No gradients, no glass, no marketing flourishes:
/// these windows have to read as ordinary macOS productivity apps in a frame
/// that is on screen for one second.
public struct DemoWindow<Toolbar: View, Content: View, Status: View>: View {

  // MARK: Lifecycle

  public init(
    @ViewBuilder toolbar: () -> Toolbar,
    @ViewBuilder content: () -> Content,
    @ViewBuilder status: () -> Status
  ) {
    self.toolbar = toolbar()
    self.content = content()
    self.status = status()
  }

  // MARK: Public

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) { toolbar }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
      Divider()
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if !(status is EmptyView) {
        Divider()
        HStack(spacing: 14) { status }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 14)
          .frame(height: 26)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.bar)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("demolab.window.content")
  }

  // MARK: Private

  private let toolbar: Toolbar
  private let content: Content
  private let status: Status

}

extension DemoWindow where Status == EmptyView {
  public init(
    @ViewBuilder toolbar: () -> Toolbar,
    @ViewBuilder content: () -> Content
  ) {
    self.init(toolbar: toolbar, content: content, status: { EmptyView() })
  }
}

// MARK: - DemoTitle

/// Toolbar title with the app's symbol, matching the window title.
public struct DemoTitle: View {

  // MARK: Lifecycle

  public init(_ text: LocalizedStringResource, symbol: String, accent: DemoAccent, subtitle: LocalizedStringResource? = nil) {
    self.text = text
    self.symbol = symbol
    self.accent = accent
    self.subtitle = subtitle
  }

  // MARK: Public

  public var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color(accent))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(text)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.primary)
        if let subtitle {
          Text(subtitle)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: Private

  private let text: LocalizedStringResource
  private let symbol: String
  private let accent: DemoAccent
  private let subtitle: LocalizedStringResource?

}
