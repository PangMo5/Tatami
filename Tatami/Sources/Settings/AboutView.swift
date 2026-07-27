import AppKit
import SwiftUI
import TatamiKit

/// Standalone About pane: app identity, credits, and open-source
/// acknowledgements. Shown as its own tab alongside Settings.
struct AboutView: View {
  @State private var showChangelog = false

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
        Link("GitHub", destination: URL(string: "https://github.com/PangMo5/Tatami")!)
        Button("View Changelog…") { showChangelog = true }
          .buttonStyle(.link)
      }

      Section("Inspired by") {
        creditLink("FlashSpace by Wojciech Kulik", "https://github.com/wojciech-kulik/FlashSpace")
        creditLink("yabai by koekeishiya", "https://github.com/koekeishiya/yabai")
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
  }

  private func creditLink(_ title: String, _ urlString: String) -> some View {
    Link(title, destination: URL(string: urlString)!)
  }

  /// Open-source dependencies credited in the About pane.
  private static let acknowledgements: [(name: String, url: String)] = [
    ("The Composable Architecture", "https://github.com/pointfreeco/swift-composable-architecture"),
    ("swift-sharing", "https://github.com/pointfreeco/swift-sharing"),
    ("swift-perception", "https://github.com/pointfreeco/swift-perception"),
    ("swift-collections", "https://github.com/apple/swift-collections"),
    ("Magnet", "https://github.com/Clipy/Magnet"),
    ("swift-toml", "https://github.com/mattt/swift-toml"),
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
}
