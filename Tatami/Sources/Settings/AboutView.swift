// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI
import TatamiKit

// MARK: - AboutView

/// Standalone About pane: app identity, credits, and open-source
/// acknowledgements. Shown as its own tab alongside Settings.
struct AboutView: View {

  // MARK: Internal

  var body: some View {
    Form {
      Section {
        HStack(spacing: 14) {
          if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
              .resizable()
              .frame(width: 56, height: 56)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text("Tatami")
              .font(.title2.weight(.semibold))
            Text("macOS workspace manager with BSP window tiling")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
      }

      Section("About") {
        LabeledContent("Version", value: Self.appVersion)
        LabeledContent("Created by") {
          Link("PangMo5", destination: URL(string: "https://github.com/PangMo5")!)
        }
        Link("Source Code", destination: URL(string: "https://github.com/PangMo5/Tatami")!)
        Button("View Changelog…") { showChangelog = true }
          .buttonStyle(.link)
      }

      Section("Inspired by") {
        creditLink("FlashSpace by Wojciech Kulik", "https://github.com/wojciech-kulik/FlashSpace")
        creditLink("yabai by koekeishiya", "https://github.com/koekeishiya/yabai")
      }

      Section("Legal") {
        LabeledContent("Copyright", value: "© 2026 PangMo5 and contributors")
        Text(
          "This program comes with no warranty. You may redistribute it under the GNU AGPL v3. Select License for details."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach(LegalDocument.allCases) { document in
          Button {
            presentedDocument = document
          } label: {
            Text(document.title)
          }
          .buttonStyle(.link)
        }
      }

      Section("Built with") {
        ForEach(Self.acknowledgements, id: \.name) { item in
          creditLink(item.name, item.url)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 460, minHeight: 520)
    .sheet(isPresented: $showChangelog) {
      ChangelogView()
    }
    .sheet(item: $presentedDocument) { document in
      LegalDocumentView(document: document)
    }
  }

  // MARK: Private

  /// Open-source dependencies credited in the About pane.
  private static let acknowledgements: [(name: String, url: String)] = [
    ("The Composable Architecture", "https://github.com/pointfreeco/swift-composable-architecture"),
    ("swift-sharing", "https://github.com/pointfreeco/swift-sharing"),
    ("swift-perception", "https://github.com/pointfreeco/swift-perception"),
    ("swift-collections", "https://github.com/apple/swift-collections"),
    ("Magnet", "https://github.com/Clipy/Magnet"),
    ("swift-toml", "https://github.com/mattt/swift-toml"),
    ("swift-yyjson", "https://github.com/mattt/swift-yyjson"),
    ("SFSafeSymbols", "https://github.com/SFSafeSymbols/SFSafeSymbols"),
    ("swift-argument-parser", "https://github.com/apple/swift-argument-parser"),
    ("Sparkle", "https://github.com/sparkle-project/Sparkle"),
  ]

  /// Marketing version + build number from the app bundle, e.g. "0.1.0 (42)".
  private static let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(short) (\(build))"
  }()

  @State private var showChangelog = false
  @State private var presentedDocument: LegalDocument?

  private func creditLink(_ title: String, _ urlString: String) -> some View {
    Link(title, destination: URL(string: urlString)!)
  }

}

// MARK: - LegalDocument

/// A legal document shipped in the app bundle and presented without relying on
/// Launch Services or an external text editor.
private enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
  case license
  case projectNotices
  case thirdPartyNotices

  // MARK: Internal

  var id: Self {
    self
  }

  var title: LocalizedStringResource {
    switch self {
    case .license: "License (AGPL-3.0-only)"
    case .projectNotices: "Project Notices"
    case .thirdPartyNotices: "Third-Party Notices"
    }
  }

  func loadContents() async throws -> String {
    let resource = resource
    guard
      let url = Bundle.main.url(
        forResource: resource.name,
        withExtension: resource.extension,
      )
    else {
      throw CocoaError(.fileNoSuchFile)
    }

    return try await Task.detached(priority: .userInitiated) {
      try String(contentsOf: url, encoding: .utf8)
    }.value
  }

  // MARK: Private

  private var resource: (name: String, extension: String?) {
    switch self {
    case .license: ("LICENSE", nil)
    case .projectNotices: ("NOTICE", "md")
    case .thirdPartyNotices: ("THIRD_PARTY_NOTICES", "md")
    }
  }
}

// MARK: - LegalDocumentView

private struct LegalDocumentView: View {

  // MARK: Internal

  let document: LegalDocument

  var body: some View {
    NavigationStack {
      Group {
        if let contents {
          ScrollView {
            Text(contents)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
        } else if let loadErrorMessage {
          ContentUnavailableView(
            "Unable to Open Document",
            systemImage: "doc.badge.exclamationmark",
            description: Text(loadErrorMessage),
          )
        } else {
          ProgressView("Loading document…")
        }
      }
      .navigationTitle(Text(document.title))
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .frame(minWidth: 680, minHeight: 520)
    .task(id: document.id) {
      do {
        contents = try await document.loadContents()
      } catch {
        loadErrorMessage = error.localizedDescription
      }
    }
  }

  // MARK: Private

  @Environment(\.dismiss) private var dismiss
  @State private var contents: String?
  @State private var loadErrorMessage: String?

}
