// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import TatamiKit

/// One reviewable change row in the sync preview. `id` is namespaced by the
/// caller so it can map an excluded id back to a workspace + app/field.
struct SyncChangeItem: Identifiable {
  let id: String
  /// Optional parent toggle. When it is off this item stays remembered but is
  /// disabled and treated as excluded, so re-enabling the parent restores the
  /// user's per-item choices.
  let parentId: String?
  let title: String
  let detail: String
  /// Colors the detail line — conveys add (green) / remove (red) / change.
  let detailTint: Color
  /// Leading SF Symbol (nil when a real app icon is shown instead).
  let symbol: String?
  let symbolTint: Color
  /// When set, the leading glyph is the app's real icon instead of a symbol.
  let appBundleId: String?
  let appIconPath: String?

  init(
    id: String,
    parentId: String? = nil,
    title: String,
    detail: String,
    detailTint: Color,
    symbol: String?,
    symbolTint: Color,
    appBundleId: String?,
    appIconPath: String?
  ) {
    self.id = id
    self.parentId = parentId
    self.title = title
    self.detail = detail
    self.detailTint = detailTint
    self.symbol = symbol
    self.symbolTint = symbolTint
    self.appBundleId = appBundleId
    self.appIconPath = appIconPath
  }
}

/// A titled group of changes (a workspace, or "Apps" / "Settings"). `symbol`
/// is the SF Symbol shown beside the title — e.g. the workspace's own icon.
struct SyncChangeGroup: Identifiable {
  let id: String
  let title: String
  var symbol: String? = nil
  let items: [SyncChangeItem]
}

extension SyncChangeItem {
  /// App-id key (namespaced): `"<prefix>app:<bundleId>"`.
  static func appId(_ prefix: String, _ bundleId: String) -> String { "\(prefix)app:\(bundleId)" }
  /// Field-id key (namespaced): `"<prefix>field:<fieldId>"`.
  static func fieldId(_ prefix: String, _ fieldId: String) -> String { "\(prefix)field:\(fieldId)" }

  init(_ change: AppChange, prefix: String, parentId: String? = nil) {
    let title: String, detail: String, tint: Color, app: AppAssignment
    switch change.kind {
    case .add(let a):
      (title, detail, tint, app) = (
        a.name,
        String(localized: "Add · \(String(localized: a.layout.displayName))"),
        .green,
        a
      )
    case .remove(let a):
      (title, detail, tint, app) = (a.name, String(localized: "Remove"), .red, a)
    case let .modify(before, after):
      var parts: [String] = []
      if before.layout != after.layout {
        parts.append(
          String(
            localized:
              "\(String(localized: before.layout.displayName)) → \(String(localized: after.layout.displayName))"
          )
        )
      }
      if before.autoOpen != after.autoOpen {
        parts.append(
          after.autoOpen
            ? String(localized: "Auto-open on")
            : String(localized: "Auto-open off")
        )
      }
      (title, detail, tint, app) = (after.name, parts.joined(separator: " · "), .orange, after)
    }
    self.init(
      id: Self.appId(prefix, change.bundleId), parentId: parentId,
      title: title, detail: detail, detailTint: tint,
      symbol: nil, symbolTint: .secondary,
      appBundleId: app.bundleIdentifier, appIconPath: app.iconPath
    )
  }

  init(_ change: WorkspaceFieldChange, prefix: String, parentId: String? = nil) {
    var symbol = "pencil"
    var symbolTint: Color = .secondary
    var appBundleId: String?
    switch change {
    case let .icon(_, after):
      // Show the resulting icon itself.
      symbol = after ?? "rectangle.stack"
      symbolTint = .accentColor
    case .keyEquivalent: symbol = "keyboard"
    case .kind: symbol = "rectangle.3.group"
    case let .appToFocus(_, after):
      if let after { appBundleId = after } else { symbol = "cursorarrow.rays" }
    case .displayHint: symbol = "display"
    case .borrowEdge: symbol = "rectangle.righthalf.inset.filled"
    case .borrowFraction: symbol = "rectangle.split.2x1"
    case .activateShortcut, .assignAppShortcut, .borrowShortcut: symbol = "command"
    }
    self.init(
      id: Self.fieldId(prefix, change.id), parentId: parentId,
      title: String(localized: change.label),
      detail: "\(change.beforeText) → \(change.afterText)", detailTint: .secondary,
      symbol: appBundleId == nil ? symbol : nil, symbolTint: symbolTint,
      appBundleId: appBundleId, appIconPath: nil
    )
  }
}

/// A sheet that previews a set of changes grouped for review, each toggleable,
/// and hands the caller back the ids the user *unchecked* on Apply.
struct SyncPreviewSheet: View {
  let title: LocalizedStringResource
  let message: LocalizedStringResource
  let applyTitle: LocalizedStringResource
  let groups: [SyncChangeGroup]
  /// Duplicate can intentionally create an empty shell after every content
  /// option is unchecked. Existing Copy flows still require one selection.
  let allowsEmptySelection: Bool
  /// Validates the complete effective selection after projecting it into the
  /// destination config. Keys are chooser item ids so each contributing field
  /// can explain why Apply is unavailable.
  let validateSelection: (_ excludedItemIds: Set<String>) -> [String: [WorkspaceShortcutConflict]]
  let onApply: (_ excludedItemIds: Set<String>) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String>

  init(
    title: LocalizedStringResource,
    message: LocalizedStringResource,
    applyTitle: LocalizedStringResource = "Apply",
    groups: [SyncChangeGroup],
    allowsEmptySelection: Bool = false,
    validateSelection: @escaping (Set<String>) -> [String: [WorkspaceShortcutConflict]] = { _ in [:] },
    onApply: @escaping (Set<String>) -> Void
  ) {
    self.title = title
    self.message = message
    self.applyTitle = applyTitle
    self.groups = groups
    self.allowsEmptySelection = allowsEmptySelection
    self.validateSelection = validateSelection
    self.onApply = onApply
    _selected = State(initialValue: Set(groups.flatMap { $0.items.map(\.id) }))
  }

  private var allIds: Set<String> { Set(groups.flatMap { $0.items.map(\.id) }) }

  private var effectiveSelection: Set<String> {
    let parentByItemID = Dictionary(
      uniqueKeysWithValues: groups.flatMap(\.items).compactMap { item in
        item.parentId.map { (item.id, $0) }
      }
    )
    return WorkspaceSync.effectiveSelection(
      selected: selected,
      validIDs: allIds,
      parentByItemID: parentByItemID
    )
  }

  var body: some View {
    let selection = effectiveSelection
    let excluded = allIds.subtracting(selection)
    let conflictsByItem = validateSelection(excluded)
    let hasShortcutConflicts = !conflictsByItem.values.allSatisfy(\.isEmpty)

    NavigationStack {
      Form {
        Section {
          Text(message).font(.callout).foregroundStyle(.secondary)
          if hasShortcutConflicts {
            Label {
              Text("Deselect the highlighted shortcut changes to continue.")
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)
          }
        }
        ForEach(groups) { group in
          Section {
            ForEach(group.items) { item in
              SyncChangeRow(
                item: item,
                conflicts: conflictsByItem[item.id] ?? [],
                isSelected: $selected[contains: item.id],
                isParentSelected: item.parentId.map(selected.contains) ?? true,
              )
            }
          } header: {
            if let symbol = group.symbol {
              Label(group.title, systemImage: symbol)
            } else {
              Text(group.title)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(applyTitle) {
            onApply(excluded)
            dismiss()
          }
          .disabled((!allowsEmptySelection && selection.isEmpty) || hasShortcutConflicts)
          .help(
            hasShortcutConflicts
              ? "Deselect the conflicting shortcut changes before applying."
              : ""
          )
        }
      }
    }
    .frame(width: 480, height: 560)
  }
}

private struct SyncChangeRow: View {
  let item: SyncChangeItem
  let conflicts: [WorkspaceShortcutConflict]
  @Binding var isSelected: Bool
  let isParentSelected: Bool

  var body: some View {
    Toggle(isOn: $isSelected) {
      HStack(spacing: 8) {
        leading.frame(width: 20, height: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.title)
          if !item.detail.isEmpty {
            Text(item.detail)
              .font(.caption)
              .foregroundStyle(item.detailTint)
          }
          if !conflicts.isEmpty {
            Label {
              Text("Conflicts with \(conflictDescriptions)")
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
          }
        }
      }
    }
    .disabled(!isParentSelected)
    .accessibilityHint(
      conflicts.isEmpty
        ? ""
        : "Deselect this change to resolve the shortcut conflict."
    )
  }

  private var conflictDescriptions: String {
    Set(conflicts.map { "\($0.hotKey.symbols): \($0.owner)" })
      .sorted()
      .formatted()
  }

  @ViewBuilder
  private var leading: some View {
    if let bundleId = item.appBundleId {
      AppIcon(bundleIdentifier: bundleId, iconPath: item.appIconPath)
    } else if let symbol = item.symbol {
      Image(systemName: symbol)
        .foregroundStyle(item.symbolTint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private extension Set {
  subscript(contains element: Element) -> Bool {
    get { contains(element) }
    set {
      if newValue {
        insert(element)
      } else {
        remove(element)
      }
    }
  }
}
