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
      VStack(alignment: .leading, spacing: 4) {
        Text("What's New in Tatami \(version)")
          .font(.title.weight(.semibold))
        Text("Per-app layout gains a third mode — and one config field changed shape.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      // MARK: Changes that touch existing setups
      GroupBox {
        VStack(alignment: .leading, spacing: 14) {
          Label("Changes to your setup", systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.orange)

          item(
            icon: "doc.plaintext",
            title: "App layout is a mode now, not a switch",
            detail: "Each assigned app and shared app now carries a `layout` of `tiled`, `floating`, or `unmanaged` instead of a `floating = true/false` flag. Your existing config migrates automatically. If you hand-edit `config.toml`, use `layout = \"floating\"` (or `\"tiled\"` / `\"unmanaged\"`) — and note that an older Tatami doesn't understand the new key, so downgrading would read every app as tiled."
          )
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      // MARK: Feature highlights
      VStack(alignment: .leading, spacing: 14) {
        Label("New", systemImage: "sparkles")
          .font(.headline)

        item(
          icon: "rectangle.slash",
          title: "Ignore tiling (unmanaged apps)",
          detail: "A third per-app mode beside Tiled and Float: keep an app as a full workspace member — auto-open, show/hide, focus-follows-mouse, window cycling — but leave its window exactly where it is. No tile, no mirror, no Screen Recording. Pick Tiled / Float / Ignore on any app in a workspace or in Shared Apps."
        )
        item(
          icon: "macwindow.badge.plus",
          title: "Workspaces remember your last window",
          detail: "Switching to a workspace (when no app is pinned for focus) now returns you to the exact window you last used there — not a fixed app."
        )
        item(
          icon: "arrow.left.arrow.right",
          title: "Cycle through every window",
          detail: "The next/previous-window shortcuts walk all visible windows in the workspace, including multiple windows of the same app."
        )
        item(
          icon: "magnifyingglass",
          title: "Add apps by search or from disk",
          detail: "The app picker searches running apps and can add one straight from a file."
        )
      }
      .padding(.horizontal, 6)

      Spacer(minLength: 0)

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
