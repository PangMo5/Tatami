// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

// MARK: - StackGroupsSection

struct StackGroupsSection: View {

  // MARK: Internal

  let groups: [StackGroup]
  let apps: [MacApp]
  let appModes: [String: LayoutMode]
  var stackAll: Binding<Bool>?
  let onSave: (StackGroup, [String: StackGroup.ID]) -> Bool
  let onRemove: (StackGroup.ID) -> Void

  var body: some View {
    let stacksAllAssignedApps = stackAll?.wrappedValue == true
    let colors = StackGroupColors.colors(for: groups, scope: stackAll.map { _ in .workspace } ?? .shared)
    Section {
      if let stackAll {
        Toggle(isOn: stackAll) {
          Text("Stack All Assigned Apps")
          if stacksAllAssignedApps, !groups.isEmpty {
            Text("Turn off to use the stack groups below again.")
          }
        }
        .accessibilityIdentifier("stack-all-assigned-apps")
      }
      ForEach(groups) { group in
        Button {
          editingGroup = group
        } label: {
          StackGroupRow(group: group, apps: apps, colorHex: colors[group.id])
            .opacity(stacksAllAssignedApps ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(stacksAllAssignedApps)
        .accessibilityIdentifier("stack-group-\(group.id)")
      }
    } header: {
      HStack {
        Text("Stack Groups")
        Spacer()
        Button {
          editingGroup = StackGroup(name: "", bundleIdentifiers: [])
        } label: {
          Label("New Stack Group", systemImage: "plus.circle")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .disabled(stacksAllAssignedApps || apps.isEmpty)
        .accessibilityIdentifier("new-stack-group")
      }
    } footer: {
      if !stacksAllAssignedApps {
        Text("Tiled windows in each group share one tile.")
      }
    }
    .sheet(item: $editingGroup) { group in
      StackGroupEditor(
        group: group,
        apps: apps,
        appModes: appModes,
        otherGroups: groups.filter { $0.id != group.id },
        isEditing: groups.contains { $0.id == group.id },
        onSave: onSave,
        onRemove: onRemove,
      )
    }
  }

  // MARK: Private

  @State private var editingGroup: StackGroup?

}

// MARK: - StackGroupRow

private struct StackGroupRow: View {

  // MARK: Internal

  let group: StackGroup
  let apps: [MacApp]
  let colorHex: String?

  var body: some View {
    let ids = Set(group.bundleIdentifiers)
    let members = apps.filter { ids.contains($0.bundleIdentifier) }
    let visibleIds = members.map(\.bundleIdentifier)
    let unresolvedIds = group.bundleIdentifiers.filter { !visibleIds.contains($0) }
    let summary = (members.map(\.name) + unresolvedIds).formatted(.list(type: .and).locale(locale))

    HStack(spacing: 10) {
      if let color = colorHex.flatMap({ Color(hex: $0) }) {
        Circle()
          .fill(color)
          .overlay { Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 0.5) }
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      }
      HStack(spacing: -8) {
        ForEach((visibleIds + unresolvedIds).prefix(3), id: \.self) { id in
          AppIcon(bundleIdentifier: id, iconPath: apps.first { $0.bundleIdentifier == id }?.iconPath)
            .frame(width: 24, height: 24)
        }
      }
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(group.name)
        if summary != group.name {
          Text(summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
  }

  // MARK: Private

  @Environment(\.locale) private var locale

}

// MARK: - StackGroupEditor

private struct StackGroupEditor: View {

  // MARK: Lifecycle

  init(
    group: StackGroup,
    apps: [MacApp],
    appModes: [String: LayoutMode],
    otherGroups: [StackGroup],
    isEditing: Bool,
    onSave: @escaping (StackGroup, [String: StackGroup.ID]) -> Bool,
    onRemove: @escaping (StackGroup.ID) -> Void,
  ) {
    self.group = group
    self.apps = apps
    self.appModes = appModes
    self.otherGroups = otherGroups
    self.isEditing = isEditing
    self.onSave = onSave
    self.onRemove = onRemove
    _name = State(initialValue: group.name)
    _selected = State(initialValue: Set(group.bundleIdentifiers).intersection(apps.map(\.bundleIdentifier)))
  }

  // MARK: Internal

  let group: StackGroup
  let apps: [MacApp]
  let appModes: [String: LayoutMode]
  let otherGroups: [StackGroup]
  let isEditing: Bool
  let onSave: (StackGroup, [String: StackGroup.ID]) -> Bool
  let onRemove: (StackGroup.ID) -> Void

  var body: some View {
    let request = namingRequest
    let occupied = apps.compactMap { app in
      owner(of: app).map { PendingAppMove(app: app, source: $0) }
    }.filter { moves[$0.app.bundleIdentifier] != $0.source.id }
    let available = apps.filter { app in
      owner(of: app).map { moves[app.bundleIdentifier] == $0.id } ?? true
    }

    VStack(alignment: .leading, spacing: 0) {
      StackGroupEditorHeader(isEditing: isEditing)

      Form {
        Section {
          if available.isEmpty {
            Text("Your apps already have groups.")
              .foregroundStyle(.secondary)
          }
          ForEach(available, id: \.bundleIdentifier) { app in
            let isSelected = selected.contains(app.bundleIdentifier)
            Button {
              toggle(app)
            } label: {
              HStack {
                StackGroupAppLabel(app: app, detail: detail(for: app))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                  .symbolRenderingMode(.hierarchical)
                  .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                  .accessibilityHidden(true)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("stack-group-app-\(app.bundleIdentifier)")
          }
        } header: {
          Text("Apps")
        } footer: {
          if selected.contains(where: { nonTiledMode(for: $0) != nil }) {
            Text("Included apps with another layout join when you set them to Tiled.")
          }
        }

        if !occupied.isEmpty {
          Section {
            DisclosureGroup {
              ForEach(occupied) { move in
                HStack {
                  StackGroupAppLabel(app: move.app, detail: detail(for: move.app, group: move.source.name))
                  Spacer()
                  Button("Move…") {
                    pendingMove = move
                    confirmsMove = true
                  }
                  .accessibilityLabel(Text("Move \(move.app.name)"))
                  .accessibilityIdentifier("move-stack-group-app-\(move.app.bundleIdentifier)")
                }
              }
            } label: {
              Text("Apps in Other Groups")
                .accessibilityIdentifier("apps-in-other-stack-groups")
            }
          }
        }

        Section("Name") {
          HStack {
            TextField("Name", text: $name, prompt: Text(defaultName))
              .labelsHidden()
              .accessibilityIdentifier("stack-group-name")
            if isSuggestingName {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Suggesting a group name…")
            } else if matchingSuggestion != nil {
              Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .help("Suggested by Apple Intelligence")
                .accessibilityLabel("Suggested by Apple Intelligence")
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      StackGroupEditorButtons(
        isEditing: isEditing,
        canSave: !selected.isEmpty && !isSuggestingName,
        onRemove: { confirmsRemoval = true },
        onCancel: { dismiss() },
        onSave: save,
      )
    }
    .frame(width: 460, height: 515)
    .task(id: request) { await suggestName(for: request) }
    .confirmationDialog("Remove Stack Group?", isPresented: $confirmsRemoval) {
      Button("Remove", role: .destructive) {
        onRemove(group.id)
        dismiss()
      }
    }
    .alert("Move App to This Group?", isPresented: $confirmsMove, presenting: pendingMove) { move in
      Button("Move App") {
        moves[move.app.bundleIdentifier] = move.source.id
        selected.insert(move.app.bundleIdentifier)
      }
      Button("Cancel", role: .cancel) { }
    } message: { move in
      if move.source.bundleIdentifiers.allSatisfy({
        $0 == move.app.bundleIdentifier || moves[$0] == move.source.id
      }) {
        Text("“\(move.app.name)” will move when you save. “\(move.source.name)” will be removed because it will be empty.")
      } else {
        Text("“\(move.app.name)” will move from “\(move.source.name)” when you save.")
      }
    }
    .alert("Stack Groups Changed", isPresented: $saveNeedsReview) {
      Button("OK", role: .cancel) { }
    } message: {
      Text("Review the apps and their groups, then save again.")
    }
  }

  // MARK: Private

  private struct NameResult {
    let request: StackGroupNameSuggestion.Request
    let suggestion: StackGroupNameSuggestion?
  }

  private struct PendingAppMove: Identifiable {
    let app: MacApp
    let source: StackGroup

    var id: String {
      app.bundleIdentifier
    }
  }

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @State private var name: String
  @State private var selected: Set<String>
  @State private var moves = [String: StackGroup.ID]()
  @State private var nameResult: NameResult?
  @State private var pendingMove: PendingAppMove?
  @State private var confirmsMove = false
  @State private var confirmsRemoval = false
  @State private var saveNeedsReview = false

  private var selectedApps: [MacApp] {
    apps.filter { selected.contains($0.bundleIdentifier) }
  }

  private var customName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var namingRequest: StackGroupNameSuggestion.Request? {
    let apps = selectedApps
    guard customName.isEmpty, !apps.isEmpty else { return nil }
    return .init(apps: apps, locale: locale)
  }

  private var isSuggestingName: Bool {
    namingRequest.map { $0 != nameResult?.request } ?? false
  }

  private var matchingSuggestion: StackGroupNameSuggestion? {
    nameResult.flatMap { $0.request == namingRequest ? $0.suggestion : nil }
  }

  private var defaultName: String {
    if let suggestion = matchingSuggestion {
      return suggestion.name
    }
    let apps = selectedApps
    guard let first = apps.first else { return "" }
    if apps.count == 1 {
      return first.name
    }

    let base = String(localized: "App Stack", locale: locale)
    let existing = Set(otherGroups.map(\.name))
    guard existing.contains(base) else { return base }
    for index in 2 ... (existing.count + 1) {
      let name = "\(base) \(index.formatted(.number.locale(locale)))"
      if !existing.contains(name) {
        return name
      }
    }
    return base
  }

  private func suggestName(for request: StackGroupNameSuggestion.Request?) async {
    guard let request, request != nameResult?.request else { return }
    let result = await StackGroupNameSuggestion.generate(for: request)
    guard !Task.isCancelled, request == namingRequest else { return }
    nameResult = NameResult(request: request, suggestion: result)
  }

  private func nonTiledMode(for bundleId: String) -> LayoutMode? {
    guard let mode = appModes[bundleId], mode != .tiled else { return nil }
    return mode
  }

  private func detail(for app: MacApp, group: String? = nil) -> String? {
    let mode = nonTiledMode(for: app.bundleIdentifier).map { String(localized: $0.displayName) }
    let parts = [group, mode].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func owner(of app: MacApp) -> StackGroup? {
    otherGroups.first { $0.bundleIdentifiers.contains(app.bundleIdentifier) }
  }

  private func toggle(_ app: MacApp) {
    let id = app.bundleIdentifier
    if selected.contains(id) {
      selected.remove(id)
      moves.removeValue(forKey: id)
    } else {
      selected.insert(id)
    }
  }

  private func save() {
    let updated = StackGroup(
      id: group.id,
      name: customName.isEmpty ? defaultName : customName,
      bundleIdentifiers: selected.sorted(),
    )
    if onSave(updated, moves) {
      dismiss()
    } else {
      saveNeedsReview = true
    }
  }

}

// MARK: - StackGroupEditorHeader

private struct StackGroupEditorHeader: View {
  let isEditing: Bool

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "rectangle.stack.fill")
        .font(.system(size: 24, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.tint)
        .frame(width: 42, height: 42)
        .background(.tint.opacity(0.12), in: .rect(cornerRadius: 11))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(isEditing ? "Edit Stack Group" : "New Stack Group")
          .font(.title2.weight(.semibold))
        Text("Tiled windows in this group share one tile.")
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
  }
}

// MARK: - StackGroupAppLabel

private struct StackGroupAppLabel: View {
  let app: MacApp
  var detail: String?

  var body: some View {
    HStack(spacing: 9) {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - StackGroupEditorButtons

private struct StackGroupEditorButtons: View {
  let isEditing: Bool
  let canSave: Bool
  let onRemove: () -> Void
  let onCancel: () -> Void
  let onSave: () -> Void

  var body: some View {
    HStack {
      if isEditing {
        Button("Remove Stack Group", role: .destructive, action: onRemove)
          .accessibilityIdentifier("remove-stack-group")
      }
      Spacer()
      Button("Cancel", role: .cancel, action: onCancel)
        .keyboardShortcut(.cancelAction)
      Button("Save", action: onSave)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier("save-stack-group")
    }
    .padding(16)
  }
}
