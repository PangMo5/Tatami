import ComposableArchitecture
import SwiftUI
import TatamiKit

/// Menu bar status item label: shows the active workspace's name + icon
/// so the bar reflects where you are, not just a static app glyph.
struct MenuBarLabel: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    // MenuBarExtra only reliably renders a single icon + title from a SwiftUI
    // label (extra `Image`s are dropped, and images inlined into a `Text`
    // don't render at all). Rasterize the composed row to a *template*
    // NSImage instead, which the menu bar then tints and highlights like any
    // status item — so we can show any mix of profile / workspace icons+names.
    Image(nsImage: renderedLabel)
  }

  @MainActor
  private var renderedLabel: NSImage {
    let renderer = ImageRenderer(content: labelContent)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let image = renderer.nsImage else { return NSImage() }
    image.isTemplate = true
    return image
  }

  @ViewBuilder
  private var labelContent: some View {
    let config = store.workspaceList.config
    let menuBar = config.settings.menuBar
    let activeId = store.activation.primaryActiveWorkspaceID
    let workspace = activeId.flatMap { config.activeProfile?.workspaces[id: $0] }
    // Profile bits only make sense with more than one profile to distinguish.
    let multiProfile = config.profiles.count > 1
    let showProfileIcon = multiProfile && menuBar.showProfileIcon
    let showProfileName = multiProfile && menuBar.showProfileName
    let profileShown = showProfileIcon || showProfileName
    let workspaceShown = menuBar.showWorkspaceIcon
      || (menuBar.showWorkspaceName && workspace?.name != nil)
    // Never render nothing — a blank menu bar item would be unclickable.
    let empty = store.errorReports.isEmpty && !profileShown && !workspaceShown

    HStack(spacing: 4) {
      // Persistent problem indicator — clears when the failure resolves or is
      // dismissed.
      if !store.errorReports.isEmpty {
        Image(systemName: "exclamationmark.triangle.fill")
      }
      if showProfileIcon {
        Image(systemName: config.activeProfile?.symbolIconName ?? "rectangle.stack")
      }
      if showProfileName, let name = config.activeProfile?.name {
        Text(name)
      }
      // Separate the profile group from the workspace group when both show.
      if profileShown, workspaceShown {
        RoundedRectangle(cornerRadius: 0.5)
          .frame(width: 1, height: 11)
          .opacity(0.35)
          .padding(.horizontal, 1)
      }
      if menuBar.showWorkspaceIcon {
        Image(systemName: workspace?.symbolIconName ?? "square.stack.3d.up.fill")
      }
      if menuBar.showWorkspaceName, let name = workspace?.name {
        Text(name)
      }
      if empty {
        Image(systemName: "square.stack.3d.up.fill")
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(.black)
  }
}

struct MenuBarContentView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let config = store.workspaceList.config
    let activeId = store.activation.primaryActiveWorkspaceID

    if !store.errorReports.isEmpty {
      Section("Problems") {
        ForEach(store.errorReports) { report in
          // Clicking a problem opens config.toml's folder — every report
          // domain so far is fixed by editing files that live there.
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([ConfigLocation.fileURL])
          } label: {
            Label(report.message, systemImage: "exclamationmark.triangle.fill")
          }
        }
        Button("Dismiss") {
          store.send(.errorReportsDismissed)
        }
      }
      Divider()
    }

    if let workspaces = config.activeProfile?.workspaces, !workspaces.isEmpty {
      let regular = workspaces.filter { $0.kind != .scratchpad }
      let scratchpads = workspaces.filter { $0.kind == .scratchpad }
      // Switchable workspaces: a Toggle renders the native trailing checkmark
      // on the active one. We swallow the off-write so re-clicking the active
      // workspace just re-activates it (matching the toolbar Activate button).
      if !regular.isEmpty {
        Section("Workspaces") {
          ForEach(regular) { workspace in
            Toggle(isOn: Binding(
              get: { workspace.id == activeId },
              set: { newValue in
                guard newValue else { return }
                store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
              }
            )) {
              Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.dashed")
            }
          }
        }
      }
      // Scratchpads are borrow-only — they never become "active", so a plain
      // button (clicking borrows onto the focused display) reads truer than a
      // Toggle, and the dedicated section header is what marks them.
      if !scratchpads.isEmpty {
        Section("Scratchpads") {
          ForEach(scratchpads) { workspace in
            Button {
              store.send(.activation(.activate(workspaceId: workspace.id, setFocus: true)))
            } label: {
              Label(workspace.name, systemImage: workspace.symbolIconName ?? "tray.full")
            }
          }
        }
      }
      Divider()
    }

    // Quick profile switcher (management — add / duplicate / rename — lives in
    // the main window). Only shown when there's more than one to pick from; the
    // active one carries the native checkmark.
    if config.profiles.count > 1 {
      Section("Profiles") {
        ForEach(config.profiles) { profile in
          Toggle(isOn: Binding(
            get: { profile.id == (config.activeProfileId ?? config.profiles.first?.id) },
            set: { on in
              guard on else { return }
              store.send(.activateProfile(profile.id))
            }
          )) {
            Label(profile.name, systemImage: profile.symbolIconName ?? "rectangle.stack")
          }
        }
      }
      Divider()
    }

    // Opens the main window (the Workspaces / Settings / About tab view).
    // ⌘, is also wired globally via the app's commands.
    Button("Settings") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)

    Button("Check for Updates…") {
      store.send(.checkForUpdatesTapped)
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
