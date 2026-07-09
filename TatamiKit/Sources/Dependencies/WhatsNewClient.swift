import AppKit
import Dependencies
import DependenciesMacros
import SwiftUI

/// One-time "What's New" window shown on the first launch after an
/// update. Two sections: changes that touch existing setups (config
/// migrations, new permissions) get a highlighted box up top; feature
/// highlights follow, with the full bundled changelog one click away.
///
/// Gated on the bundle version vs the last version that showed notes
/// (UserDefaults, app-local state — deliberately not in the dotfiles
/// config). Fresh installs record the version silently: nothing was
/// migrated, so there is nothing to explain.
@DependencyClient
struct WhatsNewClient: Sendable {
  /// Show the post-update notes when the app version changed since the
  /// last launch. `hasExistingConfig` distinguishes an update (show) from
  /// a fresh install (record only).
  var showIfNeeded: @Sendable (_ hasExistingConfig: Bool) async -> Void
}

extension WhatsNewClient: DependencyKey {
  static let liveValue: WhatsNewClient = {
    let controller = WhatsNewController()
    return WhatsNewClient { hasExistingConfig in
      await controller.showIfNeeded(hasExistingConfig: hasExistingConfig)
    }
  }()

  static let testValue = WhatsNewClient(showIfNeeded: { _ in })
  static let previewValue = testValue
}

extension DependencyValues {
  var whatsNew: WhatsNewClient {
    get { self[WhatsNewClient.self] }
    set { self[WhatsNewClient.self] = newValue }
  }
}

@MainActor
private final class WhatsNewController {
  private static let lastShownKey = "whatsNew.lastShownVersion"

  /// "1.3.1" → "1.3" — the granularity at which What's New content exists.
  private func majorMinor(_ version: String) -> String {
    version.split(separator: ".").prefix(2).joined(separator: ".")
  }
  private var window: NSWindow?

  func showIfNeeded(hasExistingConfig: Bool) {
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    guard !current.isEmpty else { return }
    let lastShown = UserDefaults.standard.string(forKey: Self.lastShownKey)
    guard lastShown != current else { return }
    UserDefaults.standard.set(current, forKey: Self.lastShownKey)
    // Fresh install: no migrated config, nothing to explain.
    guard hasExistingConfig else { return }
    // Patch releases share their minor's feature wave — someone who saw
    // 1.4.0's window must not get the identical one again on 1.4.1.
    if let lastShown, majorMinor(lastShown) == majorMinor(current) { return }

    let window = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.level = .floating
    window.contentView = NSHostingView(
      rootView: WhatsNewView(
        version: current,
        onDone: { [weak self] in
          self?.window?.close()
          self?.window = nil
        }
      )
    )
    window.setContentSize(NSSize(width: 540, height: 600))
    window.center()
    self.window = window
    // LSUIElement app: bring the notes forward explicitly.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
}

/// Notes for the *current* release — update alongside each version whose
/// changes deserve a first-launch heads-up.
private struct WhatsNewView: View {
  let version: String
  let onDone: () -> Void

  @State private var showChangelog = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("What's New in Tatami \(version)")
          .font(.title.weight(.semibold))
        Text("See and edit each workspace's tile layout right in its settings — live.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      // MARK: Breaking changes
      VStack(alignment: .leading, spacing: 6) {
        Label("Breaking Changes", systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline.weight(.semibold))
        Text("The per-workspace \u{201C}session only\u{201D} tiling-memory option is gone — every workspace now keeps its layout across restarts. Configs that set it still load fine; the setting is simply ignored.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))

      // MARK: Feature highlights
      VStack(alignment: .leading, spacing: 14) {
        Label("New", systemImage: "sparkles")
          .font(.headline)

        item(
          icon: "rectangle.split.2x2",
          title: "Layout preview & editor",
          detail: "Every workspace's settings now open with a live graphic of its tiles. Drag a divider to resize, drag a tile onto another to move it (edge to split, center to swap), and rotate, mirror, balance, or flip a tile's orientation. Fullscreen windows sit in their own band you can drag in and out of. It works on **inactive** workspaces too — edits apply next time you switch to them."
        )
        item(
          icon: "macwindow.on.rectangle",
          title: "Same-app windows keep their spot",
          detail: "Two windows of one app now hold distinct, arrangeable tiles (and remember which was fullscreen) instead of collapsing together. Layout memory is hardened too: one bad entry no longer resets everything, and older layouts migrate automatically."
        )
        item(
          icon: "display.2",
          title: "Displays restore on reconnect",
          detail: "Replug a monitor and the workspace that lived on it comes back — a pinned workspace reclaims its screen, otherwise the monitor restores its most-recent one. Moving a workspace between monitors also refills the one it left, and cross-display moves now size correctly."
        )
        item(
          icon: "line.3.horizontal",
          title: "Reorder by dragging, confirm before deleting",
          detail: "Drag workspaces and scratchpads to reorder them in the sidebar. Deleting a workspace or removing an app now asks first."
        )
      }
      .padding(.horizontal, 6)
        }
      }

      HStack {
        Button("View Full Changelog…") { showChangelog = true }
        Spacer()
        Button("Done", action: onDone)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 540, height: 600, alignment: .topLeading)
    .sheet(isPresented: $showChangelog) {
      ChangelogView()
    }
  }

  private func item(icon: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text((try? AttributedString(markdown: detail)) ?? AttributedString(detail))
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
