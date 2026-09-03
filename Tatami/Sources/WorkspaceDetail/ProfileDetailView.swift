// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit

private enum CountMode: Hashable { case any, exactly, atLeast, atMost }
/// Per-monitor requirement in the auto-activation editor.
private enum DisplayReq: Hashable { case any, required, excluded }

/// Settings for the selected profile — name, switch shortcut, auto-activation
/// rule, activate + delete. Shown in the detail pane like a workspace's detail.
struct ProfileDetailView: View {
  @Bindable var store: StoreOf<ProfileDetailFeature>
  @State private var symbolPickerPresented = false
  @State private var syncReview: ProfileSyncReview?
  @State private var workspaceChainEditor: WorkspaceChainEditorPresentation?

  var body: some View {
    if let profile = store.profile {
      Form {
        Section {
          // Icon — opens the SF Symbol grid on tap. Centered HStack (not
          // LabeledContent) so the label aligns to the taller icon button.
          HStack {
            Text("Icon")
            Spacer()
            Button {
              symbolPickerPresented = true
            } label: {
              Image(systemName: profile.symbolIconName ?? "rectangle.stack")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Choose an icon for this profile.")
            .sheet(isPresented: $symbolPickerPresented) {
              SymbolPicker(
                selected: profile.symbolIconName,
                onSelect: { store.send(.symbolIconChanged($0)) }
              )
            }
          }

          HStack {
            Text("Name")
            Spacer(minLength: 16)
            TextField("", text: Binding(
              get: { profile.name },
              set: { store.send(.nameChanged($0)) },
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
            .accessibilityLabel("Name")
          }
        }

        Section {
          ShortcutRecorder(
            hotKey: profile.shortcut,
            accessibilityLabel: "Switch Shortcut",
            conflict: { store.state.shortcutConflict(for: $0) },
            onRecordingChanged: { store.send(.shortcutRecordingChanged($0)) },
            onChange: { store.send(.shortcutChanged($0)) }
          )
        } header: {
          Text("Switch Shortcut")
        } footer: {
          Text("Press to switch to this profile from anywhere.")
            .font(.caption).foregroundStyle(.secondary)
        }

        autoActivationSection(profile)
        ProfileWorkspaceChainsSection(
          store: store,
          editor: $workspaceChainEditor,
        )
        syncSection
      }
      .formStyle(.grouped)
      .navigationTitle(profile.name)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.activateTapped)
          } label: {
            Label(
              store.isActive ? "Active" : "Activate",
              systemImage: store.isActive ? "checkmark.circle.fill" : "play.fill"
            )
          }
          .disabled(store.isActive)
          .help(store.isActive ? "This profile is already active." : "Activate this profile.")
        }
      }
      // Keyed on the profile so it re-fetches the display list on every
      // selection — a plain `.task` fires only on first appearance, so
      // switching to another profile and back left the list empty (the detail
      // pane view is reused, just re-scoped to a fresh state). Mirrors
      // WorkspaceDetailView.
      .task(id: store.profileId) { store.send(.onAppear) }
      .sheet(item: $workspaceChainEditor) { presentation in
        WorkspaceChainEditorView(
          store: store,
          chain: presentation.chain,
          original: presentation.original,
        )
      }
      .sheet(item: $syncReview) { review in
        SyncPreviewSheet(
          title: "Copy from “\(review.source.name)”",
          message: "Copy each change from “\(review.source.name)” into this profile's matching workspaces (by name). Uncheck anything you'd rather keep.",
          applyTitle: "Copy",
          groups: profileSyncGroups(review),
          validateSelection: { excluded in
            profileSyncConflicts(review, excluding: excluded)
          },
          onApply: { excluded in applyProfileSync(review, excluding: excluded) }
        )
      }
      .alert($store.scope(state: \.alert, action: \.alert))
    } else {
      ContentUnavailableView(
        "Profile Unavailable",
        systemImage: "rectangle.stack",
        description: Text("This profile no longer exists.")
      )
    }
  }

  // MARK: - Sync apps from another profile

  /// Profiles keep independent workspaces, so assignments and settings can
  /// drift. This previews another profile's apps and workspace settings for
  /// same-named workspaces, then copies only the changes the user selects.
  @ViewBuilder
  private var syncSection: some View {
    let others = store.config.profiles.filter { $0.id != store.profileId }
    if !others.isEmpty {
      Section {
        ForEach(others, id: \.id) { source in
          syncRow(source)
        }
      } header: {
        Text("Copy")
      } footer: {
        Text("Review another profile's differences and copy the ones you pick into this profile's matching workspaces (by name).")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func syncRow(_ source: Profile) -> some View {
    let diverged = store.config.workspacesDiffering(in: store.profileId, comparedTo: source.id)
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(source.name)
        Text(diverged.isEmpty
          ? "No differences"
          : diverged.count == 1
            ? "\(diverged.count) workspace differs"
            : "\(diverged.count) workspaces differ")
          .font(.caption)
          .foregroundStyle(diverged.isEmpty ? Color.secondary : Color.orange)
      }
      Spacer()
      Button("Copy from…") {
        let baseline = store.config
        guard let snapshot = baseline.profiles.first(where: { $0.id == source.id })
        else { return }
        syncReview = ProfileSyncReview(
          baseline: baseline,
          source: snapshot,
          targetProfileId: store.profileId
        )
      }
        .disabled(diverged.isEmpty)
    }
  }

  /// One group per this-profile workspace that has changes vs the same-named
  /// source workspace; items are namespaced by workspace id so `onApply` can
  /// map excluded ids back per workspace.
  private func profileSyncGroups(_ review: ProfileSyncReview) -> [SyncChangeGroup] {
    guard let target = review.baseline.profiles.first(where: { $0.id == review.targetProfileId })
    else { return [] }
    var groups: [SyncChangeGroup] = []
    for ws in target.workspaces {
      guard let match = review.source.workspaces.first(where: { $0.name == ws.name }) else { continue }
      let appChanges = WorkspaceSync.appChanges(from: match.apps, to: ws.apps)
      let fieldChanges = WorkspaceSync.fieldChanges(from: match, to: ws)
      guard !appChanges.isEmpty || !fieldChanges.isEmpty else { continue }
      let prefix = "\(ws.id.uuidString):"
      let items = appChanges.map { SyncChangeItem($0, prefix: prefix) }
        + fieldChanges.map { SyncChangeItem($0, prefix: prefix) }
      groups.append(SyncChangeGroup(
        id: ws.id.uuidString, title: ws.name,
        symbol: ws.symbolIconName ?? "square.stack.3d.up", items: items
      ))
    }
    return groups
  }

  private func applyProfileSync(
    _ review: ProfileSyncReview,
    excluding excluded: Set<String>
  ) {
    let exclusions = profileSyncExclusions(excluded)
    store.send(.applyProfileSync(
      target: review.targetProfileId,
      source: review.source.id,
      baseline: review.baseline,
      excludedApps: exclusions.apps,
      excludedFields: exclusions.fields
    ))
  }

  /// Validate exactly the options currently effective in the sheet by applying
  /// them to a temporary config. Grouping by the chooser's namespaced field id
  /// lets a conflict involving two selected workspaces highlight both rows.
  private func profileSyncConflicts(
    _ review: ProfileSyncReview,
    excluding excluded: Set<String>
  ) -> [String: [WorkspaceShortcutConflict]] {
    let exclusions = profileSyncExclusions(excluded)
    guard let projection = review.baseline.profileSyncProjection(
      into: review.targetProfileId,
      from: review.source.id,
      excludedAppsByWorkspace: exclusions.apps,
      excludedFieldsByWorkspace: exclusions.fields
    ) else { return [:] }
    return Dictionary(grouping: projection.conflicts) { conflict in
      let prefix = "\(conflict.selection.workspaceId.uuidString):"
      return SyncChangeItem.fieldId(prefix, conflict.selection.field.rawValue)
    }
  }

  private func profileSyncExclusions(
    _ excluded: Set<String>
  ) -> (apps: [Workspace.ID: Set<String>], fields: [Workspace.ID: Set<String>]) {
    var excApps: [Workspace.ID: Set<String>] = [:]
    var excFields: [Workspace.ID: Set<String>] = [:]
    for id in excluded {
      // "<wsUUID>:app:<bundleId>" or "<wsUUID>:field:<fieldId>"
      let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count == 3, let wsId = UUID(uuidString: String(parts[0])) else { continue }
      let key = String(parts[2])
      if parts[1] == "app" { excApps[wsId, default: []].insert(key) }
      else if parts[1] == "field" { excFields[wsId, default: []].insert(key) }
    }
    return (excApps, excFields)
  }

  private struct ProfileSyncReview: Identifiable {
    let baseline: AppConfig
    let source: Profile
    let targetProfileId: Profile.ID

    var id: String {
      "\(targetProfileId.uuidString):\(source.id.uuidString)"
    }
  }

  // MARK: - Auto-activation editor

  /// Persist the edited rule. While auto-activation is on, an all-Any rule is a
  /// deliberate catch-all (kept non-nil); the section's toggle owns `nil` (off).
  private func emit(_ rule: ProfileActivation) {
    store.send(.autoActivationChanged(rule))
  }

  @ViewBuilder
  private func autoActivationSection(_ profile: Profile) -> some View {
    let enabled = profile.autoActivation != nil
    let cur = profile.autoActivation ?? ProfileActivation()
    Section {
      Toggle("Auto-activate this profile", isOn: Binding(
        get: { enabled },
        // On → keep/seed a rule (empty = catch-all); off → nil (manual only).
        set: { on in store.send(.autoActivationChanged(on ? cur : nil)) }
      ))

      if enabled {
        if !cur.hasConditions {
          Label {
            Text("No conditions — activates on any configuration. Add a monitor condition below to narrow it.")
          } icon: {
            Image(systemName: "info.circle")
          }
          .font(.caption).foregroundStyle(.secondary)
        }

        Picker("Monitor count", selection: Binding<CountMode>(
          get: {
            switch cur.displayCount {
            case .none: .any
            case .exactly: .exactly
            case .atLeast: .atLeast
            case .atMost: .atMost
            }
          },
          set: { mode in
            let n = cur.displayCount.map(count) ?? max(1, store.availableDisplays.count)
            var next = cur
            switch mode {
            case .any: next.displayCount = nil
            case .exactly: next.displayCount = .exactly(n)
            case .atLeast: next.displayCount = .atLeast(n)
            case .atMost: next.displayCount = .atMost(n)
            }
            emit(next)
          }
        )) {
          Text("Any").tag(CountMode.any)
          Text("Exactly").tag(CountMode.exactly)
          Text("At least").tag(CountMode.atLeast)
          Text("At most").tag(CountMode.atMost)
        }
        if let dc = cur.displayCount {
          Stepper(
            count(dc) == 1
              ? "\(count(dc)) monitor"
              : "\(count(dc)) monitors",
            value: Binding<Int>(
              get: { count(dc) },
              set: { n in
                var next = cur
                switch dc {
                case .exactly: next.displayCount = .exactly(n)
                case .atLeast: next.displayCount = .atLeast(n)
                case .atMost: next.displayCount = .atMost(n)
                }
                emit(next)
              }
            ),
            in: 1 ... 8
          )
          .padding(.leading, 12)
        }

        // Per-monitor requirement: Required (must be connected) / Excluded
        // (must be unplugged) / Any. Clearer than separate lists.
        if store.availableDisplays.isEmpty {
          Text("No monitors detected yet.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ForEach(store.availableDisplays, id: \.self) { display in
            Picker(display.name, selection: Binding<DisplayReq>(
              get: {
                if cur.whenDisconnected.contains(where: { $0.matches(display) }) { return .excluded }
                if cur.whenConnected?.displays.contains(where: { $0.matches(display) }) ?? false { return .required }
                return .any
              },
              set: { req in
                var required = (cur.whenConnected?.displays ?? []).filter { !$0.matches(display) }
                var excluded = cur.whenDisconnected.filter { !$0.matches(display) }
                switch req {
                case .any: break
                case .required: required.append(display)
                case .excluded: excluded.append(display)
                }
                var next = cur
                next.whenConnected = required.isEmpty ? nil : .contains(required)
                next.whenDisconnected = excluded
                emit(next)
              }
            )) {
              Text("Any").tag(DisplayReq.any)
              Text("Required").tag(DisplayReq.required)
              Text("Excluded").tag(DisplayReq.excluded)
            }
          }
        }

        let diagnostic = store.autoActivationDiagnostic
        if !diagnostic.isEmpty { diagnosticRows(diagnostic) }
      }
    } header: {
      Text("Auto-Activation")
    } footer: {
      Text("When on, auto-switch to this profile as the monitors match — all conditions apply together. Per monitor: Required = must be connected, Excluded = must be unplugged.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func count(_ rule: CountRule) -> Int {
    switch rule { case .exactly(let n), .atLeast(let n), .atMost(let n): n }
  }

  // MARK: - Overlap diagnostic

  /// Inline warning (equal-specificity conflict) + info (intended shadowing)
  /// about how this profile's rule overlaps the others'.
  @ViewBuilder
  private func diagnosticRows(_ d: ProfileActivationDiagnostic) -> some View {
    if !d.ambiguousWith.isEmpty {
      Label {
        Text("Also matches \(quoted(d.ambiguousWith)) at the same priority — profile order decides which one activates. Make one more specific, or reorder them in the sidebar.")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      }
      .font(.caption)
    }
    if !d.shadowedBy.isEmpty {
      Label {
        Text("Overlaps \(quoted(d.shadowedBy)) — more specific, so it wins where both match.")
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
    if !d.shadows.isEmpty {
      Label {
        Text("Wins over \(quoted(d.shadows)) where both match.")
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func quoted(_ names: [String]) -> String {
    names.map { "“\($0)”" }.joined(separator: ", ")
  }
}
