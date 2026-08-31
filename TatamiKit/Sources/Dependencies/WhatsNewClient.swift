// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import SwiftUI

// MARK: - WhatsNewClient

/// One-time "What's New" window shown on the first launch after an update.
/// Keeps the release's main feature highlights scannable, with the full
/// bundled changelog one click away.
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

// MARK: DependencyKey

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

// MARK: - WhatsNewController

@MainActor
private final class WhatsNewController {

  // MARK: Internal

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
      defer: false,
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
        },
      )
    )
    window.setContentSize(NSSize(width: 540, height: 600))
    window.center()
    self.window = window
    // LSUIElement app: bring the notes forward explicitly.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  // MARK: Private

  private static let lastShownKey = "whatsNew.lastShownVersion"

  private var window: NSWindow?

  /// "1.3.1" → "1.3" — the granularity at which What's New content exists.
  private func majorMinor(_ version: String) -> String {
    version.split(separator: ".").prefix(2).joined(separator: ".")
  }

}

// MARK: - WhatsNewView

/// Notes for the *current* release — update alongside each version whose
/// changes deserve a first-launch heads-up.
private struct WhatsNewView: View {

  // MARK: Internal

  let version: String
  let onDone: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("What's New in Tatami \(version)")
              .font(.title.weight(.semibold))
            Text(
              """
              Tatami 1.12 adds scriptable control and lifecycle hooks, plus safer, more selective profile and \
              workspace duplication.
              """
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
          }

          // MARK: Feature highlights
          VStack(alignment: .leading, spacing: 14) {
            Label("New", systemImage: "sparkles")
              .font(.headline)

            item(
              icon: "terminal",
              title: "Control Tatami from the command line",
              detail: """
                Use domain commands for profiles, workspaces, windows, displays, layouts, and apps, with stable JSON \
                output and every action available to trackpad gestures.
                """,
            )
            item(
              icon: "bolt.circle",
              title: "Run programs on lifecycle events",
              detail: """
                Create and test hooks for Tatami launch, profile changes, and workspaces becoming visible on a \
                display. Each event includes versioned JSON and useful environment variables.
                """,
            )
            item(
              icon: "square.on.square",
              title: "Choose what Duplicate keeps",
              detail: """
                Right-click a profile or workspace, review its workspaces, apps, settings, and saved layouts, then \
                include only what you want.
                """,
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

  // MARK: Private

  @State private var showChangelog = false

  private func item(
    icon: String,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        let localizedDetail = String(localized: detail)
        Text(
          (try? AttributedString(markdown: localizedDetail))
            ?? AttributedString(localizedDetail)
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

}
