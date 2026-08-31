// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI
import TatamiKit

// MARK: - OnboardingSection

struct OnboardingSection<Content: View>: View {

  // MARK: Lifecycle

  init(
    title: LocalizedStringResource,
    subtitle: LocalizedStringResource? = nil,
    @ViewBuilder content: () -> Content,
  ) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  // MARK: Internal

  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.primary.opacity(0.075))
    }
  }

}

// MARK: - OnboardingPhilosophyCard

struct OnboardingPhilosophyCard: View {
  let icon: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 38, height: 38)
        .background(Color.accentColor.opacity(0.11), in: .rect(cornerRadius: 10))
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(17)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .strokeBorder(Color.primary.opacity(0.07))
    }
  }
}

// MARK: - OnboardingRecommendationCallout

struct OnboardingRecommendationCallout: View {

  // MARK: Lifecycle

  init(_ text: LocalizedStringResource) {
    self.text = text
  }

  // MARK: Internal

  let text: LocalizedStringResource

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color.accentColor)
        .frame(width: 3)
      Image(systemName: "lightbulb.max.fill")
        .foregroundStyle(.yellow)
      VStack(alignment: .leading, spacing: 4) {
        Text("Why Tatami recommends this")
          .font(.callout.weight(.semibold))
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 13)
    .padding(.horizontal, 15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.055), in: .rect(cornerRadius: 13))
  }

}

// MARK: - OnboardingInlineNotice

struct OnboardingInlineNotice: View {
  let icon: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let tint: Color
  let buttonTitle: LocalizedStringResource?
  let action: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let buttonTitle {
        Button(buttonTitle, action: action)
      }
    }
    .padding(15)
    .background(tint.opacity(0.075), in: .rect(cornerRadius: 13))
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder(tint.opacity(0.18))
    }
  }
}

// MARK: - OnboardingPermissionRow

struct OnboardingPermissionRow: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let granted: Bool
  let buttonTitle: LocalizedStringResource?
  let action: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.title3)
        .foregroundStyle(granted ? .green : .orange)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let buttonTitle {
        Button(buttonTitle, action: action)
      }
    }
  }
}

// MARK: - OnboardingWorkspaceEditorRow

struct OnboardingWorkspaceEditorRow: View {

  // MARK: Internal

  let workspace: Workspace
  let displays: [DisplayName]
  let canDelete: Bool
  let switchModifiers: String
  let assignModifiers: String
  let borrowModifiers: String
  let onNameChanged: (String) -> Void
  let onKeyChanged: (String) -> Void
  let onDisplayChanged: (DisplayName?) -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(spacing: 10) {
        Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
          .foregroundStyle(.tint)
          .frame(width: 24)
        TextField(
          "Workspace name",
          text: Binding(
            get: { workspace.name },
            set: { onNameChanged($0) },
          ),
        )
        Button(role: .destructive, action: onDelete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(!canDelete)
      }

      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Workspace shortcut")
            .font(.caption.weight(.semibold))
          TextField(
            "–",
            text: Binding(
              get: { workspace.keyEquivalent ?? "" },
              set: { onKeyChanged($0) },
            ),
          )
          .multilineTextAlignment(.center)
          .frame(width: 48)
        }

        Spacer(minLength: 8)

        VStack(alignment: .leading, spacing: 6) {
          Text("Preferred display")
            .font(.caption.weight(.semibold))
          Picker(
            "Preferred display",
            selection: Binding(
              get: { workspace.displayHint },
              set: { onDisplayChanged($0) },
            ),
          ) {
            Text("Dynamic").tag(DisplayName?.none)
            ForEach(displays, id: \.self) { display in
              Text(display.name).tag(DisplayName?.some(display))
            }
          }
          .labelsHidden()
          .frame(width: 168)
        }
      }

      if let key = workspace.keyEquivalent?.uppercased(), !key.isEmpty {
        HStack(spacing: 8) {
          shortcutMeaning("Switch", symbols: switchModifiers + key)
          shortcutMeaning("Assign", symbols: assignModifiers + key)
          shortcutMeaning("Borrow", symbols: borrowModifiers + key)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 14)
    .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(Color.primary.opacity(0.07))
    }
  }

  // MARK: Private

  private func shortcutMeaning(_ title: LocalizedStringResource, symbols: String) -> some View {
    HStack(spacing: 5) {
      Text(title)
        .foregroundStyle(.secondary)
      Text(symbols)
        .font(.caption.monospaced().weight(.semibold))
    }
    .font(.caption2)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.primary.opacity(0.045), in: .capsule)
  }

}

// MARK: - OnboardingAppGroup

struct OnboardingAppGroup: View {

  // MARK: Internal

  let title: String
  let icon: String
  let tint: Color
  let apps: [MacApp]
  let emptyMessage: LocalizedStringResource
  let workspaces: [Workspace]
  let destination: (MacApp) -> OnboardingAppDestination
  let onDestinationChanged: (MacApp, OnboardingAppDestination) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .foregroundStyle(tint)
        Text(title)
          .font(.callout.weight(.semibold))
        Text("\(apps.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
      }
      if apps.isEmpty {
        Text(emptyMessage)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.vertical, 4)
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
          ForEach(apps, id: \.bundleIdentifier) { app in
            OnboardingAppDestinationMenu(
              app: app,
              destination: destination(app),
              workspaces: workspaces,
              onDestinationChanged: { onDestinationChanged(app, $0) },
            )
          }
        }
      }
    }
    .padding(15)
    .background(tint.opacity(0.045), in: .rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(tint.opacity(0.14))
    }
  }

  // MARK: Private

  private let columns = [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10)]

}

// MARK: - OnboardingAppDestinationMenu

private struct OnboardingAppDestinationMenu: View {

  // MARK: Internal

  let app: MacApp
  let destination: OnboardingAppDestination
  let workspaces: [Workspace]
  let onDestinationChanged: (OnboardingAppDestination) -> Void

  var body: some View {
    Menu {
      Button {
        onDestinationChanged(.unassigned)
      } label: {
        destinationLabel(
          String(localized: "Not managed"),
          selected: destination == .unassigned
        )
      }
      Button {
        onDestinationChanged(.shared)
      } label: {
        destinationLabel(
          String(localized: "Shared Apps"),
          selected: destination == .shared
        )
      }
      Divider()
      ForEach(workspaces) { workspace in
        Button {
          onDestinationChanged(.workspace(workspace.id))
        } label: {
          destinationLabel(workspace.name, selected: destination == .workspace(workspace.id))
        }
      }
    } label: {
      HStack(spacing: 9) {
        AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
          .frame(width: 27, height: 27)
        Text(app.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 4)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.callout)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.primary.opacity(0.07))
      }
    }
    .menuStyle(.borderlessButton)
    .help(app.bundleIdentifier)
  }

  // MARK: Private

  private func destinationLabel(
    _ title: String,
    selected: Bool
  ) -> some View {
    Label(title, systemImage: selected ? "checkmark" : "circle")
  }

}

// MARK: - OnboardingShortcutCard

struct OnboardingShortcutCard: View {
  let title: LocalizedStringResource
  let symbols: String
  let detail: LocalizedStringResource

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Text(symbols)
          .font(.title3.monospaced())
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 7))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.primary.opacity(0.07))
    }
  }
}

// MARK: - OnboardingShortcutPracticeRow

struct OnboardingShortcutPracticeRow: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let action: HotKeyAction
  let hotKey: HotKey?
  let config: AppConfig
  let lastShortcut: HotKeyAction?
  let onRecordingChanged: (Bool) -> Void
  let onChange: (HotKey?) -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: lastShortcut == action ? "checkmark.circle.fill" : "command")
        .font(.title3)
        .foregroundStyle(lastShortcut == action ? Color.green : Color.accentColor)
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      ShortcutRecorder(
        hotKey: hotKey,
        accessibilityLabel: title,
        conflict: { config.shortcutConflict(for: $0, excluding: action) },
        onRecordingChanged: onRecordingChanged,
        onChange: onChange,
      )
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          lastShortcut == action ? Color.green.opacity(0.5) : Color.primary.opacity(0.06)
        )
    }
    .animation(.easeInOut(duration: 0.18), value: lastShortcut)
  }
}

// MARK: - OnboardingWorkspaceContextPicker

struct OnboardingWorkspaceContextPicker: View {
  var label: LocalizedStringResource = "Workspace"
  let workspaces: [OnboardingWorkspaceAppGroup]
  let selectedID: Workspace.ID?
  let onSelect: (Workspace.ID) -> Void

  var body: some View {
    HStack(spacing: 14) {
      Picker(
        label,
        selection: Binding(
          get: { selectedID },
          set: { if let id = $0 { onSelect(id) } },
        ),
      ) {
        ForEach(workspaces) { group in
          Text(group.workspace.name)
            .tag(Workspace.ID?.some(group.id))
        }
      }
      .frame(maxWidth: 280)

      if let group = workspaces.first(where: { $0.id == selectedID }) {
        if group.workspace.kind == .scratchpad {
          Label("One-app quick access", systemImage: "tray.full")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
        }
        HStack(spacing: -5) {
          ForEach(group.apps.prefix(5), id: \.bundleIdentifier) { app in
            AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
              .frame(width: 28, height: 28)
              .background(.background, in: .circle)
              .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
          }
        }
        Text(group.apps.isEmpty ? "No assigned apps" : "\(group.apps.count) assigned")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(14)
    .background(Color.accentColor.opacity(0.055), in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.accentColor.opacity(0.16))
    }
  }
}

// MARK: - OnboardingRoleBlueprintGallery

/// Shows activity-shaped examples before a fresh draft has enough meaning to
/// preview. These are teaching blueprints only; they never mutate the draft.
struct OnboardingRoleBlueprintGallery: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 12) {
      OnboardingDemoControlPanel(
        title: "Explore a role-shaped starting point",
        detail: "Pick the closest example. Notice that contexts follow recurring activities—not broad app categories. Nothing here is applied to your draft.",
      ) {
        VStack(alignment: .leading, spacing: 9) {
          Picker("Example role", selection: $selectedRole) {
            ForEach(OnboardingRoleBlueprint.allCases) { role in
              Text(role.title).tag(role)
            }
          }
          .pickerStyle(.segmented)
          Text(selectedRole.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      OnboardingDemoMonitor(
        title: selectedRole.exampleTitle,
        status: String(localized: "Blueprint · not applied"),
      ) {
        OnboardingRoleBlueprintMap(role: selectedRole)
      }
    }
  }

  // MARK: Private

  @State private var selectedRole = OnboardingRoleBlueprint.software

}

// MARK: - OnboardingRoleBlueprint

private enum OnboardingRoleBlueprint: String, CaseIterable, Identifiable {
  case software
  case design
  case product
  case research

  // MARK: Internal

  var id: String {
    rawValue
  }

  var title: LocalizedStringResource {
    switch self {
    case .software: "Software"
    case .design: "Design"
    case .product: "Product"
    case .research: "Research"
    }
  }

  var summary: LocalizedStringResource {
    switch self {
    case .software:
      "Separate making a change from reviewing one. Keep a one-app terminal check temporary."
    case .design:
      "Separate focused creation from collaborative critique. Keep quick capture lightweight."
    case .product:
      "Separate planning from discovery so meetings and evidence do not become one giant context."
    case .research:
      "Separate collecting sources from writing conclusions. Keep lookup tools temporary."
    }
  }

  var exampleTitle: String {
    switch self {
    case .software: String(localized: "Software example")
    case .design: String(localized: "Design example")
    case .product: String(localized: "Product example")
    case .research: String(localized: "Research example")
    }
  }

  var contexts: [OnboardingRoleContext] {
    switch self {
    case .software:
      [
        .init(
          id: "software-build",
          title: "Build",
          detail: "Implement and run one change",
          icon: "hammer.fill",
          apps: [
            .init(id: "ide", name: "IDE", icon: "chevron.left.forwardslash.chevron.right"),
            .init(id: "simulator", name: "Simulator", icon: "iphone"),
            .init(id: "terminal", name: "Terminal", icon: "terminal"),
          ],
        ),
        .init(
          id: "software-review",
          title: "Review",
          detail: "Inspect code and coordinate feedback",
          icon: "checkmark.bubble.fill",
          apps: [
            .init(id: "browser", name: "Browser", icon: "safari"),
            .init(id: "git", name: "Git client", icon: "point.3.connected.trianglepath.dotted"),
            .init(id: "team", name: "Team chat", icon: "bubble.left.and.bubble.right"),
          ],
        ),
        .init(
          id: "software-quick",
          title: "Quick terminal",
          detail: "One app · borrow only",
          icon: "tray.full.fill",
          apps: [.init(id: "quick-terminal", name: "Terminal", icon: "terminal")],
          isQuickAccess: true,
        ),
      ]

    case .design:
      [
        .init(
          id: "design-create",
          title: "Create",
          detail: "Shape one interface or visual",
          icon: "paintpalette.fill",
          apps: [
            .init(id: "canvas", name: "Design canvas", icon: "scribble.variable"),
            .init(id: "assets", name: "Assets", icon: "photo.stack"),
            .init(id: "reference", name: "Browser", icon: "safari"),
          ],
        ),
        .init(
          id: "design-critique",
          title: "Critique",
          detail: "Present, discuss, and capture decisions",
          icon: "person.2.wave.2.fill",
          apps: [
            .init(id: "prototype", name: "Prototype", icon: "play.rectangle"),
            .init(id: "call", name: "Video call", icon: "video"),
            .init(id: "critique-notes", name: "Notes", icon: "note.text"),
          ],
        ),
        .init(
          id: "design-capture",
          title: "Quick capture",
          detail: "One app · borrow only",
          icon: "tray.full.fill",
          apps: [.init(id: "capture-notes", name: "Notes", icon: "note.text")],
          isQuickAccess: true,
        ),
      ]

    case .product:
      [
        .init(
          id: "product-plan",
          title: "Plan",
          detail: "Turn decisions into scheduled work",
          icon: "checklist",
          apps: [
            .init(id: "tracker", name: "Tracker", icon: "checklist.checked"),
            .init(id: "docs", name: "Docs", icon: "doc.text"),
            .init(id: "calendar", name: "Calendar", icon: "calendar"),
          ],
        ),
        .init(
          id: "product-discover",
          title: "Discovery",
          detail: "Collect evidence before deciding",
          icon: "scope",
          apps: [
            .init(id: "discovery-browser", name: "Browser", icon: "safari"),
            .init(id: "analytics", name: "Analytics", icon: "chart.xyaxis.line"),
            .init(id: "discovery-notes", name: "Notes", icon: "note.text"),
          ],
        ),
        .init(
          id: "product-message",
          title: "Quick message",
          detail: "One app · borrow only",
          icon: "tray.full.fill",
          apps: [.init(id: "message", name: "Team chat", icon: "bubble.left.and.text.bubble.right")],
          isQuickAccess: true,
        ),
      ]

    case .research:
      [
        .init(
          id: "research-collect",
          title: "Research",
          detail: "Collect and compare source material",
          icon: "binoculars.fill",
          apps: [
            .init(id: "papers", name: "Papers", icon: "doc.richtext"),
            .init(id: "research-browser", name: "Browser", icon: "safari"),
            .init(id: "research-notes", name: "Notes", icon: "note.text"),
          ],
        ),
        .init(
          id: "research-write",
          title: "Write",
          detail: "Synthesize evidence into one argument",
          icon: "pencil.and.outline",
          apps: [
            .init(id: "editor", name: "Editor", icon: "text.document"),
            .init(id: "references", name: "References", icon: "books.vertical"),
            .init(id: "writing-browser", name: "Browser", icon: "safari"),
          ],
        ),
        .init(
          id: "research-lookup",
          title: "Quick lookup",
          detail: "One app · borrow only",
          icon: "tray.full.fill",
          apps: [.init(id: "dictionary", name: "Dictionary", icon: "character.book.closed")],
          isQuickAccess: true,
        ),
      ]
    }
  }
}

// MARK: - OnboardingRoleContext

private struct OnboardingRoleContext: Identifiable {
  let id: String
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let icon: String
  let apps: [OnboardingRoleApp]
  var isQuickAccess = false
}

// MARK: - OnboardingRoleApp

private struct OnboardingRoleApp: Identifiable {
  let id: String
  let name: LocalizedStringResource
  let icon: String
}

// MARK: - OnboardingRoleBlueprintMap

private struct OnboardingRoleBlueprintMap: View {

  // MARK: Internal

  let role: OnboardingRoleBlueprint

  var body: some View {
    VStack(spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        ForEach(role.contexts) { context in
          VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
              Image(systemName: context.icon)
                .foregroundStyle(context.isQuickAccess ? Color.purple : Color.accentColor)
              Text(context.title)
                .font(.caption.weight(.semibold))
              Spacer(minLength: 4)
              Text(context.isQuickAccess ? "Quick access" : "Workspace")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Text(context.detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
              ForEach(context.apps) { app in
                Label(app.name, systemImage: app.icon)
                  .font(.caption2.weight(.medium))
                  .padding(.horizontal, 7)
                  .padding(.vertical, 5)
                  .background(Color.primary.opacity(0.055), in: .capsule)
              }
            }
          }
          .padding(12)
          .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
          .background(
            (context.isQuickAccess ? Color.purple : Color.accentColor).opacity(0.055),
            in: .rect(cornerRadius: 12),
          )
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(
                (context.isQuickAccess ? Color.purple : Color.accentColor).opacity(0.16)
              )
          }
        }
      }

      HStack(spacing: 10) {
        blueprintStrip(
          title: "Shared across contexts",
          detail: "Nothing by default",
          icon: "square.on.square",
          tint: .purple,
        )
        blueprintStrip(
          title: "Not managed",
          detail: "Utilities keep their own geometry",
          icon: "minus.circle",
          tint: .secondary,
        )
      }
    }
    .id(role.id)
    .transition(.opacity.combined(with: .scale(scale: 0.985)))
    .animation(.easeInOut(duration: 0.18), value: role)
  }

  // MARK: Private

  private func blueprintStrip(
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    icon: String,
    tint: Color,
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: icon)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption.weight(.semibold))
        Text(detail).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(tint.opacity(0.055), in: .rect(cornerRadius: 10))
  }

}

// MARK: - OnboardingWorkspaceMap

struct OnboardingWorkspaceMap: View {

  // MARK: Internal

  let groups: [OnboardingWorkspaceAppGroup]
  let sharedApps: [MacApp]
  let unmanagedCount: Int

  var body: some View {
    VStack(spacing: 10) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
        ForEach(groups.prefix(4)) { group in
          workspaceCard(group)
        }
      }
      HStack(spacing: 10) {
        membershipStrip(
          title: "Shared across contexts",
          detail: sharedApps.isEmpty ? "Nothing shared—recommended" : "\(sharedApps.count) apps always arrive",
          icon: "square.on.square",
          tint: .purple,
        )
        membershipStrip(
          title: "Not managed",
          detail: "\(unmanagedCount) apps keep their current windows",
          icon: "minus.circle",
          tint: .secondary,
        )
      }
      if groups.count > 4 {
        Text("+ \(groups.count - 4) more contexts in this draft")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Private

  private func workspaceCard(_ group: OnboardingWorkspaceAppGroup) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: group.workspace.symbolIconName ?? "square.stack.3d.up")
          .foregroundStyle(group.workspace.kind == .scratchpad ? Color.purple : Color.accentColor)
        Text(group.workspace.name)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Spacer()
        Text(group.workspace.kind == .scratchpad ? "Quick access" : "Workspace")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
      HStack(spacing: -5) {
        ForEach(group.apps.prefix(5), id: \.bundleIdentifier) { app in
          AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
            .frame(width: 30, height: 30)
            .background(.background, in: .circle)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        }
        if group.apps.isEmpty {
          Text("Assign apps below")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      Text(group.apps.isEmpty ? "No windows arrive yet" : "These apps arrive and leave together")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(Color.primary.opacity(0.075))
    }
  }

  private func membershipStrip(
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    icon: String,
    tint: Color,
  ) -> some View {
    HStack(spacing: 9) {
      Image(systemName: icon)
        .foregroundStyle(tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption.weight(.semibold))
        Text(detail).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(tint.opacity(0.055), in: .rect(cornerRadius: 10))
  }

}

// MARK: - OnboardingSwitchingDemo

struct OnboardingSwitchingDemo: View {
  let workspaces: [Workspace]
  let activeWorkspace: Workspace?
  let activeApps: [MacApp]
  let onWorkspaceTapped: (Workspace.ID) -> Void

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 9) {
        ForEach(workspaces) { workspace in
          Button {
            onWorkspaceTapped(workspace.id)
          } label: {
            Label(workspace.name, systemImage: workspace.symbolIconName ?? "square.stack.3d.up")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .tint(activeWorkspace?.id == workspace.id ? .accentColor : .secondary)
          .accessibilityAddTraits(activeWorkspace?.id == workspace.id ? .isSelected : [])
        }
      }

      HStack(spacing: 14) {
        Image(systemName: activeWorkspace?.symbolIconName ?? "square.stack.3d.up")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 44, height: 44)
          .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 3) {
          Text(activeWorkspace?.name ?? String(localized: "Workspace"))
            .font(.headline)
          Text(activeApps.isEmpty ? "No assigned apps yet" : "\(activeApps.count) apps arrive together")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: -5) {
          ForEach(activeApps.prefix(6), id: \.bundleIdentifier) { app in
            AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
              .frame(width: 30, height: 30)
              .background(.background, in: .circle)
              .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
          }
        }
      }
      .padding(16)
      .background(Color.accentColor.opacity(0.07), in: .rect(cornerRadius: 13))
      .animation(.spring(response: 0.28, dampingFraction: 0.86), value: activeWorkspace?.id)
    }
  }
}

// MARK: - OnboardingDemoMonitor

/// A shared visual language for every safe onboarding exercise. Content lives
/// inside a recognisable display rather than looking like a disconnected form.
struct OnboardingDemoMonitor<Content: View>: View {

  // MARK: Lifecycle

  init(
    title: String,
    status: String,
    hud: String? = nil,
    @ViewBuilder content: () -> Content,
  ) {
    self.title = title
    self.status = status
    self.hud = hud
    self.content = content()
  }

  // MARK: Internal

  let title: String
  let status: String
  let hud: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 21)
          .fill(
            LinearGradient(
              colors: [Color.black.opacity(0.92), Color.black.opacity(0.72)],
              startPoint: .top,
              endPoint: .bottom,
            )
          )

        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Image(systemName: "apple.logo")
              .font(.system(size: 10, weight: .semibold))
            Text(title)
              .font(.caption2.weight(.semibold))
            Spacer()
            Text(status)
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
            Image(systemName: "wifi")
              .font(.system(size: 9, weight: .medium))
            Image(systemName: "battery.75percent")
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(.white.opacity(0.9))
          .padding(.horizontal, 12)
          .frame(height: 28)
          .background(.ultraThinMaterial)

          content
            .padding(11)
            .frame(maxWidth: .infinity)
            .background {
              ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(
                  colors: [
                    Color.accentColor.opacity(0.10),
                    Color.purple.opacity(0.055),
                    .clear,
                  ],
                  startPoint: .topLeading,
                  endPoint: .bottomTrailing,
                )
              }
            }
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 13))
        .padding(9)
        .overlay(alignment: .top) {
          Capsule()
            .fill(Color.black.opacity(0.88))
            .frame(width: 38, height: 5)
            .padding(.top, 3)
        }
        .overlay(alignment: .top) {
          if let hud {
            Label(hud, systemImage: "sparkles")
              .font(.caption2.weight(.semibold))
              .lineLimit(1)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.thickMaterial, in: .capsule)
              .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
              .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
              .padding(.top, 36)
              .transition(.move(edge: .top).combined(with: .opacity))
          }
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 21)
          .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.28), radius: 18, y: 9)

      VStack(spacing: 0) {
        LinearGradient(
          colors: [Color.black.opacity(0.68), Color.black.opacity(0.34)],
          startPoint: .leading,
          endPoint: .trailing,
        )
        .frame(width: 54, height: 17)
        Capsule()
          .fill(Color.black.opacity(0.62))
          .frame(width: 128, height: 6)
      }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hud)
  }

}

// MARK: - OnboardingDemoControlPanel

/// Controls that drive a virtual display belong beside the monitor, not inside
/// its screen. Keeping this shell separate makes the screen read as the actual
/// macOS result while still connecting the controls to that result.
struct OnboardingDemoControlPanel<Content: View>: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      content
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 13))
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder(Color.primary.opacity(0.08))
    }
  }
}

// MARK: - OnboardingLessonPrompt

struct OnboardingLessonPrompt: View {
  let step: LocalizedStringResource
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  var completed = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: completed ? "checkmark.circle.fill" : "hand.point.up.left.fill")
        .font(.title3)
        .foregroundStyle(completed ? Color.green : Color.accentColor)
        .frame(width: 30, height: 30)
        .background(
          (completed ? Color.green : Color.accentColor).opacity(0.11),
          in: .circle,
        )
      VStack(alignment: .leading, spacing: 4) {
        Text(step)
          .font(.caption2.weight(.bold))
          .foregroundStyle(completed ? Color.green : Color.accentColor)
        Text(title)
          .font(.callout.weight(.semibold))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }
    .padding(14)
    .background(
      (completed ? Color.green : Color.accentColor).opacity(0.055),
      in: .rect(cornerRadius: 13),
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13)
        .strokeBorder((completed ? Color.green : Color.accentColor).opacity(0.18))
    }
  }
}

// MARK: - OnboardingSettingToggle

struct OnboardingSettingToggle: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource

  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .toggleStyle(.checkbox)
    .padding(.vertical, 3)
  }
}

// MARK: - OnboardingCommandReference

struct OnboardingCommandReference: View {

  // MARK: Internal

  let config: AppConfig
  let shortcut: (HotKeyAction) -> HotKey?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(commandGroups) { group in
        VStack(alignment: .leading, spacing: 9) {
          Label(group.title, systemImage: group.icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(group.tint)
          ForEach(group.items) { item in
            commandRow(item, tint: group.tint)
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
      }
    }
  }

  // MARK: Private

  private struct CommandGroup: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let icon: String
    let tint: Color
    let items: [CommandItem]
  }

  private struct CommandItem: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let practice: LocalizedStringResource
    let actions: [HotKeyAction]
  }

  private var commandGroups: [CommandGroup] {
    let workspace = config.activeProfile?.workspaces.first
    let alternateWorkspace = config.activeProfile?.workspaces.dropFirst().first ?? workspace
    let profile = config.profiles.first
    var contextItems = [
      CommandItem(
        id: "activate-workspace",
        title: "Activate a workspace",
        detail: "Replace the visible task context with one named workspace.",
        practice: "Switching Lab",
        actions: workspace.map { [.activateWorkspace($0.id)] } ?? [],
      ),
      CommandItem(
        id: "cycle-workspace",
        title: "Next / Previous / Recent workspace",
        detail: "Walk the configured order or return to the most recently used context.",
        practice: "Switching Lab",
        actions: [.switchToNextWorkspace, .switchToPreviousWorkspace, .switchToRecentWorkspace],
      ),
      CommandItem(
        id: "assign-direct",
        title: "Assign app to a workspace",
        detail: "Add the focused app to a named context and follow it there.",
        practice: "Workspaces",
        actions: alternateWorkspace.map { [.assignFocusedAppToWorkspace($0.id)] } ?? [],
      ),
      CommandItem(
        id: "assign-navigation",
        title: "Assign app to Next / Previous / Recent",
        detail: "Use workspace navigation targets without remembering a numbered key.",
        practice: "Workspaces",
        actions: [
          .assignFocusedAppToNextWorkspace,
          .assignFocusedAppToPreviousWorkspace,
          .assignFocusedAppToRecentWorkspace,
        ],
      ),
      CommandItem(
        id: "move-app",
        title: "Move app Next / Previous",
        detail: "Relocate the focused app to an adjacent context and switch with it.",
        practice: "Workspaces",
        actions: [.moveFocusedAppToNextWorkspace, .moveFocusedAppToPreviousWorkspace],
      ),
      CommandItem(
        id: "focus-display",
        title: "Focus Next / Previous display",
        detail: "Move keyboard focus to the workspace active on another monitor.",
        practice: "Switching",
        actions: [.focusNextDisplay, .focusPreviousDisplay],
      ),
      CommandItem(
        id: "membership",
        title: "Toggle app membership",
        detail: "Add/remove the focused app in this workspace or in Shared Apps.",
        practice: "Workspaces",
        actions: [.toggleFocusedAppInActiveWorkspace, .toggleAppInSharedApps],
      ),
      CommandItem(
        id: "pause",
        title: "Pause / resume this macOS Space",
        detail: "Temporarily stop Tatami activation on the current Space without changing config.",
        practice: "Settings",
        actions: [.toggleSpaceActivated],
      ),
    ]
    if let profile {
      contextItems.insert(CommandItem(
        id: "activate-profile",
        title: "Activate a profile",
        detail: "Swap the complete workspace/display setup, for example Laptop ↔ Desk.",
        practice: "Finish",
        actions: [.activateProfile(profile.id)],
      ), at: 6)
    }

    return [
      CommandGroup(
        id: "contexts",
        title: "Contexts & membership",
        icon: "square.stack.3d.up",
        tint: .accentColor,
        items: contextItems,
      ),
      CommandGroup(
        id: "windows",
        title: "Windows & split tree",
        icon: "rectangle.split.2x2",
        tint: .orange,
        items: [
          CommandItem(
            id: "focus-direction",
            title: "Focus Left / Right / Up / Down",
            detail: "Change the target tile without changing the tree.",
            practice: "Tiling Lab",
            actions: [.focusLeft, .focusRight, .focusUp, .focusDown],
          ),
          CommandItem(
            id: "cycle-window",
            title: "Cycle Next / Previous window",
            detail: "Step through the visible Tatami context—not the global ⌘Tab list or one app's ⌘` list.",
            practice: "Gesture + Tiling",
            actions: [.cycleNextWindow, .cyclePreviousWindow],
          ),
          CommandItem(
            id: "swap-direction",
            title: "Swap Left / Right / Up / Down",
            detail: "Exchange with a directional neighbor; at an outer edge, turn the parent split toward that direction.",
            practice: "Tiling Lab",
            actions: [.swapLeft, .swapRight, .swapUp, .swapDown],
          ),
          CommandItem(
            id: "resize",
            title: "Grow / Shrink",
            detail: "Adjust the split ratio that owns the focused tile.",
            practice: "Tiling Lab",
            actions: [.resizeGrow, .resizeShrink],
          ),
          CommandItem(
            id: "orientation",
            title: "Toggle orientation",
            detail: "Flip the selected branch between side-by-side and stacked.",
            practice: "Tiling Lab",
            actions: [.toggleOrientation],
          ),
          CommandItem(
            id: "fullscreen",
            title: "Toggle fullscreen",
            detail: "Zoom the focused tile inside its workspace, then restore the tree.",
            practice: "Tiling Lab",
            actions: [.toggleFullscreen],
          ),
          CommandItem(
            id: "balance",
            title: "Balance layout",
            detail: "Follow Auto-balance; Off rebuilds the BSP layout.",
            practice: "Tiling Lab",
            actions: [.balance],
          ),
        ],
      ),
      CommandGroup(
        id: "composition",
        title: "Borrow & floating",
        icon: "rectangle.righthalf.inset.filled",
        tint: .purple,
        items: [
          CommandItem(
            id: "borrow-direct",
            title: "Borrow a workspace",
            detail: "Dock a named context beside the host without merging either layout.",
            practice: "Borrow Lab",
            actions: alternateWorkspace.map { [.borrowWorkspace($0.id)] } ?? [],
          ),
          CommandItem(
            id: "borrow-navigation",
            title: "Borrow Next / Previous / Recent",
            detail: "Choose the visiting context through navigation targets.",
            practice: "Borrow Lab",
            actions: [.borrowNextWorkspace, .borrowPreviousWorkspace, .borrowRecentWorkspace],
          ),
          CommandItem(
            id: "dismiss-borrow",
            title: "Dismiss Borrow",
            detail: "Return the visitor and expand the untouched host layout.",
            practice: "Borrow Lab",
            actions: [.dismissBorrow],
          ),
          CommandItem(
            id: "floating",
            title: "Toggle floating",
            detail: "Move the focused workspace app between the BSP tree and its topmost mirror.",
            practice: "Float Lab",
            actions: [.toggleFloating],
          ),
          CommandItem(
            id: "shared-floating",
            title: "Toggle Shared floating",
            detail: "Add the focused app to Shared Apps as floating, or flip an existing shared assignment.",
            practice: "Float + Workspaces",
            actions: [.toggleSharedFloating],
          ),
        ],
      ),
    ]
  }

  private func commandRow(_ item: CommandItem, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(item.title)
        .font(.caption.weight(.semibold))
      Text(shortcutSummary(for: item.actions))
        .font(.caption2.monospaced().weight(.medium))
        .foregroundStyle(tint)
        .lineLimit(2)
        .minimumScaleFactor(0.72)
      Text(item.detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(item.practice)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
    }
    .padding(9)
    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 9))
  }

  private func shortcutSummary(for actions: [HotKeyAction]) -> String {
    let symbols = actions.compactMap { shortcut($0)?.symbols }
    return symbols.isEmpty
      ? String(localized: "Set in Settings")
      : symbols.joined(separator: " · ")
  }

}

// MARK: - OnboardingWindowCyclingComparison

struct OnboardingWindowCyclingComparison: View {

  // MARK: Internal

  let tatamiShortcut: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      comparisonCard(
        shortcut: tatamiShortcut,
        title: "Tatami cycling",
        detail: "Searches the active Tatami context instead of every running app. Its Floating and Ignore-mode members participate, and a borrowed tiled block joins the host until dismissed.",
        tint: .accentColor,
      )
      comparisonCard(
        shortcut: "⌘Tab",
        title: "macOS app switcher",
        detail: "Searches running apps across the whole login session. It chooses an app, not a Tatami workspace.",
        tint: .blue,
      )
      comparisonCard(
        shortcut: "⌘`",
        title: "macOS window cycle",
        detail: "Searches windows belonging to the current app only. It cannot move from one workspace app to another.",
        tint: .purple,
      )
    }
  }

  // MARK: Private

  private func comparisonCard(
    shortcut: String,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    tint: Color,
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(shortcut)
        .font(.system(.callout, design: .rounded, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1), in: .capsule)
      Text(title)
        .font(.callout.weight(.semibold))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(13)
    .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
    .background(tint.opacity(0.045), in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(tint.opacity(0.14))
    }
  }

}

// MARK: - OnboardingGesturePractice

struct OnboardingGesturePractice: View {

  // MARK: Internal

  let enabled: Bool
  let workspaces: [Workspace]
  let activeWorkspace: Workspace?
  let apps: [MacApp]
  let selectedWindowIndex: Int
  let lastGesture: TrackpadGesture?
  let actionResult: String?
  let windowGestureCompleted: Bool
  let workspaceGestureCompleted: Bool
  let onWorkspaceTapped: (Workspace.ID) -> Void
  let onSimulate: (TrackpadGesture) -> Void

  var body: some View {
    VStack(spacing: 14) {
      OnboardingGestureConsole(
        workspaces: workspaces,
        activeWorkspace: activeWorkspace,
        windowGestureCompleted: windowGestureCompleted,
        workspaceGestureCompleted: workspaceGestureCompleted,
        onWorkspaceTapped: onWorkspaceTapped,
      )

      OnboardingDemoMonitor(
        title: activeWorkspace?.name ?? String(localized: "Gesture Lab"),
        status: String(localized: "Virtual display · safe preview"),
        hud: actionResult,
      ) {
        OnboardingGestureWindowStage(
          apps: apps,
          selectedWindowIndex: selectedWindowIndex,
        )
        .frame(height: 250)
      }

      lessonPrompt

      OnboardingDemoControlPanel(
        title: "No trackpad?",
        detail: "These buttons send the same gesture actions to the virtual display above.",
      ) {
        HStack(spacing: 8) {
          Button("3F ←") { simulate(fingers: 3, direction: .left) }
          Button("3F →") { simulate(fingers: 3, direction: .right) }
          Divider().frame(height: 20)
          Button("4F ←") { simulate(fingers: 4, direction: .left) }
          Button("4F →") { simulate(fingers: 4, direction: .right) }
          Spacer()
          if let lastGesture {
            Label(
              "Recognized \(lastGesture.fingerCount)F \(lastGesture.direction.rawValue)",
              systemImage: "checkmark.circle.fill",
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .transition(.scale.combined(with: .opacity))
          }
        }
      }
      .disabled(!enabled)
    }
    .animation(.easeInOut(duration: 0.18), value: lastGesture)
    .animation(.spring(response: 0.3, dampingFraction: 0.84), value: selectedWindowIndex)
    .animation(.spring(response: 0.3, dampingFraction: 0.84), value: activeWorkspace?.id)
  }

  // MARK: Private

  private var lessonPrompt: some View {
    let windowDone = windowGestureCompleted
    let workspaceDone = workspaceGestureCompleted
    return OnboardingLessonPrompt(
      step: !windowDone ? "Step 1 of 2" : (workspaceDone ? "Complete" : "Step 2 of 2"),
      title: !windowDone
        ? "Cycle the focused window"
        : (workspaceDone ? "You learned both gesture levels" : "Change the whole workspace"),
      detail: !windowDone
        ? "Swipe left or right with three fingers. Only the highlighted window should change."
        : (workspaceDone
          ? "Three fingers stays local to this workspace; four fingers replaces the entire task context."
          : "Now swipe with four fingers. The workspace rail and every window should change together."),
      completed: windowDone && workspaceDone,
    )
  }

  private func simulate(fingers: Int, direction: GestureDirection) {
    onSimulate(TrackpadGesture(fingerCount: fingers, direction: direction))
  }

}

// MARK: - OnboardingGestureConsole

private struct OnboardingGestureConsole: View {

  // MARK: Internal

  let workspaces: [Workspace]
  let activeWorkspace: Workspace?
  let windowGestureCompleted: Bool
  let workspaceGestureCompleted: Bool
  let onWorkspaceTapped: (Workspace.ID) -> Void

  var body: some View {
    OnboardingDemoControlPanel(
      title: "Gesture controller",
      detail: "This console controls the virtual display below; it is not part of the simulated macOS screen.",
    ) {
      HStack(spacing: 10) {
        lessonBadge(number: 1, title: "Windows", completed: windowGestureCompleted)
        lessonBadge(number: 2, title: "Workspace", completed: workspaceGestureCompleted)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Label("4 fingers · switch the whole workspace", systemImage: "hand.raised.fingers.spread")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        FlowLayout(spacing: 8) {
          ForEach(workspaces) { workspace in
            workspaceButton(workspace)
          }
        }
      }

      Label(
        "3 fingers · cycle the focused window inside \(activeWorkspace?.name ?? String(localized: "this workspace"))",
        systemImage: "macwindow",
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  private func lessonBadge(
    number: Int,
    title: LocalizedStringResource,
    completed: Bool
  ) -> some View {
    Label(
      "\(number) · \(String(localized: title))",
      systemImage: completed ? "checkmark.circle.fill" : "circle"
    )
      .font(.caption.weight(.semibold))
      .foregroundStyle(completed ? Color.green : Color.secondary)
  }

  private func workspaceButton(_ workspace: Workspace) -> some View {
    let selected = workspace.id == activeWorkspace?.id
    return Button {
      onWorkspaceTapped(workspace.id)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
        Text(workspace.name)
          .lineLimit(1)
        if selected {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 6, height: 6)
        }
      }
      .font(.caption.weight(selected ? .semibold : .regular))
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(
      selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
      in: .rect(cornerRadius: 9),
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

}

// MARK: - OnboardingGestureWindowStage

private struct OnboardingGestureWindowStage: View {

  // MARK: Internal

  let apps: [MacApp]
  let selectedWindowIndex: Int

  var body: some View {
    HStack(spacing: 9) {
      demoWindow(index: 0, fallbackTitle: "Main window")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      VStack(spacing: 9) {
        demoWindow(index: 1, fallbackTitle: "Reference")
        demoWindow(index: 2, fallbackTitle: "Messages")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: Private

  private func demoWindow(index: Int, fallbackTitle: String) -> some View {
    let app = apps.indices.contains(index) ? apps[index] : nil
    let selected = selectedWindowIndex % 3 == index
    let title = app?.name ?? fallbackTitle
    return VStack(spacing: 0) {
      HStack(spacing: 5) {
        Circle().fill(Color.red.opacity(0.8)).frame(width: 6, height: 6)
        Circle().fill(Color.yellow.opacity(0.8)).frame(width: 6, height: 6)
        Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
        Text(title)
          .font(.system(size: 9, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .frame(height: 25)
      .background(Color.primary.opacity(0.055))

      VStack(spacing: 7) {
        if let app {
          AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
            .frame(width: 32, height: 32)
        } else {
          Image(systemName: index == 0 ? "doc.richtext" : (index == 1 ? "safari" : "bubble.left.and.bubble.right"))
            .font(.title2)
            .foregroundStyle(.secondary)
        }
        Text(title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025))
    }
    .background(.regularMaterial)
    .compositingGroup()
    .clipShape(.rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          selected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.12),
          lineWidth: selected ? 2 : 1,
        )
    }
    .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 8 : 4, y: 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)\(selected ? ", focused" : "")")
  }

}

// MARK: - OnboardingLayoutToolbar

struct OnboardingLayoutToolbar: View {

  // MARK: Internal

  let onCommand: (OnboardingDemoCommand) -> Void

  var body: some View {
    HStack(spacing: 10) {
      commandGroup("Focus") {
        iconButton("Focus left", symbol: "arrow.left", command: .focus(.west))
        iconButton("Focus down", symbol: "arrow.down", command: .focus(.south))
        iconButton("Focus up", symbol: "arrow.up", command: .focus(.north))
        iconButton("Focus right", symbol: "arrow.right", command: .focus(.east))
      }
      commandDivider
      commandGroup("Swap / warp") {
        iconButton("Swap left", symbol: "arrow.left", command: .swap(.west))
        iconButton("Swap down", symbol: "arrow.down", command: .swap(.south))
        iconButton("Swap up", symbol: "arrow.up", command: .swap(.north))
        iconButton("Swap right", symbol: "arrow.right", command: .swap(.east))
      }
      commandDivider
      commandGroup("Cycle") {
        iconButton("Previous window", symbol: "chevron.backward", command: .cycle(.previous))
        iconButton("Next window", symbol: "chevron.forward", command: .cycle(.next))
      }
      commandDivider
      commandGroup("Size") {
        iconButton("Shrink window", symbol: "minus", command: .resize(delta: -0.05))
        iconButton("Grow window", symbol: "plus", command: .resize(delta: 0.05))
      }
      commandDivider
      commandGroup("Layout") {
        iconButton("Flip split", symbol: "rectangle.split.2x1", command: .orientation)
        iconButton("Zoom window", symbol: "arrow.up.left.and.arrow.down.right", command: .fullscreen)
        iconButton("Balance layout", symbol: "square.grid.2x2", command: .balance)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  // MARK: Private

  private var commandDivider: some View {
    Divider().frame(height: 34)
  }

  private func commandGroup(
    _ title: LocalizedStringResource,
    @ViewBuilder content: () -> some View,
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
      HStack(spacing: 4) { content() }
    }
  }

  private func iconButton(
    _ title: LocalizedStringResource,
    symbol: String,
    command: OnboardingDemoCommand,
  ) -> some View {
    Button {
      onCommand(command)
    } label: {
      Image(systemName: symbol)
        .frame(width: 16, height: 16)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(Text(title))
    .accessibilityLabel(Text(title))
  }

}

// MARK: - OnboardingBorrowDemo

struct OnboardingBorrowDemo: View {

  // MARK: Internal

  let hostName: String
  let hostApps: [MacApp]
  let borrowedName: String
  let borrowedApps: [MacApp]
  let borrowed: Bool
  let edge: BorrowEdge
  let fraction: Double

  var body: some View {
    GeometryReader { geometry in
      let frames = regions(in: CGRect(origin: .zero, size: geometry.size))
      ZStack {
        RoundedRectangle(cornerRadius: 13)
          .fill(Color(nsColor: .windowBackgroundColor))
        region(
          title: hostName,
          apps: hostApps,
          color: .accentColor,
          frame: frames.host,
        )
        if borrowed {
          region(
            title: borrowedName,
            apps: borrowedApps,
            color: .purple,
            frame: frames.borrowed,
          )
        }
      }
      .compositingGroup()
      .clipShape(.rect(cornerRadius: 13))
    }
    .frame(height: 260)
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: borrowed)
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: edge)
    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: fraction)
  }

  // MARK: Private

  private func region(
    title: String,
    apps: [MacApp],
    color: Color,
    frame: CGRect,
  ) -> some View {
    VStack(spacing: 9) {
      HStack(spacing: -5) {
        ForEach(apps.prefix(3), id: \.bundleIdentifier) { app in
          AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
            .frame(width: 34, height: 34)
            .background(.background, in: .circle)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        }
      }
      Text(title)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
    }
    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
    .background(color.opacity(0.08), in: .rect(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11)
        .strokeBorder(color.opacity(0.38))
    }
    .position(x: frame.midX, y: frame.midY)
  }

  private func regions(in bounds: CGRect) -> (host: CGRect, borrowed: CGRect) {
    let inset = bounds.insetBy(dx: 10, dy: 10)
    guard borrowed else { return (inset, .zero) }
    let gap = 10.0
    let value = CGFloat(min(max(fraction, 0.3), 0.7))
    switch edge {
    case .left:
      let width = (inset.width - gap) * value
      return (
        CGRect(x: inset.minX + width + gap, y: inset.minY, width: inset.width - width - gap, height: inset.height),
        CGRect(x: inset.minX, y: inset.minY, width: width, height: inset.height),
      )

    case .right:
      let width = (inset.width - gap) * value
      return (
        CGRect(x: inset.minX, y: inset.minY, width: inset.width - width - gap, height: inset.height),
        CGRect(x: inset.maxX - width, y: inset.minY, width: width, height: inset.height),
      )

    case .top:
      let height = (inset.height - gap) * value
      return (
        CGRect(x: inset.minX, y: inset.minY + height + gap, width: inset.width, height: inset.height - height - gap),
        CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: height),
      )

    case .bottom:
      let height = (inset.height - gap) * value
      return (
        CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height - height - gap),
        CGRect(x: inset.minX, y: inset.maxY - height, width: inset.width, height: height),
      )
    }
  }

}

// MARK: - OnboardingModeCard

struct OnboardingModeCard: View {
  let title: LocalizedStringResource
  let detail: LocalizedStringResource
  let selected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.callout.weight(.semibold))
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      selected ? Color.accentColor.opacity(0.075) : Color.primary.opacity(0.035),
      in: .rect(cornerRadius: 12),
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06))
    }
  }
}

// MARK: - OnboardingMetric

struct OnboardingMetric: View {
  let value: String
  let label: LocalizedStringResource
  let icon: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(value)
          .font(.title2.weight(.semibold).monospacedDigit())
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(Color.primary.opacity(0.07))
    }
  }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {

  // MARK: Internal

  let spacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout (),
  ) -> CGSize {
    layout(proposal: proposal, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout (),
  ) {
    let result = layout(
      proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
      subviews: subviews,
    )
    for (index, point) in result.points.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
        anchor: .topLeading,
        proposal: .unspecified,
      )
    }
  }

  // MARK: Private

  private func layout(
    proposal: ProposedViewSize,
    subviews: Subviews,
  ) -> (size: CGSize, points: [CGPoint]) {
    let maxWidth = proposal.width ?? .greatestFiniteMagnitude
    var points = [CGPoint]()
    var cursor = CGPoint.zero
    var rowHeight = 0.0
    var usedWidth = 0.0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if cursor.x > 0, cursor.x + size.width > maxWidth {
        cursor.x = 0
        cursor.y += rowHeight + spacing
        rowHeight = 0
      }
      points.append(cursor)
      cursor.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      usedWidth = max(usedWidth, cursor.x - spacing)
    }
    return (CGSize(width: usedWidth, height: cursor.y + rowHeight), points)
  }

}
