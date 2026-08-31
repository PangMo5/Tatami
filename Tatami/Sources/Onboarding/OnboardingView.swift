// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit

// MARK: - OnboardingView

struct OnboardingView: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    HStack(spacing: 0) {
      OnboardingSidebar(store: store)
      Divider()
      VStack(spacing: 0) {
        OnboardingHeader(step: store.step)
        Divider()
        ScrollViewReader { proxy in
          ScrollView {
            Color.clear
              .frame(height: 0)
              .id(ScrollAnchor.top)
            OnboardingStepContent(store: store)
              .frame(maxWidth: 900, alignment: .topLeading)
              .padding(.horizontal, 36)
              .padding(.vertical, 30)
              .frame(maxWidth: .infinity, alignment: .top)
          }
          .onChange(of: store.step) { _, _ in
            proxy.scrollTo(ScrollAnchor.top, anchor: .top)
          }
        }
        Divider()
        OnboardingFooter(store: store)
      }
    }
    .frame(minWidth: 1_040, minHeight: 720)
    .task { store.send(.viewAppeared) }
    .onDisappear { store.send(.viewDisappeared) }
    .onChange(of: store.dismissalRequest) { previousRequest, request in
      if request > previousRequest { dismissWindow() }
    }
  }

  // MARK: Private

  private enum ScrollAnchor {
    case top
  }

  @Environment(\.dismissWindow) private var dismissWindow

}

// MARK: - OnboardingSidebar

private struct OnboardingSidebar: View {
  let store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Tatami")
          .font(.title2.weight(.semibold))
        Text("Guided Setup")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 14)

      ForEach(OnboardingStep.allCases) { step in
        Button {
          store.send(.stepSelected(step))
        } label: {
          HStack(spacing: 11) {
            Image(systemName: step.icon)
              .frame(width: 19)
            Text(step.title)
            Spacer()
            if step.index < store.step.index || step.index < store.furthestStepIndex {
              Image(systemName: "checkmark")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .contentShape(.rect)
          .background(
            store.step == step ? Color.accentColor.opacity(0.14) : .clear,
            in: .rect(cornerRadius: 10),
          )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.step == step ? .isSelected : [])
      }

      Spacer()

      Button {
        store.send(.resetButtonTapped)
      } label: {
        Label("Start Over", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
    }
    .padding(16)
    .frame(width: 224)
    .background(.thinMaterial)
  }
}

// MARK: - OnboardingHeader

private struct OnboardingHeader: View {
  let step: OnboardingStep

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(step.title)
          .font(.title2.weight(.semibold))
        Text(step.subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 6) {
        Text("\(step.index + 1) of \(OnboardingStep.allCases.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        ProgressView(value: Double(step.index + 1), total: Double(OnboardingStep.allCases.count))
          .frame(width: 112)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 17)
  }
}

// MARK: - OnboardingFooter

private struct OnboardingFooter: View {
  let store: StoreOf<OnboardingFeature>

  var body: some View {
    HStack(spacing: 12) {
      if let validationMessage = store.validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Label("Nothing changes until you apply the draft.", systemImage: "lock.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Back") { store.send(.backButtonTapped) }
        .disabled(store.step.previous == nil)
      if store.step == .finish {
        Button {
          store.send(.applyButtonTapped)
        } label: {
          if store.isApplying {
            ProgressView()
              .controlSize(.small)
              .frame(width: 82)
          } else {
            Text("Apply Setup")
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(store.isApplying || !store.canApply)
      } else {
        Button("Continue") { store.send(.nextButtonTapped) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(.horizontal, 28)
    .padding(.vertical, 14)
  }
}

// MARK: - OnboardingStepContent

private struct OnboardingStepContent: View {
  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    switch store.step {
    case .welcome:
      OnboardingWelcomeStep(store: store)
    case .environment:
      OnboardingEnvironmentStep(store: store)
    case .workspaces:
      OnboardingWorkspacesStep(store: store)
    case .switching:
      OnboardingSwitchingStep(store: store)
    case .tiling:
      OnboardingTilingStep(store: store)
    case .borrow:
      OnboardingBorrowStep(store: store)
    case .floating:
      OnboardingFloatingStep(store: store)
    case .focusAndCycling:
      OnboardingFocusCyclingStep(store: store)
    case .finish:
      OnboardingFinishStep(store: store)
    }
  }
}

// MARK: - OnboardingWelcomeStep

private struct OnboardingWelcomeStep: View {
  let store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 28) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Switch tasks, not windows.")
          .font(.largeTitle.weight(.bold))
        Text(
          "Tatami groups the apps for a task, remembers their layout, and brings the whole context back with one key or gesture."
        )
        .font(.title3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(alignment: .top, spacing: 16) {
        OnboardingPhilosophyCard(
          icon: "square.stack.3d.up",
          title: "Contexts over desktops",
          detail: "A workspace represents a repeatable activity such as deep work, research, review, or conversation.",
        )
        OnboardingPhilosophyCard(
          icon: "rectangle.split.2x2",
          title: "Memory with control",
          detail: "Routine placement is automatic. Focus, swap, resize, and borrow stay explicit.",
        )
        OnboardingPhilosophyCard(
          icon: "lock.shield",
          title: "Native and inspectable",
          detail: "Keep SIP enabled, avoid shell scripts, and retain a readable TOML configuration.",
        )
      }

      OnboardingSection(title: "Built from this Mac", subtitle: "Only app metadata and display names are used during setup.") {
        HStack(spacing: 28) {
          Label(
            store.displays.count == 1
              ? "\(store.displays.count) display"
              : "\(store.displays.count) displays",
            systemImage: "display"
          )
          Label("\(store.runningApps.count) running apps", systemImage: "app.badge")
          Label("No screen contents captured", systemImage: "eye.slash")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      OnboardingRecommendationCallout(
        "The right workspace count depends on your role. First create the contexts you enter independently. Later, after learning temporary Borrow, you can add a special one-app quick-access context for brief side work."
      )
    }
  }
}

// MARK: - OnboardingEnvironmentStep

private struct OnboardingEnvironmentStep: View {
  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(title: "Permissions", subtitle: "Tatami asks only for capabilities used by the features you enable.") {
        VStack(spacing: 14) {
          OnboardingPermissionRow(
            title: "Accessibility",
            detail: store.hasAccessibility
              ? "Granted — Tatami can move, resize, and focus windows."
              : "Required for workspace switching and tiling.",
            granted: store.hasAccessibility,
            buttonTitle: store.hasAccessibility ? nil : "Grant…",
            action: { store.send(.grantAccessibilityButtonTapped) },
          )
          Divider()
          OnboardingPermissionRow(
            title: "Screen Recording",
            detail: store.hasScreenRecording
              ? "Granted — local floating mirrors are available."
              : "Optional. Needed only for Floating mirrors.",
            granted: store.hasScreenRecording,
            buttonTitle: store.hasScreenRecording ? nil : "Grant…",
            action: { store.send(.grantScreenRecordingButtonTapped) },
          )
        }
      }

      if !store.hasAccessibility || !store.hasScreenRecording {
        OnboardingInlineNotice(
          icon: "arrow.clockwise.circle",
          title: "Relaunch after granting access",
          detail: "macOS applies a newly granted permission after Tatami relaunches. Your draft is saved first.",
          tint: .orange,
          buttonTitle: "Relaunch Tatami",
          action: { store.send(.relaunchButtonTapped) },
        )
      }

      HStack(alignment: .top, spacing: 18) {
        OnboardingSection(title: "Startup", subtitle: "Keep the menu-bar workspace manager ready.") {
          Toggle(isOn: $store.draft.settings.general.launchAtLogin) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Launch at login")
              Text("Recommended for a workspace manager.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        OnboardingSection(title: "Connected Displays", subtitle: "Workspaces can follow a named display or stay dynamic.") {
          if store.displays.isEmpty {
            Label("No displays found", systemImage: "display.trianglebadge.exclamationmark")
              .foregroundStyle(.secondary)
          } else {
            FlowLayout(spacing: 8) {
              ForEach(store.displays, id: \.self) { display in
                Label(display.name, systemImage: "display")
                  .font(.callout)
                  .padding(.horizontal, 11)
                  .padding(.vertical, 7)
                  .background(Color.secondary.opacity(0.09), in: .capsule)
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - OnboardingWorkspacesStep

private struct OnboardingWorkspacesStep: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(
        title: store.hasCustomizedWorkspaceMap
          ? "Your setup so far"
          : "See a useful workspace before making yours",
        subtitle: store.hasCustomizedWorkspaceMap
          ? "This map now follows the names and app membership in your draft."
          : "Start with a role example, then shape your own named tasks and the apps that should arrive together.",
      ) {
        VStack(spacing: 12) {
          if store.hasCustomizedWorkspaceMap {
            OnboardingDemoMonitor(
              title: String(localized: "Your Workspace Map"),
              status: String(localized: "Your draft"),
            ) {
              OnboardingWorkspaceMap(
                groups: store.workspaceAppGroups,
                sharedApps: store.sharedKnownApps,
                unmanagedCount: store.unassignedApps.count,
              )
            }
          } else {
            OnboardingRoleBlueprintGallery()
          }
          OnboardingLessonPrompt(
            step: "Foundation",
            title: "Group by work you enter, not by app category",
            detail: "A Workspace is the unit Tatami switches, lays out, hides, and restores. Shared apps appear in every context; Not managed apps are discovered but Tatami never moves them.",
          )
        }
      }

      OnboardingAIRecommendationSection(store: store)

      OnboardingSection(
        title: "Workspace shortcuts",
        subtitle: "Review the proposed contexts, then adjust names, keys, or displays.",
      ) {
        LazyVGrid(columns: workspaceColumns, alignment: .leading, spacing: 12) {
          ForEach(store.normalWorkspaces) { workspace in
            OnboardingWorkspaceEditorRow(
              workspace: workspace,
              displays: store.displays,
              canDelete: store.normalWorkspaces.count > 1,
              switchModifiers: switchModifiers,
              assignModifiers: assignModifiers,
              borrowModifiers: borrowModifiers,
              onNameChanged: { store.send(.workspaceNameChanged(workspace.id, $0)) },
              onKeyChanged: { store.send(.workspaceKeyChanged(workspace.id, $0)) },
              onDisplayChanged: { store.send(.workspaceDisplayChanged(workspace.id, $0)) },
              onDelete: { store.send(.deleteWorkspaceButtonTapped(workspace.id)) },
            )
          }
        }
        if !store.scratchpads.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 4) {
            Text("One-app quick access")
              .font(.callout.weight(.semibold))
            Text("These stay out of normal cycling. The Borrow lesson later introduces the name and behavior in context.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          LazyVGrid(columns: workspaceColumns, alignment: .leading, spacing: 12) {
            ForEach(store.scratchpads) { workspace in
              OnboardingWorkspaceEditorRow(
                workspace: workspace,
                displays: store.displays,
                canDelete: true,
                switchModifiers: switchModifiers,
                assignModifiers: assignModifiers,
                borrowModifiers: borrowModifiers,
                onNameChanged: { store.send(.workspaceNameChanged(workspace.id, $0)) },
                onKeyChanged: { store.send(.workspaceKeyChanged(workspace.id, $0)) },
                onDisplayChanged: { store.send(.workspaceDisplayChanged(workspace.id, $0)) },
                onDelete: { store.send(.deleteWorkspaceButtonTapped(workspace.id)) },
              )
            }
          }
        }
        HStack {
          Button {
            store.send(.addWorkspaceButtonTapped)
          } label: {
            Label("Add Workspace", systemImage: "plus")
          }
          Spacer()
        }
      }

      VStack(alignment: .leading, spacing: 14) {
        Text("Apps by workspace")
          .font(.headline)
        Text("Every app appears under its current destination. Use its menu to move it without losing the overview.")
          .font(.callout)
          .foregroundStyle(.secondary)

        ForEach(store.workspaceAppGroups) { group in
          OnboardingAppGroup(
            title: group.workspace.kind == .scratchpad
              ? String(localized: "\(group.workspace.name) · one-app quick access")
              : group.workspace.name,
            icon: group.workspace.symbolIconName ?? "square.stack.3d.up",
            tint: group.workspace.kind == .scratchpad ? .purple : .accentColor,
            apps: group.apps,
            emptyMessage: "No apps assigned yet",
            workspaces: store.activeWorkspaces,
            destination: { store.appDestinations[$0.bundleIdentifier] ?? .unassigned },
            onDestinationChanged: { app, destination in
              store.send(.appDestinationChanged(app.bundleIdentifier, destination))
            },
          )
        }

        if !store.sharedKnownApps.isEmpty {
          OnboardingAppGroup(
            title: String(localized: "Shared Apps"),
            icon: "square.on.square",
            tint: .purple,
            apps: store.sharedKnownApps,
            emptyMessage: "No shared apps",
            workspaces: store.activeWorkspaces,
            destination: { store.appDestinations[$0.bundleIdentifier] ?? .unassigned },
            onDestinationChanged: { app, destination in
              store.send(.appDestinationChanged(app.bundleIdentifier, destination))
            },
          )
        }

        OnboardingAppGroup(
          title: String(localized: "Not managed"),
          icon: "minus.circle",
          tint: .secondary,
          apps: store.unassignedApps,
          emptyMessage: "Every discovered app has a destination",
          workspaces: store.activeWorkspaces,
          destination: { store.appDestinations[$0.bundleIdentifier] ?? .unassigned },
          onDestinationChanged: { app, destination in
            store.send(.appDestinationChanged(app.bundleIdentifier, destination))
          },
        )

        Button {
          store.send(.chooseAppButtonTapped)
        } label: {
          Label("Choose an App from Files…", systemImage: "folder")
        }
      }

      OnboardingRecommendationCallout(
        "Prefer activity names that make sense for your role over catch-all app categories. Keep Shared Apps rare and leave utilities unmanaged when Tatami should not move them."
      )
    }
  }

  // MARK: Private

  private var workspaceColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 12)]
  }

  private var switchModifiers: String {
    HotKey.modifierSymbols(from: store.draft.settings.shortcuts.keyEquivalentModifiers)
  }

  private var assignModifiers: String {
    HotKey.modifierSymbols(from: store.draft.settings.shortcuts.assignModifiers)
  }

  private var borrowModifiers: String {
    HotKey.modifierSymbols(from: store.draft.settings.shortcuts.borrowModifiers)
  }

}

// MARK: - OnboardingAIRecommendationSection

private struct OnboardingAIRecommendationSection: View {
  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    OnboardingSection(
      title: "Design my setup with AI",
      subtitle: "Describe your work in plain language. Tatami infers durable contexts instead of copying your list.",
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Role or kind of work")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("e.g. iOS developer, designer, student", text: $store.roleDescription)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("What fills a typical week?")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            TextField("e.g. ship features, review PRs, explore ideas, coordinate releases", text: $store.recurringWork)
          }
        }
        Picker("Context density", selection: $store.contextStyle) {
          ForEach(OnboardingContextStyle.allCases) { style in
            Text(style.displayName).tag(style)
          }
        }
        .pickerStyle(.segmented)
        Text(store.contextStyle.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Include a one-app quick-access context for brief side work", isOn: $store.prefersScratchpads)
          Text(
            "This stays out of normal cycling and is summoned temporarily. AI only uses it when that app remains useful beside another workspace on your available screen space."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Divider()

        HStack(spacing: 8) {
          Label("Use any AI", systemImage: "sparkles.rectangle.stack")
            .font(.callout.weight(.semibold))
          Text("Recommended")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.1), in: .capsule)
            .foregroundStyle(Color.accentColor)
          Spacer()
        }
        Text(
          "Tatami prepares the prompt and validates the result. You choose ChatGPT, Claude, Gemini, or another AI — no account connection required."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        HStack(spacing: 10) {
          Button {
            store.send(.externalAIPromptCopyButtonTapped)
          } label: {
            Label(
              store.externalAIPromptCopied ? "1. Prompt Copied" : "1. Copy Prompt",
              systemImage: store.externalAIPromptCopied ? "checkmark" : "doc.on.doc",
            )
          }
          .disabled(!store.canRequestAIRecommendation)

          Label("2. Ask your AI", systemImage: "arrow.up.right")
            .font(.callout)
            .foregroundStyle(.secondary)

          Button {
            store.send(.externalAIResponsePasteButtonTapped)
          } label: {
            Label("3. Paste Result", systemImage: "doc.on.clipboard")
          }
          Spacer()
        }

        Label(
          "The prompt contains only these answers, app metadata, and connected display names and sizes — never screen contents.",
          systemImage: "lock.shield",
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Divider()

        HStack(spacing: 10) {
          Label("Quick local draft", systemImage: "apple.intelligence")
            .font(.callout.weight(.medium))
          Text("On-device")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.12), in: .capsule)
            .foregroundStyle(.green)
          Spacer()
          Button {
            store.send(.aiRecommendationButtonTapped)
          } label: {
            if store.isGeneratingRecommendation {
              HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Thinking…")
              }
            } else {
              Label("Try on This Mac", systemImage: "sparkles")
            }
          }
          .disabled(
            store.aiRecommendationAvailability != .available
              || !store.canRequestAIRecommendation
              || store.isGeneratingRecommendation
          )
        }

        if !store.canRequestAIRecommendation {
          Text("Add your role or describe a typical week to guide the draft.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if case .unavailable(let reason) = store.aiRecommendationAvailability {
          Text("Local option unavailable: \(reason)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = store.aiRecommendationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if let recommendation = store.aiRecommendation {
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Text("Review \(recommendation.workspaces.count) workspaces and \(store.aiRecommendationChangeCount) app placements")
              .font(.callout.weight(.semibold))
            FlowLayout(spacing: 8) {
              ForEach(recommendation.workspaces, id: \.name) { workspace in
                Label(
                  workspace.name,
                  systemImage: workspace.kind == .scratchpad
                    ? "rectangle.righthalf.inset.filled"
                    : "square.stack.3d.up",
                )
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                  workspace.kind == .scratchpad
                    ? Color.purple.opacity(0.1)
                    : Color.accentColor.opacity(0.09),
                  in: .capsule,
                )
              }
            }
            ForEach(store.aiRecommendationChanges) { change in
              HStack(spacing: 9) {
                AppIcon(bundleIdentifier: change.app.bundleIdentifier, iconPath: change.app.iconPath)
                  .frame(width: 22, height: 22)
                Text(change.app.name)
                Spacer()
                Image(systemName: "arrow.right")
                  .foregroundStyle(.tertiary)
                Text(change.destinationName)
                  .foregroundStyle(.secondary)
              }
              .font(.callout)
            }
            HStack {
              Spacer()
              Button("Dismiss") { store.send(.aiRecommendationDismissButtonTapped) }
              Button("Apply Plan to Draft") { store.send(.aiRecommendationApplyButtonTapped) }
                .buttonStyle(.borderedProminent)
                .disabled(recommendation.workspaces.isEmpty)
            }
          }
        }
      }
    }
  }
}

// MARK: - OnboardingSwitchingStep

private struct OnboardingSwitchingStep: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(alignment: .top, spacing: 16) {
        OnboardingShortcutCard(
          title: "Switch",
          symbols: HotKey.modifierSymbols(from: store.draft.settings.shortcuts.keyEquivalentModifiers)
            + (store.activeDemoWorkspace?.keyEquivalent?.uppercased() ?? "–"),
          detail: "Open the selected workspace",
        )
        OnboardingShortcutCard(
          title: "Assign",
          symbols: HotKey.modifierSymbols(from: store.draft.settings.shortcuts.assignModifiers)
            + (store.activeDemoWorkspace?.keyEquivalent?.uppercased() ?? "–"),
          detail: "Move the focused app there",
        )
        OnboardingShortcutCard(
          title: "Borrow",
          symbols: HotKey.modifierSymbols(from: store.draft.settings.shortcuts.borrowModifiers)
            + (store.activeDemoWorkspace?.keyEquivalent?.uppercased() ?? "–"),
          detail: "Dock it beside the current one",
        )
      }

      if let shortcut = store.demoLastShortcut {
        Label("Recognized \(shortcut.title(in: store.draft))", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.green)
      }

      OnboardingSection(
        title: "Learn switching in a virtual display",
        subtitle: "Nothing outside Guided Setup moves. Watch one window change first, then replace the whole workspace.",
      ) {
        VStack(alignment: .leading, spacing: 14) {
          Toggle(
            "Enable trackpad gestures",
            isOn: Binding(
              get: { store.draft.settings.gestures.enabled },
              set: { store.send(.demoGestureEnabledChanged($0)) },
            ),
          )
          OnboardingGesturePractice(
            enabled: store.draft.settings.gestures.enabled,
            workspaces: store.normalWorkspaces,
            activeWorkspace: store.activeDemoWorkspace,
            apps: store.gestureDemoApps,
            selectedWindowIndex: store.demoGestureWindowIndex,
            lastGesture: store.demoLastGesture,
            actionResult: store.demoActionResult,
            windowGestureCompleted: store.practices.contains(.windowGesture),
            workspaceGestureCompleted: store.practices.contains(.workspaceGesture),
            onWorkspaceTapped: { store.send(.demoWorkspaceTapped($0)) },
            onSimulate: { store.send(.demoGesturePerformed($0)) },
          )
        }
      }

      OnboardingSection(
        title: "Use the real workspace shortcuts",
        subtitle: "Press either shortcut while Guided Setup is open. The virtual display follows the same loop and skip-empty rules as Tatami.",
      ) {
        VStack(spacing: 9) {
          shortcutRow(
            "Next workspace",
            "Move forward through normal workspaces without memorizing each workspace key",
            .switchToNextWorkspace,
          )
          shortcutRow(
            "Previous workspace",
            "Move backward through the same workspace cycle",
            .switchToPreviousWorkspace,
          )
        }
      }

      OnboardingSection(title: "Switching behavior", subtitle: "These defaults keep cycling predictable as your contexts grow.") {
        VStack(alignment: .leading, spacing: 11) {
          OnboardingSettingToggle(
            title: "Loop around",
            detail: "Going past the last workspace returns to the first, so repeated Next/Previous commands never dead-end.",
            isOn: $store.draft.settings.switching.loop,
          )
          Divider()
          OnboardingSettingToggle(
            title: "Follow app focus",
            detail: "If you focus a managed app that belongs to another workspace, Tatami follows it to the owning context instead of exposing mixed contexts.",
            isOn: $store.draft.settings.switching.followAppFocus,
          )
          Divider()
          OnboardingSettingToggle(
            title: "Skip empty workspaces",
            detail: "Normal cycling ignores contexts with no assigned apps. Their direct shortcut still remains available.",
            isOn: $store.draft.settings.switching.skipEmpty,
          )
          if store.displays.count > 1 {
            Divider()
            OnboardingSettingToggle(
              title: "Cycle across all displays",
              detail: "Next/Previous walks the full profile rather than staying on the pointer display's workspace list.",
              isOn: $store.draft.settings.switching.cycleAcrossDisplays,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Recent workspace crosses displays",
              detail: "Recent may jump to the last context used on another monitor; Off keeps the recall local to one display.",
              isOn: $store.draft.settings.switching.recentAcrossDisplays,
            )
          }
        }
      }

      OnboardingRecommendationCallout(
        "Use four fingers for the larger decision — changing context — and three fingers for the local decision of cycling windows inside it."
      )
    }
  }

  // MARK: Private

  private func shortcutRow(
    _ title: LocalizedStringResource,
    _ detail: LocalizedStringResource,
    _ action: HotKeyAction,
  ) -> some View {
    OnboardingShortcutPracticeRow(
      title: title,
      detail: detail,
      action: action,
      hotKey: store.state.shortcut(for: action),
      config: store.draft,
      lastShortcut: store.demoLastShortcut,
      onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
      onChange: { store.send(.shortcutChanged(action, $0)) },
    )
  }

}

// MARK: - OnboardingTilingStep

private struct OnboardingTilingStep: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(
        title: "Learn the split tree on one workspace",
        subtitle: "Each new tiled window splits one region into two. Tatami stores that structure as a BSP tree, using the apps you assigned—not a canned demo.",
      ) {
        VStack(spacing: 12) {
          OnboardingWorkspaceContextPicker(
            workspaces: store.workspaceAppGroups,
            selectedID: store.demoActiveWorkspaceID,
            onSelect: { store.send(.demoWorkspaceSelectionChanged($0)) },
          )
          if store.demoLayoutTree == nil {
            OnboardingInlineNotice(
              icon: "square.stack.3d.up.slash",
              title: "This workspace has no assigned apps yet",
              detail: "Go back to Workspaces and assign at least two apps to practice moving and resizing tiles.",
              tint: .orange,
              buttonTitle: nil,
              action: { },
            )
          } else {
            if (store.demoLayoutTree?.windows.count ?? 0) < 2 {
              OnboardingInlineNotice(
                icon: "rectangle.split.2x1",
                title: "Add a second app to practice structural edits",
                detail: "Focus and Zoom work with one window, but Cycle, Swap, Resize, Split, and Balance become visible with at least two BSP leaves.",
                tint: .orange,
                buttonTitle: nil,
                action: { },
              )
            }
            OnboardingDemoMonitor(
              title: store.activeDemoWorkspace?.name ?? String(localized: "Tiling Lab"),
              status: String(localized: "Split-tree layout · safe draft"),
              hud: store.demoActionResult,
            ) {
              OnboardingLayoutEditor(
                tree: store.demoLayoutTree,
                apps: store.demoAppBySlot,
                selectedSlot: store.demoSelectedSlot,
                fullscreenSlots: store.demoFullscreenSlots,
                windowOrder: store.demoActiveWorkspaceID
                  .flatMap { store.demoWindowMRU[$0] } ?? [],
                innerGap: store.draft.settings.layout.gapInner,
                outerGap: store.draft.settings.layout.gapOuter,
                specialMode: nil,
                allowsEditing: true,
                onTileTapped: { store.send(.demoTileTapped(.host, $0)) },
                onTileMoved: { source, target, zone in
                  store.send(.demoTileMoved(source: source, target: target, zone: zone))
                },
                onDividerResized: { store.send(.demoDividerResized($0, $1)) },
              )
            }
            OnboardingDemoControlPanel(
              title: "Tiling controls",
              detail: "These controls act on the focused window in the virtual display above; they are not part of its screen.",
            ) {
              OnboardingLayoutToolbar { store.send(.demoCommandTapped($0)) }
            }
            OnboardingLessonPrompt(
              step: tilingLesson.step,
              title: tilingLesson.title,
              detail: tilingLesson.detail,
              completed: tilingLesson.completed,
            )
          }
        }
      }

      OnboardingSection(
        title: "Use the real shortcuts",
        subtitle: "Record a combo, then press it while Guided Setup is open. Tatami updates only this preview.",
      ) {
        VStack(spacing: 9) {
          shortcutRow("Focus right", "Move selection to another tile", .focusRight)
          shortcutRow(
            "Cycle next",
            "Walk through this Tatami context—not the global ⌘Tab list or only one app like ⌘`",
            .cycleNextWindow,
          )
          shortcutRow(
            "Swap right",
            "Exchange with the right neighbour, or turn the parent split right at an outer edge",
            .swapRight,
          )
          shortcutRow("Grow", "Adjust the selected split ratio", .resizeGrow)
          shortcutRow("Flip split", "Toggle the selected branch between horizontal and vertical", .toggleOrientation)
          shortcutRow("Zoom", "Toggle workspace fullscreen for the selected tile", .toggleFullscreen)
          shortcutRow("Balance", "Follow Auto-balance; Off rebuilds the BSP layout.", .balance)
        }
      }

      OnboardingSection(title: "Layout defaults", subtitle: "The editor above uses these gap values immediately.") {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Picker("Split direction", selection: $store.draft.settings.layout.splitType) {
              ForEach(SplitTypePreference.allCases) { type in
                Text(type.displayName).tag(type)
              }
            }
            Text(
              "Auto chooses the long axis of the available region; fixed Horizontal or Vertical makes every newly inserted branch predictable."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 4) {
            Picker("Auto-balance", selection: $store.draft.settings.layout.autoBalance) {
              ForEach(AutoBalanceMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
              }
            }
            Text(
              "Off preserves ratios you shaped by hand. Other modes may redistribute space when apps enter or leave the BSP tree."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Stepper(
            "Inner gap: \(store.draft.settings.layout.gapInner) px",
            value: $store.draft.settings.layout.gapInner,
            in: 0 ... 40,
          )
          Stepper(
            "Outer gap: \(store.draft.settings.layout.gapOuter) px",
            value: $store.draft.settings.layout.gapOuter,
            in: 0 ... 40,
          )
          Text(
            "Inner gap separates neighboring tiles. Outer gap reserves breathing room between the BSP canvas and the display edge."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }

      OnboardingRecommendationCallout(
        "Auto split, 8 px gaps, and auto-balance Off preserve the shape you create instead of flattening intentional ratios."
      )
    }
  }

  // MARK: Private

  private var tilingLesson: (
    step: LocalizedStringResource,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    completed: Bool
  ) {
    let lessons: [(OnboardingPractice, LocalizedStringResource, LocalizedStringResource)] = [
      (
        .focus,
        "Focus a neighboring tile",
        "Focus changes the target for the next command without moving any window. Click Focus or use the recorded focus shortcut.",
      ),
      (
        .cycle,
        "Cycle windows in this workspace",
        "Cycle walks through apps or windows in this Tatami context. Unlike ⌘Tab it does not search every running app, and unlike ⌘` it can cross between apps in the same context.",
      ),
      (
        .swap,
        "Swap or warp the focused tile",
        "With a neighbor, Swap exchanges BSP leaves. At an outer edge it turns the parent split toward that direction—for example, side-by-side windows can become stacked.",
      ),
      (
        .resize,
        "Resize one split",
        "Grow/Shrink changes the ratio of the split that owns the focused tile; dragging a divider writes the same value.",
      ),
      (
        .orientation,
        "Flip a split's direction",
        "Split toggles the selected branch between horizontal and vertical while keeping the same apps.",
      ),
      (
        .fullscreen,
        "Zoom one tile",
        "Zoom temporarily gives the selected tile the workspace canvas. Toggle it again to restore the remembered tree.",
      ),
      (
        .balance,
        "Balance the current layout",
        "Balance follows Auto-balance. Off rebuilds the canonical BSP layout.",
      ),
    ]
    if let index = lessons.firstIndex(where: { !store.practices.contains($0.0) }) {
      let lesson = lessons[index]
      return ("Step \(index + 1) of \(lessons.count)", lesson.1, lesson.2, false)
    }
    return (
      "Complete",
      "You exercised the full tiling toolset",
      "Focus, cycle, swap, resize, split, zoom, and balance all changed only this draft monitor.",
      true,
    )
  }

  private func shortcutRow(
    _ title: LocalizedStringResource,
    _ detail: LocalizedStringResource,
    _ action: HotKeyAction,
  ) -> some View {
    OnboardingShortcutPracticeRow(
      title: title,
      detail: detail,
      action: action,
      hotKey: store.state.shortcut(for: action),
      config: store.draft,
      lastShortcut: store.demoLastShortcut,
      onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
      onChange: { store.send(.shortcutChanged(action, $0)) },
    )
  }

}

// MARK: - OnboardingBorrowStep

private struct OnboardingBorrowStep: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    let hostGroups = store.workspaceAppGroups.filter { $0.workspace.kind == .normal }
    let borrowGroups = store.workspaceAppGroups.filter { $0.id != store.demoActiveWorkspaceID }
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(
        title: "Borrow a context",
        subtitle: "A borrowed workspace docks beside the host, then leaves without merging either layout.",
      ) {
        VStack(spacing: 14) {
          OnboardingWorkspaceContextPicker(
            label: "Host",
            workspaces: hostGroups,
            selectedID: store.demoActiveWorkspaceID,
            onSelect: { store.send(.demoWorkspaceSelectionChanged($0)) },
          )
          OnboardingWorkspaceContextPicker(
            label: "Borrow",
            workspaces: borrowGroups,
            selectedID: store.demoBorrowWorkspaceID,
            onSelect: { store.send(.demoBorrowWorkspaceTapped($0)) },
          )
          OnboardingDemoMonitor(
            title: String(localized: "Borrow Lab"),
            status: String(localized: "Two layouts · no merge"),
            hud: store.demoActionResult,
          ) {
            OnboardingBorrowDemo(
              hostName: store.activeDemoWorkspace?.name ?? String(localized: "Host workspace"),
              hostApps: store.activeDemoApps,
              borrowedName: store.demoBorrowWorkspace?.name
                ?? String(localized: "Borrowed workspace"),
              borrowedApps: store.demoBorrowApps,
              borrowed: store.demoBorrowed,
              edge: store.demoEffectiveBorrowEdge,
              fraction: store.demoEffectiveBorrowFraction,
            )
          }
          if store.demoBorrowPendingWorkspaceID != nil {
            HStack(spacing: 8) {
              Label("Choose a dock edge", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption.weight(.semibold))
              Spacer()
              borrowDirectionButton("Left", symbol: "arrow.left", edge: .left)
              borrowDirectionButton("Bottom", symbol: "arrow.down", edge: .bottom)
              borrowDirectionButton("Top", symbol: "arrow.up", edge: .top)
              borrowDirectionButton("Right", symbol: "arrow.right", edge: .right)
              Button("Cancel") { store.send(.demoBorrowCancelButtonTapped) }
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.07), in: .rect(cornerRadius: 10))
          }
          OnboardingLessonPrompt(
            step: borrowLesson.step,
            title: borrowLesson.title,
            detail: borrowLesson.detail,
            completed: borrowLesson.completed,
          )
          if let workspace = store.demoBorrowWorkspace {
            OnboardingShortcutPracticeRow(
              title: "Borrow \(workspace.name)",
              detail: borrowShortcutDetail(workspace),
              action: .borrowWorkspace(workspace.id),
              hotKey: store.state.shortcut(for: .borrowWorkspace(workspace.id)),
              config: store.draft,
              lastShortcut: store.demoLastShortcut,
              onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
              onChange: { store.send(.shortcutChanged(.borrowWorkspace(workspace.id), $0)) },
            )
          }
          HStack {
            Button {
              store.send(.demoBorrowButtonTapped)
            } label: {
              let dismisses = store.demoBorrowed
                && store.draft.settings.switching.toggleBorrowOnRepeat
              Label(
                dismisses ? "Dismiss Borrow" : (store.demoBorrowed ? "Re-dock Borrow" : "Borrow Workspace"),
                systemImage: dismisses ? "rectangle" : "rectangle.righthalf.inset.filled",
              )
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.demoBorrowWorkspace == nil)
            Spacer()
            if store.practices.contains(.borrow) {
              Label("Tried", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }
      }

      HStack(alignment: .top, spacing: 18) {
        OnboardingSection(
          title: "Borrow defaults",
          subtitle: "Choose the edge and how much room the visiting context receives.",
        ) {
          VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
              Picker("Direction", selection: $store.draft.settings.switching.borrowDefaultEdge) {
                Text("Ask every time").tag(BorrowEdge?.none)
                ForEach(BorrowEdge.allCases, id: \.self) { edge in
                  Text(edge.displayName).tag(BorrowEdge?.some(edge))
                }
              }
              Text(
                "Ask every time lets the final arrow/HJKL decide placement. A fixed edge makes the Borrow shortcut complete immediately."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            HStack {
              Text("Size")
              Slider(value: $store.draft.settings.switching.borrowFraction, in: 0.3 ... 0.7, step: 0.1)
              Text("\(Int((store.draft.settings.switching.borrowFraction * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            }
            Text(
              "Size is the visitor's share of the display; the host receives the remaining space without changing either saved layout."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            OnboardingSettingToggle(
              title: "Dismiss when summoned again",
              detail: "Repeating the same Borrow command becomes a toggle. Off keeps repeat presses idempotent until you use Dismiss Borrow.",
              isOn: $store.draft.settings.switching.toggleBorrowOnRepeat,
            )
          }
        }

        OnboardingSection(
          title: "One-app quick access",
          subtitle: "After learning Borrow, the special case is easier: Tatami calls a borrow-only, non-cycling workspace a Scratchpad.",
        ) {
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              if let scratchpadName = store.scratchpads.first?.name {
                Text(scratchpadName)
              } else {
                Text("No Scratchpad configured yet")
              }
              let scratchpadAppCount = store.scratchpads.first.map {
                store.state.apps(in: $0.id).count
              } ?? 0
              if scratchpadAppCount > 1 {
                Text("\(scratchpadAppCount) apps assigned. Scratchpads work best with exactly one.")
                  .font(.caption)
                  .foregroundStyle(.orange)
              } else {
                Text("Keep exactly one app here, such as a terminal or notes window. Then Borrow it only when needed.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            if store.scratchpads.isEmpty {
              Button("Add Quick Look") { store.send(.addScratchpadButtonTapped) }
            } else {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }
      }
    }
  }

  // MARK: Private

  private var borrowLesson: (
    step: LocalizedStringResource,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    completed: Bool
  ) {
    if !store.demoBorrowed, !store.practices.contains(.borrowDismiss) {
      return (
        "Step 1 of 2",
        "Dock the visiting workspace",
        "Borrow keeps the host and visitor as two independent layouts. With Ask every time, summon it first and then choose an edge; a fixed edge docks immediately.",
        false,
      )
    }
    if store.demoBorrowed {
      return (
        "Step 2 of 2",
        "Dismiss it without changing either layout",
        "Use Dismiss Borrow, or repeat the same summon when the repeat-toggle setting is on. The host expands and both remembered trees stay intact.",
        false,
      )
    }
    return (
      "Complete",
      "You borrowed and returned a context",
      "Borrow is temporary composition: it never moves the visiting apps into the host workspace.",
      true,
    )
  }

  private func borrowDirectionButton(
    _ title: LocalizedStringResource,
    symbol: String,
    edge: BorrowEdge,
  ) -> some View {
    Button {
      store.send(.demoBorrowDirectionTapped(edge))
    } label: {
      Image(systemName: symbol)
        .frame(width: 14, height: 14)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(Text(title))
    .accessibilityLabel(Text(title))
  }

  private func borrowShortcutDetail(_ workspace: Workspace) -> LocalizedStringResource {
    let scratchpadSwitchDetail =
      if workspace.kind == .scratchpad {
        store.state.shortcut(for: .activateWorkspace(workspace.id))
          .map {
            String(localized: "Its \($0.symbols) workspace shortcut takes this same Borrow path.")
          }
          ?? String(localized: "Its workspace shortcut takes this same Borrow path.")
      } else {
        ""
      }
    if let edge = workspace.borrowEdge ?? store.draft.settings.switching.borrowDefaultEdge {
      let edgeName = String(localized: edge.displayName)
      return "The shortcut docks on the \(edgeName). Repeating it dismisses only when ‘Dismiss when summoned again’ is on. \(scratchpadSwitchDetail)"
    }
    return "The shortcut arms Borrow first; finish with an arrow or H/J/K/L direction, just like the real command. \(scratchpadSwitchDetail)"
  }

}

// MARK: - OnboardingFloatingStep

private struct OnboardingFloatingStep: View {

  // MARK: Internal

  let store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(
        title: "Choose a workspace and app",
        subtitle: "Handling is saved on that app assignment inside this draft workspace.",
      ) {
        VStack(spacing: 12) {
          OnboardingWorkspaceContextPicker(
            workspaces: store.workspaceAppGroups,
            selectedID: store.demoActiveWorkspaceID,
            onSelect: { store.send(.demoWorkspaceSelectionChanged($0)) },
          )
          if store.demoLayoutTree == nil {
            OnboardingInlineNotice(
              icon: "rectangle.on.rectangle.slash",
              title: "Assign an app to this workspace first",
              detail: "Float and Ignore are workspace-specific contracts, so the preview needs one of its assigned apps.",
              tint: .orange,
              buttonTitle: nil,
              action: { },
            )
          } else {
            Picker(
              "App to configure",
              selection: Binding(
                get: { store.demoPrimarySlot },
                set: { if let slot = $0 { store.send(.demoTileTapped(.host, slot)) } },
              ),
            ) {
              ForEach(store.demoLayoutTree?.windows ?? [], id: \.self) { slot in
                Text(store.demoAppBySlot[slot]?.name ?? slot.bundleId)
                  .tag(SlotID?.some(slot))
              }
            }
            OnboardingDemoMonitor(
              title: store.activeDemoWorkspace?.name
                ?? String(localized: "Window Handling Lab"),
              status: String(
                localized: "Selected app · \(String(localized: store.demoLayoutMode.displayName))"
              ),
              hud: store.demoActionResult,
            ) {
              OnboardingLayoutEditor(
                tree: store.demoLayoutTree,
                apps: store.demoAppBySlot,
                selectedSlot: store.demoPrimarySlot,
                fullscreenSlots: [],
                innerGap: store.draft.settings.layout.gapInner,
                outerGap: store.draft.settings.layout.gapOuter,
                specialMode: store.demoLayoutMode,
                allowsEditing: false,
                onTileTapped: { store.send(.demoTileTapped(.host, $0)) },
                onTileMoved: { _, _, _ in },
                onDividerResized: { _, _ in },
              )
            }
            OnboardingLessonPrompt(
              step: handlingLesson.step,
              title: handlingLesson.title,
              detail: handlingLesson.detail,
              completed: handlingLesson.completed,
            )
          }
        }
      }

      OnboardingSection(
        title: "Try the floating shortcut",
        subtitle: "The global shortcut is temporarily routed into this selected app preview.",
      ) {
        OnboardingShortcutPracticeRow(
          title: "Toggle floating",
          detail: "Press again to return the selected app to the BSP tree.",
          action: .toggleFloating,
          hotKey: store.state.shortcut(for: .toggleFloating),
          config: store.draft,
          lastShortcut: store.demoLastShortcut,
          onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
          onChange: { store.send(.shortcutChanged(.toggleFloating, $0)) },
        )
      }

      OnboardingSection(title: "Handling mode", subtitle: "Choose the contract Tatami should keep with this app.") {
        VStack(spacing: 16) {
          Picker(
            "How should Tatami handle this app?",
            selection: Binding(
              get: { store.demoLayoutMode },
              set: { store.send(.demoLayoutModeChanged($0)) },
            ),
          ) {
            Label("Tiled", systemImage: "rectangle.split.2x2").tag(LayoutMode.tiled)
            Label("Floating", systemImage: "rectangle.on.rectangle").tag(LayoutMode.floating)
            Label("Ignore", systemImage: "nosign").tag(LayoutMode.unmanaged)
          }
          .pickerStyle(.segmented)

          HStack(alignment: .top, spacing: 14) {
            OnboardingModeCard(
              title: "Tiled",
              detail: "Part of the BSP tree. Tatami writes its frame.",
              selected: store.demoLayoutMode == .tiled,
            )
            OnboardingModeCard(
              title: "Floating",
              detail: "A compact mirror stays above the tiles without replacing them.",
              selected: store.demoLayoutMode == .floating,
            )
            OnboardingModeCard(
              title: "Ignore",
              detail: "The app belongs to the context, but its real window stays untouched.",
              selected: store.demoLayoutMode == .unmanaged,
            )
          }
        }
      }

      if store.demoLayoutMode == .floating, !store.hasScreenRecording {
        OnboardingInlineNotice(
          icon: "record.circle",
          title: "Floating needs Screen Recording",
          detail: "Tatami uses it only for per-window always-on-top mirrors. Ignore needs no capture permission.",
          tint: .orange,
          buttonTitle: "Grant…",
          action: { store.send(.grantScreenRecordingButtonTapped) },
        )
      }

      OnboardingRecommendationCallout(
        "Use Floating only for windows that must stay above the layout, such as a simulator or call. Prefer Ignore when the app should keep its own geometry."
      )
    }
  }

  // MARK: Private

  private var handlingLesson: (
    step: LocalizedStringResource,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    completed: Bool
  ) {
    if !store.practices.contains(.floating) {
      return (
        "Step 1 of 3",
        "Lift one app above the tiles",
        "Choose Floating. Tatami removes this app from the BSP tree and keeps a compact live mirror above the remaining tiles.",
        false,
      )
    }
    if !store.practices.contains(.ignore) {
      return (
        "Step 2 of 3",
        "Leave one app's real window untouched",
        "Choose Ignore. The app still belongs to this workspace, but Tatami stops writing its frame or replacing it with a mirror.",
        false,
      )
    }
    if !store.practices.contains(.tiledHandling) {
      return (
        "Step 3 of 3",
        "Return it to the BSP tree",
        "Choose Tiled. The app becomes a managed leaf again and shares the remembered layout with its workspace peers.",
        false,
      )
    }
    return (
      "Complete",
      "You compared all three window contracts",
      "Tiled lets Tatami place the window, Floating creates an always-on-top mirror, and Ignore preserves the app's own geometry.",
      true,
    )
  }

}

// MARK: - OnboardingFocusCyclingStep

private struct OnboardingFocusCyclingStep: View {

  // MARK: Internal

  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      OnboardingSection(
        title: "Window cycling stays inside the visible Tatami context",
        subtitle: "A borrowed block joins its host's cycle until dismissed. Tatami, ⌘Tab, and ⌘` still search three different sets of windows.",
      ) {
        VStack(alignment: .leading, spacing: 13) {
          OnboardingWindowCyclingComparison(
            tatamiShortcut: store.state.shortcut(for: .cycleNextWindow)?.symbols
              ?? String(localized: "Not set")
          )
          Divider()
          OnboardingSettingToggle(
            title: "Cycle through every window",
            detail: "On makes every context window a stop, including multiple windows from one app. Off cycles app-by-app and recalls each app's most recently used window.",
            isOn: $store.draft.settings.switching.cycleSameAppWindows,
          )
        }
      }

      OnboardingSection(
        title: "Focus and pointer on your finished layout",
        subtitle: "This final lab reuses your draft workspace. Every shortcut and gesture introduced earlier still controls the same virtual display.",
      ) {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 18) {
            OnboardingSettingToggle(
              title: "Mouse follows focus (MFF)",
              detail: "When Tatami changes the focused managed window, the pointer follows it—even across the host and a borrowed block. Focus and Cycle move it to the new window; Swap keeps it attached to that same window in its new tile.",
              isOn: $store.draft.settings.focus.mouseFollowsFocus,
            )
            OnboardingSettingToggle(
              title: "Focus follows mouse (FFM)",
              detail: "When the pointer enters any managed preview window, including a borrowed one, Tatami gives it keyboard focus. Pointer movement leads; focus follows afterward.",
              isOn: $store.draft.settings.focus.focusFollowsMouse,
            )
          }

          OnboardingWorkspaceContextPicker(
            workspaces: store.workspaceAppGroups,
            selectedID: store.demoActiveWorkspaceID,
            onSelect: { store.send(.demoWorkspaceSelectionChanged($0)) },
          )

          if store.demoLayoutTree == nil {
            OnboardingInlineNotice(
              icon: "rectangle.3.group.bubble.left.fill",
              title: "Assign an app to a normal workspace first",
              detail: "This lab uses the layout and window handling you configured in the earlier steps.",
              tint: .orange,
              buttonTitle: nil,
              action: { },
            )
          } else {
            if (store.demoLayoutTree?.windows.count ?? 0) < 2 {
              OnboardingInlineNotice(
                icon: "rectangle.split.2x1",
                title: "A second app makes focus and cycling visible",
                detail: "The controls remain available with one app, but MFF, FFM, Cycle, and directional focus are easiest to understand with at least two managed windows.",
                tint: .orange,
                buttonTitle: nil,
                action: { },
              )
            }

            OnboardingDemoMonitor(
              title: store.activeDemoWorkspace?.name
                ?? String(localized: "Focus & Cycling Lab"),
              status: monitorStatus,
              hud: store.demoActionResult,
            ) {
              OnboardingCumulativeLayoutStage(store: store)
            }

            if store.demoBorrowPendingWorkspaceID != nil {
              HStack(spacing: 8) {
                Label("Choose where the borrowed workspace should dock", systemImage: "rectangle.split.2x1")
                  .font(.caption.weight(.semibold))
                Spacer()
                borrowDirectionButton("Left", symbol: "arrow.left", edge: .left)
                borrowDirectionButton("Bottom", symbol: "arrow.down", edge: .bottom)
                borrowDirectionButton("Top", symbol: "arrow.up", edge: .top)
                borrowDirectionButton("Right", symbol: "arrow.right", edge: .right)
                Button("Cancel") { store.send(.demoBorrowCancelButtonTapped) }
                  .controlSize(.small)
              }
              .padding(10)
              .background(Color.accentColor.opacity(0.07), in: .rect(cornerRadius: 10))
            }

            OnboardingLessonPrompt(
              step: focusLesson.step,
              title: focusLesson.title,
              detail: focusLesson.detail,
              completed: focusLesson.completed,
            )

            OnboardingDemoControlPanel(
              title: "Everything learned so far",
              detail: "Use these buttons or press the real shortcuts and trackpad gestures you configured. Borrow focuses the visiting block; directional Focus can cross its shared edge, while Cycle and tiling commands stay inside the currently focused block.",
            ) {
              VStack(spacing: 12) {
                HStack(spacing: 8) {
                  Button {
                    store.send(.demoShortcutPerformed(.switchToPreviousWorkspace))
                  } label: {
                    Label("Previous workspace", systemImage: "chevron.backward.2")
                  }
                  Button {
                    store.send(.demoShortcutPerformed(.switchToNextWorkspace))
                  } label: {
                    Label("Next workspace", systemImage: "chevron.forward.2")
                  }
                  Button {
                    if store.demoBorrowed {
                      store.send(.demoShortcutPerformed(.dismissBorrow))
                    } else {
                      store.send(.demoBorrowButtonTapped)
                    }
                  } label: {
                    Label(
                      store.demoBorrowed ? "Dismiss Borrow" : "Borrow",
                      systemImage: store.demoBorrowed ? "rectangle" : "rectangle.righthalf.inset.filled",
                    )
                  }
                  .disabled(!store.demoBorrowed && store.demoBorrowWorkspace == nil)
                  Button {
                    store.send(.demoShortcutPerformed(.toggleFloating))
                  } label: {
                    Label("Toggle Floating", systemImage: "rectangle.on.rectangle")
                  }
                  Spacer()
                }
                Divider()
                OnboardingLayoutToolbar { store.send(.demoCommandTapped($0)) }
              }
            }
          }
        }
      }

      OnboardingRecommendationCallout(
        "MFF and FFM are independent. Start with both Off if you want explicit keyboard and pointer control; enable only the direction of automation that feels natural after trying it here."
      )
    }
  }

  // MARK: Private

  private var monitorStatus: String {
    let borrow = store.demoBorrowed
      ? String(
        localized:
          "Borrowed \(store.demoBorrowWorkspace?.name ?? String(localized: "workspace"))"
      )
      : String(localized: store.demoLayoutMode.displayName)
    let mff = store.draft.settings.focus.mouseFollowsFocus
      ? String(localized: "On")
      : String(localized: "Off")
    let ffm = store.draft.settings.focus.focusFollowsMouse
      ? String(localized: "On")
      : String(localized: "Off")
    return String(localized: "MFF \(mff) · FFM \(ffm) · \(borrow)")
  }

  private var focusLesson: (
    step: LocalizedStringResource,
    title: LocalizedStringResource,
    detail: LocalizedStringResource,
    completed: Bool
  ) {
    if !store.practices.contains(.mouseFollowsFocus) {
      return (
        "Step 1 of 2",
        "Let the pointer follow a Tatami focus change",
        store.draft.settings.focus.mouseFollowsFocus
          ? "Use Cycle, directional Focus, or Swap. Borrow a workspace too: its MRU window receives focus, and the virtual pointer follows across the block boundary."
          :
          "Turn MFF On, then use Cycle, directional Focus, or Swap. With MFF Off, keyboard focus can change while the virtual pointer deliberately stays behind.",
        false,
      )
    }
    if !store.practices.contains(.focusFollowsMouse) {
      return (
        "Step 2 of 2",
        "Let keyboard focus follow the pointer",
        store.draft.settings.focus.focusFollowsMouse
          ? "Move your real pointer over another host or borrowed window. Its focus ring follows without a click, and that window becomes the block's new MRU target."
          :
          "Turn FFM On, then move your real pointer over another preview window. With FFM Off, hovering does not change keyboard focus.",
        false,
      )
    }
    return (
      "Complete",
      "You separated MFF from FFM",
      "MFF starts from a Tatami focus change and moves the pointer. FFM starts from pointer movement and changes keyboard focus. Every earlier command remains available in this same lab.",
      true,
    )
  }

  private func borrowDirectionButton(
    _ title: LocalizedStringResource,
    symbol: String,
    edge: BorrowEdge,
  ) -> some View {
    Button {
      store.send(.demoBorrowDirectionTapped(edge))
    } label: {
      Label {
        Text(title)
      } icon: {
        Image(systemName: symbol)
      }
    }
    .controlSize(.small)
  }

}

// MARK: - OnboardingCumulativeLayoutStage

private struct OnboardingCumulativeLayoutStage: View {

  // MARK: Internal

  let store: StoreOf<OnboardingFeature>

  var body: some View {
    GeometryReader { geometry in
      let bounds = CGRect(origin: .zero, size: geometry.size)
      if store.demoBorrowed, let borrowed = borrowedFrames(in: bounds) {
        layoutEditor(
          tree: store.demoLayoutTree,
          apps: store.demoAppBySlot,
          frame: borrowed.host,
          selectedSlot: store.demoFocusedBlock == .host ? store.demoSelectedSlot : nil,
          fullscreenSlots: store.demoFullscreenSlots,
          windowOrder: store.demoActiveWorkspaceID
            .flatMap { store.demoWindowMRU[$0] } ?? [],
          specialMode: store.demoLayoutMode,
          pointerLocation: store.demoPointerBlock == .host ? store.demoPointerLocation : nil,
          block: .host,
        )
        layoutEditor(
          tree: store.demoBorrowLayoutTree,
          apps: store.demoBorrowAppBySlot,
          frame: borrowed.visitor,
          selectedSlot: store.demoFocusedBlock == .borrowed ? store.demoBorrowSelectedSlot : nil,
          fullscreenSlots: store.demoBorrowFullscreenSlots,
          windowOrder: store.demoBorrowWorkspaceID
            .flatMap { store.demoWindowMRU[$0] } ?? [],
          specialMode: nil,
          pointerLocation: store.demoPointerBlock == .borrowed ? store.demoPointerLocation : nil,
          block: .borrowed,
        )
      } else {
        layoutEditor(
          tree: store.demoLayoutTree,
          apps: store.demoAppBySlot,
          frame: bounds,
          selectedSlot: store.demoSelectedSlot,
          fullscreenSlots: store.demoFullscreenSlots,
          windowOrder: store.demoActiveWorkspaceID
            .flatMap { store.demoWindowMRU[$0] } ?? [],
          specialMode: store.demoLayoutMode,
          pointerLocation: store.demoPointerLocation,
          block: .host,
        )
      }
    }
    .frame(height: 330)
  }

  // MARK: Private

  private func layoutEditor(
    tree: BSPNode<SlotID>?,
    apps: [SlotID: MacApp],
    frame: CGRect,
    selectedSlot: SlotID?,
    fullscreenSlots: Set<SlotID>,
    windowOrder: [SlotID],
    specialMode: LayoutMode?,
    pointerLocation: OnboardingDemoPoint?,
    block: OnboardingDemoBlock,
  ) -> some View {
    let isHost = block == .host
    return OnboardingLayoutEditor(
      tree: tree,
      apps: apps,
      selectedSlot: selectedSlot,
      fullscreenSlots: fullscreenSlots,
      windowOrder: windowOrder,
      innerGap: store.draft.settings.layout.gapInner,
      outerGap: store.draft.settings.layout.gapOuter,
      specialMode: specialMode,
      allowsEditing: isHost,
      height: frame.height,
      pointerLocation: pointerLocation,
      tracksPointerPosition: true,
      onTileTapped: { store.send(.demoTileTapped(block, $0)) },
      onTileHovered: { slot, location in
        store.send(.demoPointerHovered(block, slot, location))
      },
      onTileMoved: { source, target, zone in
        if isHost {
          store.send(.demoTileMoved(source: source, target: target, zone: zone))
        }
      },
      onDividerResized: { path, ratio in
        if isHost { store.send(.demoDividerResized(path, ratio)) }
      },
    )
    .frame(width: frame.width, height: frame.height)
    .position(x: frame.midX, y: frame.midY)
    .overlay(alignment: .topLeading) {
      Group {
        if isHost {
          if let name = store.activeDemoWorkspace?.name {
            Text(name)
          } else {
            Text("Host")
          }
        } else if let name = store.demoBorrowWorkspace?.name {
          Text(name)
        } else {
          Text("Borrowed")
        }
      }
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.ultraThinMaterial, in: .capsule)
      .padding(8)
      .allowsHitTesting(false)
    }
  }

  private func borrowedFrames(in bounds: CGRect) -> (host: CGRect, visitor: CGRect)? {
    let gap = CGFloat(store.draft.settings.layout.gapInner)
    let fraction = CGFloat(min(0.7, max(0.3, store.demoEffectiveBorrowFraction)))
    switch store.demoEffectiveBorrowEdge {
    case .left:
      let visitorWidth = (bounds.width - gap) * fraction
      return (
        CGRect(
          x: bounds.minX + visitorWidth + gap,
          y: bounds.minY,
          width: bounds.width - visitorWidth - gap,
          height: bounds.height,
        ),
        CGRect(x: bounds.minX, y: bounds.minY, width: visitorWidth, height: bounds.height),
      )

    case .right:
      let visitorWidth = (bounds.width - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width - visitorWidth - gap,
          height: bounds.height,
        ),
        CGRect(
          x: bounds.maxX - visitorWidth,
          y: bounds.minY,
          width: visitorWidth,
          height: bounds.height,
        ),
      )

    case .top:
      let visitorHeight = (bounds.height - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY + visitorHeight + gap,
          width: bounds.width,
          height: bounds.height - visitorHeight - gap,
        ),
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: visitorHeight),
      )

    case .bottom:
      let visitorHeight = (bounds.height - gap) * fraction
      return (
        CGRect(
          x: bounds.minX,
          y: bounds.minY,
          width: bounds.width,
          height: bounds.height - visitorHeight - gap,
        ),
        CGRect(
          x: bounds.minX,
          y: bounds.maxY - visitorHeight,
          width: bounds.width,
          height: visitorHeight,
        ),
      )
    }
  }

}

// MARK: - OnboardingFinishStep

private struct OnboardingFinishStep: View {
  @Bindable var store: StoreOf<OnboardingFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if store.configurationConflict {
        OnboardingInlineNotice(
          icon: "exclamationmark.triangle.fill",
          title: "Configuration changed while Guided Setup was open",
          detail: "Reload the latest config so no external edit is overwritten.",
          tint: .orange,
          buttonTitle: "Reload",
          action: { store.send(.reloadConfigurationButtonTapped) },
        )
      }

      HStack(spacing: 14) {
        OnboardingMetric(value: "\(store.draft.profiles.count)", label: "Profiles", icon: "display.2")
        OnboardingMetric(value: "\(store.normalWorkspaces.count)", label: "Workspaces", icon: "square.stack.3d.up")
        OnboardingMetric(value: "\(store.draft.sharedApps.count)", label: "Shared Apps", icon: "square.on.square")
        OnboardingMetric(value: "\(store.practices.count)", label: "Features Tried", icon: "checkmark.circle")
      }

      OnboardingSection(
        title: "Profiles",
        subtitle: "Keep one setup for the laptop, or add another for a desk display arrangement.",
      ) {
        VStack(spacing: 14) {
          ForEach(store.draft.profiles) { profile in
            HStack(spacing: 11) {
              Image(systemName: profile.symbolIconName ?? "rectangle.stack")
                .frame(width: 22)
              TextField(
                "Profile name",
                text: Binding(
                  get: { profile.name },
                  set: { store.send(.profileNameChanged(profile.id, $0)) },
                ),
              )
              if let rule = profile.autoActivation, rule.hasConditions {
                Label("Automatic", systemImage: "display.2")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              if store.draft.profiles.count > 1 {
                Button(role: .destructive) {
                  store.send(.deleteProfileButtonTapped(profile.id))
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
            }
          }
          Button {
            store.send(.addProfileButtonTapped)
          } label: {
            Label("Add Laptop / Desk Profile", systemImage: "plus")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      OnboardingSection(
        title: "Complete command map",
        subtitle: "Every keyboard-driven Tatami action is listed here. Labs teach the state change; this map covers every directional and navigation variant.",
      ) {
        VStack(spacing: 12) {
          OnboardingCommandReference(
            config: store.draft,
            shortcut: { store.state.shortcut(for: $0) },
          )
          OnboardingLessonPrompt(
            step: "Reference",
            title: "Learn a family once, then keep its variants nearby",
            detail: "The virtual Labs demonstrate context switching, window focus, split-tree edits, Borrow, and handling modes. This map explains the remaining direction, display, profile, membership, pause, and Shared Apps variants without touching real windows.",
          )
        }
      }

      HStack(alignment: .top, spacing: 18) {
        OnboardingSection(title: "Daily behavior", subtitle: "Recommended defaults; every item stays editable in Settings.") {
          VStack(alignment: .leading, spacing: 11) {
            OnboardingSettingToggle(
              title: "Refocus when a window closes",
              detail: "When the focused window disappears, Tatami selects the next managed window instead of leaving keyboard focus nowhere.",
              isOn: $store.draft.settings.focus.refocusOnClose,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Mouse follows focus (MFF)",
              detail: "Keep the pointer attached to the focused managed window. It moves to that window's center after Tatami focus/cycle and workspace changes, focus changes caused by open/close, or a Swap that relocates the focused tile. Clicking a window preserves the click position.",
              isOn: $store.draft.settings.focus.mouseFollowsFocus,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Focus follows mouse (FFM)",
              detail: "Moving the pointer over a managed window gives it keyboard focus. Leave this Off if you prefer clicks and shortcuts to control focus explicitly.",
              isOn: $store.draft.settings.focus.focusFollowsMouse,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Show workspace icon",
              detail: "The menu bar shows the active workspace's symbol so you can identify context at a glance.",
              isOn: $store.draft.settings.menuBar.showWorkspaceIcon,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Show workspace name",
              detail: "Adds the active workspace name beside its icon. Useful while learning; it can be hidden later to save menu-bar space.",
              isOn: $store.draft.settings.menuBar.showWorkspaceName,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Show action HUDs",
              detail: "Brief overlays confirm focus, swap, resize, workspace, and layout commands without opening Settings.",
              isOn: $store.draft.settings.hud.enabled,
            )
            Divider()
            OnboardingSettingToggle(
              title: "Check for updates automatically",
              detail: "Sparkle checks in the background on Tatami's configured schedule; installing an update still remains explicit.",
              isOn: $store.draft.settings.general.checkForUpdatesAutomatically,
            )
          }
        }
        OnboardingSection(title: "After applying", subtitle: "The first real activation happens only after the draft is saved.") {
          Toggle(isOn: $store.activateAfterApplying) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Activate my first workspace")
              Text(store.hasAccessibility
                ? "After saving the TOML draft, activate the first workspace once so its real windows adopt the layout you just reviewed."
                : "Accessibility is required because this final step focuses, moves, and resizes real windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .disabled(!store.hasAccessibility)
        }
      }

      Label(
        "Your final configuration remains readable at ~/.config/tatami/config.toml.",
        systemImage: "doc.text",
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

extension OnboardingStep {
  fileprivate var subtitle: LocalizedStringResource {
    switch self {
    case .welcome: "Switch tasks, not windows."
    case .environment: "Prepare Tatami for this Mac without unnecessary access."
    case .workspaces: "Turn the apps you use into clear, independent working contexts."
    case .switching: "Choose how a whole context should arrive."
    case .tiling: "Shape the split-tree layout Tatami remembers for each workspace."
    case .borrow: "Bring one context beside another without mixing layouts."
    case .floating: "Choose what Tatami tiles, floats, or leaves untouched."
    case .focusAndCycling: "Compare focus models and rehearse the complete setup in one virtual display."
    case .finish: "Review the draft and apply everything at once."
    }
  }
}

extension OnboardingAppDestination {
  fileprivate func displayName(in config: AppConfig) -> String {
    switch self {
    case .shared: String(localized: "Shared Apps")
    case .unassigned: String(localized: "Not managed")
    case .workspace(let id): config.workspace(id: id)?.name ?? String(localized: "Workspace")
    }
  }
}
