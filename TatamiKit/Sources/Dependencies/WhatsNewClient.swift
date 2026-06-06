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
public struct WhatsNewClient: Sendable {
  /// Show the post-update notes when the app version changed since the
  /// last launch. `hasExistingConfig` distinguishes an update (show) from
  /// a fresh install (record only).
  public var showIfNeeded: @Sendable (_ hasExistingConfig: Bool) async -> Void
}

extension WhatsNewClient: DependencyKey {
  public static let liveValue: WhatsNewClient = {
    @Dependency(\.screenRecording) var screenRecording
    let controller = WhatsNewController(screenRecording: screenRecording)
    return WhatsNewClient { hasExistingConfig in
      await controller.showIfNeeded(hasExistingConfig: hasExistingConfig)
    }
  }()

  public static let testValue = WhatsNewClient(showIfNeeded: { _ in })
  public static let previewValue = testValue
}

extension DependencyValues {
  public var whatsNew: WhatsNewClient {
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
  private let screenRecording: ScreenRecordingClient

  init(screenRecording: ScreenRecordingClient) {
    self.screenRecording = screenRecording
  }

  func showIfNeeded(hasExistingConfig: Bool) {
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    guard !current.isEmpty else { return }
    let lastShown = UserDefaults.standard.string(forKey: Self.lastShownKey)
    guard lastShown != current else { return }
    UserDefaults.standard.set(current, forKey: Self.lastShownKey)
    // Fresh install: no migrated config, nothing to explain.
    guard hasExistingConfig else { return }
    // Patch releases share their minor's feature wave — someone who saw
    // 1.3.0's window must not get the identical one again on 1.3.1.
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
        screenRecordingGranted: screenRecording.isGranted(),
        onGrant: { [screenRecording] in
          Task {
            await screenRecording.requestAccess()
            await screenRecording.openSettings()
          }
        },
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
  let screenRecordingGranted: Bool
  let onGrant: () -> Void
  let onDone: () -> Void

  @State private var showChangelog = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("What's New in Tatami \(version)")
          .font(.title.weight(.semibold))
        Text("This update changes a couple of things about existing setups.")
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
            icon: "square.on.square",
            title: "Floating apps are now Shared Apps",
            detail: "Your floating list was migrated automatically — `[[floatingApps]]` became `[[sharedApps]]` with `floating = true` in the config. Shared apps are part of every workspace: tiled into each layout, or floating with the Float toggle. Manage them in Workspaces → Shared Apps."
          )

          item(
            icon: "rectangle.dashed",
            title: "Floating needs Screen Recording",
            detail: screenRecordingGranted
              ? "Floating windows now stay above the tiles by mirroring them (no SIP changes). Screen Recording is already granted — you're all set."
              : "Floating windows now stay above the tiles by mirroring them, which needs the Screen Recording permission. Without it, floating windows won't stay on top."
          )
          if !screenRecordingGranted {
            HStack {
              Text("macOS applies the grant after a relaunch.")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Grant Screen Recording…", action: onGrant)
            }
            .padding(.leading, 34)
          }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      // MARK: Feature highlights
      VStack(alignment: .leading, spacing: 14) {
        Label("New", systemImage: "sparkles")
          .font(.headline)

        item(
          icon: "macwindow.on.rectangle",
          title: "Floating windows, no SIP required",
          detail: "Float any app per workspace or everywhere. Reach for a floating window and the real one is handed back to you; focused floats stack above the rest."
        )
        item(
          icon: "keyboard",
          title: "Shared shortcuts & per-action HUD",
          detail: "Hotkeys for shared floating and Shared Apps membership (Settings → Shortcuts). The HUD now confirms floats, membership, pause, fullscreen, and balance — each toggleable, with a configurable duration."
        )
        item(
          icon: "sidebar.left",
          title: "Settings, reorganized",
          detail: "A System Settings-style sidebar, plus a Screen Recording permission row under General → Permissions."
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
