// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI
import TatamiKit

// MARK: - WorkspaceChainEditorPresentation

struct WorkspaceChainEditorPresentation: Identifiable, Equatable {
  let id = UUID()
  let chain: WorkspaceChain
  let original: WorkspaceChain?

  static func editing(_ chain: WorkspaceChain) -> Self {
    Self(chain: chain, original: chain)
  }

  static func creating(_ chain: WorkspaceChain) -> Self {
    Self(chain: chain, original: nil)
  }
}

// MARK: - ProfileWorkspaceChainsSection

/// Profile-scoped overview. A chain is symmetric, so it lives beside profile
/// activation rather than under any one workspace detail.
struct ProfileWorkspaceChainsSection: View {

  // MARK: Internal

  @Bindable var store: StoreOf<ProfileDetailFeature>
  @Binding var editor: WorkspaceChainEditorPresentation?

  var body: some View {
    if let profile = store.profile {
      Section {
        if profile.workspaceChains.isEmpty {
          Text("No workspace chains yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(chainEntries(in: profile)) { entry in
            WorkspaceChainSettingsRow(
              chain: entry.chain,
              profile: profile,
              hasIssues: validation.issues.contains {
                $0.affectedChainIDs.contains(entry.chain.id)
              },
              onEdit: { editor = .editing(entry.chain) },
              onDelete: { store.send(.deleteWorkspaceChainRequested(entry.chain)) },
            )
          }
        }

        Button {
          editor = .creating(WorkspaceChain(name: nextChainName(in: profile)))
        } label: {
          Label("Add Workspace Chain", systemImage: "plus")
        }
      } header: {
        Text("Workspace Chains")
      } footer: {
        Text(
          "Switching to any member always keeps that workspace active. Tatami considers the rest in list order: connected pins and Chain Dynamic workspaces run before the ordinary empty-display fallback."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Private

  private var validation: WorkspaceChainValidation {
    store.profile?.validateWorkspaceChains()
      ?? WorkspaceChainValidation(validChains: [], issues: [])
  }

  private func chainEntries(in profile: Profile) -> [WorkspaceChainListEntry] {
    var occurrences = [WorkspaceChain.ID: Int]()
    return profile.workspaceChains.map { chain in
      let occurrence = occurrences[chain.id, default: 0]
      occurrences[chain.id] = occurrence + 1
      return WorkspaceChainListEntry(
        id: .init(chainID: chain.id, occurrence: occurrence),
        chain: chain,
      )
    }
  }

  private func nextChainName(in profile: Profile) -> String {
    let base = String(localized: "Workspace Chain")
    let names = Set(profile.workspaceChains.compactMap(\.name))
    var number = profile.workspaceChains.count + 1
    while names.contains("\(base) \(number)") { number += 1 }
    return "\(base) \(number)"
  }

}

// MARK: - WorkspaceChainListEntry

private struct WorkspaceChainListEntry: Identifiable {
  struct ID: Hashable {
    let chainID: WorkspaceChain.ID
    let occurrence: Int
  }

  let id: ID
  let chain: WorkspaceChain
}

// MARK: - WorkspaceChainSettingsRow

private struct WorkspaceChainSettingsRow: View {

  // MARK: Internal

  let chain: WorkspaceChain
  let profile: Profile
  let hasIssues: Bool
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onEdit) {
        HStack(spacing: 10) {
          Image(systemName: hasIssues ? "exclamationmark.triangle.fill" : "link")
            .foregroundStyle(hasIssues ? Color.orange : Color.accentColor)
            .frame(width: 18)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(summary)
              .font(.caption)
              .foregroundStyle(hasIssues ? Color.orange : Color.secondary)
              .lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(title))
      .accessibilityValue(hasIssues ? Text("Needs repair. \(summary)") : Text(summary))
      .accessibilityHint("Edit this workspace chain")

      Button(role: .destructive, action: onDelete) {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Delete this workspace chain")
      .accessibilityLabel("Delete \(title)")
    }
  }

  // MARK: Private

  private var title: String {
    let name = chain.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name, !name.isEmpty { return name }
    return String(localized: "Untitled Workspace Chain")
  }

  private var summary: String {
    let names = chain.workspaceIDs.map { workspaceID in
      profile.workspaces[id: workspaceID]?.name
        ?? String(localized: "Missing workspace")
    }
    return names.isEmpty
      ? String(localized: "No linked workspaces")
      : names.joined(separator: " · ")
  }

}

// MARK: - WorkspaceChainEditorView

/// Draft-based editor: no invalid partial chain is published while the user is
/// adding, removing, or ordering its workspaces. Placement stays owned by each
/// workspace and is shown here as context rather than edited a second time.
struct WorkspaceChainEditorView: View {

  // MARK: Lifecycle

  init(
    store: StoreOf<ProfileDetailFeature>,
    chain: WorkspaceChain,
    original: WorkspaceChain?,
  ) {
    self.store = store
    self.original = original
    _draft = State(initialValue: chain)
  }

  // MARK: Internal

  @Bindable var store: StoreOf<ProfileDetailFeature>

  var body: some View {
    NavigationStack {
      if let profile = store.profile {
        Form {
          Section("Workspace Chain") {
            TextField("Name", text: chainName)
          }

          Section {
            if selectedEntries.isEmpty {
              Text("No workspaces yet. Tap + to add one.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(selectedEntries) { entry in
                workspaceRow(entry, profile: profile)
              }
            }

            if let validationMessage {
              Label {
                Text(validationMessage)
              } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
              }
              .font(.caption)
              .foregroundStyle(.orange)
              .accessibilityElement(children: .combine)
            } else if let repairMessage {
              Label(repairMessage, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
          } header: {
            HStack {
              Text("Workspaces")
              Spacer()
              Button {
                isWorkspacePickerPresented = true
              } label: {
                Label("Add", systemImage: "plus.circle")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
              .help("Add Workspace")
            }
          } footer: {
            VStack(alignment: .leading, spacing: 4) {
              Text("Add at least two workspaces. Switching to any one applies this priority order.")
              Text(
                "The workspace you switch to is always included. The order below sets the priority for the rest: Tatami places them from top to bottom on displays they can use."
              )
              Text(
                "A pinned companion is skipped when its display is unavailable. Dynamic in this chain uses the next free display before Tatami applies the ordinary fallback."
              )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .formStyle(.grouped)
        .navigationTitle(editorTitle)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }
              .disabled(validationMessage != nil)
              .help(validationMessage ?? String(localized: "Save this workspace chain"))
          }
        }
        .sheet(isPresented: $isWorkspacePickerPresented) {
          WorkspaceChainWorkspacePicker(
            workspaces: candidateWorkspaces(in: profile),
            onSelect: addWorkspace,
            onCancel: { isWorkspacePickerPresented = false },
          )
        }
      } else {
        ContentUnavailableView(
          "Profile Unavailable",
          systemImage: "rectangle.stack",
          description: Text("This profile no longer exists."),
        )
      }
    }
    .frame(minWidth: 560, minHeight: 440)
  }

  // MARK: Private

  /// The edge of a row where the dragged workspace will be inserted. The edge
  /// follows the source/target direction: moving down inserts after the target,
  /// while moving up inserts before it.
  private struct DropIndicator: Equatable {
    let entryID: WorkspaceChainReferenceEntry.ID
    let after: Bool
  }

  @Environment(\.dismiss) private var dismiss
  @State private var activeDragEntryID: WorkspaceChainReferenceEntry.ID?
  @State private var draft: WorkspaceChain
  @State private var dropTargetEntryID: WorkspaceChainReferenceEntry.ID?
  @State private var isCommitting = false
  @State private var isWorkspacePickerPresented = false

  private let original: WorkspaceChain?

  private var isExisting: Bool {
    original != nil
  }

  private var editorTitle: LocalizedStringResource {
    isExisting ? "Edit Workspace Chain" : "New Workspace Chain"
  }

  private var chainName: Binding<String> {
    Binding(
      get: { draft.name ?? "" },
      set: { draft.name = $0 },
    )
  }

  private var selectedEntries: [WorkspaceChainReferenceEntry] {
    var occurrences = [Workspace.ID: Int]()
    return draft.workspaceIDs.enumerated().map { index, workspaceID in
      let occurrence = occurrences[workspaceID, default: 0]
      occurrences[workspaceID] = occurrence + 1
      return WorkspaceChainReferenceEntry(
        id: .init(workspaceID: workspaceID, occurrence: occurrence),
        index: index,
        workspaceID: workspaceID,
      )
    }
  }

  private var dropIndicator: DropIndicator? {
    guard
      let activeDragEntryID,
      let dropTargetEntryID,
      let sourceIndex = selectedEntries.firstIndex(where: { $0.id == activeDragEntryID }),
      let targetIndex = selectedEntries.firstIndex(where: { $0.id == dropTargetEntryID }),
      sourceIndex != targetIndex
    else { return nil }
    return DropIndicator(
      entryID: dropTargetEntryID,
      after: sourceIndex < targetIndex,
    )
  }

  private var validationIssues: [WorkspaceChainValidationIssue] {
    // `Store.send` publishes the saved chain synchronously, while the sheet
    // remains visible for one dismissal frame. Validation has already passed at
    // that point; rebuilding a hypothetical profile from the stale `original`
    // would append the submitted draft beside its saved replacement and invent
    // a self-conflict.
    guard !isCommitting else { return [] }
    guard var profile = store.profile else { return [] }
    if let index = editedChainIndex(in: profile.workspaceChains) {
      profile.workspaceChains[index] = draft
    } else {
      profile.workspaceChains.append(draft)
    }
    return profile.validateWorkspaceChains().issues.filter(isIssueRelevantToDraft)
  }

  private var validationMessage: String? {
    // Saving already passed this validation. Keep the dismissal frame inert so
    // the synchronous Shared update cannot surface transient diagnostics.
    guard !isCommitting else { return nil }
    if let original, store.profile?.workspaceChains.contains(original) != true {
      return String(localized: "This workspace chain changed. Close the editor and open it again.")
    }
    guard let issue = blockingValidationIssues.first else { return nil }
    return switch issue {
    case .tooFewWorkspaces:
      String(localized: "Add at least two workspaces.")
    case .duplicateChainID:
      String(localized: "Another workspace chain has the same identifier.")
    case .duplicateWorkspace:
      String(localized: "A workspace appears more than once in this chain.")
    case .duplicateDynamicWorkspace:
      String(localized: "A workspace appears more than once in the Chain Dynamic list.")
    case .dynamicWorkspaceOutsideChain:
      String(localized: "Chain Dynamic references a workspace outside this chain.")
    case .workspaceInMultipleChains:
      String(localized: "One of these workspaces already belongs to another workspace chain.")
    case .unknownWorkspace:
      String(localized: "One of these workspaces no longer exists.")
    case .scratchpadWorkspace:
      String(localized: "Scratchpads cannot join workspace chains.")
    }
  }

  /// Duplicate internal IDs can come from a hand-edited config. Saving an
  /// otherwise valid chain assigns it a fresh ID in the feature reducer.
  private var blockingValidationIssues: [WorkspaceChainValidationIssue] {
    validationIssues.filter { issue in
      switch issue {
      case .duplicateChainID,
           .duplicateDynamicWorkspace,
           .dynamicWorkspaceOutsideChain:
        false
      default:
        true
      }
    }
  }

  private var repairMessage: String? {
    if
      validationIssues.contains(where: { issue in
        switch issue {
        case .duplicateDynamicWorkspace,
             .dynamicWorkspaceOutsideChain:
          true
        default:
          false
        }
      })
    {
      return String(localized: "Saving will repair the Chain Dynamic references.")
    }
    if
      validationIssues.contains(where: { issue in
        if case .duplicateChainID = issue { true } else { false }
      })
    {
      return String(
        localized: "This workspace chain shares an internal identifier. Saving will repair it."
      )
    }
    return nil
  }

  /// Duplicate chain IDs make `affectedChainIDs` alone ambiguous: an issue in
  /// the other hand-edited chain must not block repairing this draft. Attribute
  /// reference problems by the draft's actual contents instead.
  private func isIssueRelevantToDraft(_ issue: WorkspaceChainValidationIssue) -> Bool {
    switch issue {
    case .duplicateChainID(let chainID):
      chainID == draft.id

    case .tooFewWorkspaces(let chainID):
      chainID == draft.id && draft.workspaceIDs.count < 2

    case .duplicateWorkspace(let chainID, let workspaceID):
      chainID == draft.id
        && draft.workspaceIDs.count(where: { $0 == workspaceID }) > 1

    case .duplicateDynamicWorkspace(let chainID, let workspaceID):
      chainID == draft.id
        && draft.dynamicWorkspaceIDs.count(where: { $0 == workspaceID }) > 1

    case .dynamicWorkspaceOutsideChain(let chainID, let workspaceID):
      chainID == draft.id
        && draft.dynamicWorkspaceIDs.contains(workspaceID)
        && !draft.workspaceIDs.contains(workspaceID)

    case .workspaceInMultipleChains(let workspaceID, _):
      draft.workspaceIDs.contains(workspaceID)

    case .unknownWorkspace(let chainID, let workspaceID),
         .scratchpadWorkspace(let chainID, let workspaceID):
      chainID == draft.id && draft.workspaceIDs.contains(workspaceID)
    }
  }

  private func workspaceRow(
    _ entry: WorkspaceChainReferenceEntry,
    profile: Profile,
  ) -> some View {
    let workspace = profile.workspaces[id: entry.workspaceID]
    return WorkspaceChainWorkspaceRow(
      dragPayload: entry.id.dragPayload,
      name: workspace?.name ?? String(localized: "Missing workspace"),
      symbolName: workspace?.symbolIconName ?? "exclamationmark.triangle.fill",
      displayHint: workspace?.displayHint,
      isDynamicInChain: workspace.map { draft.isDynamicInChain($0) } ?? false,
      showsPlacement: workspace != nil,
      issue: referenceIssue(for: entry, profile: profile),
      position: entry.index + 1,
      positionCount: draft.workspaceIDs.count,
      canMoveEarlier: entry.index > draft.workspaceIDs.startIndex,
      canMoveLater: entry.index < draft.workspaceIDs.index(before: draft.workspaceIDs.endIndex),
      onMoveEarlier: { moveWorkspace(at: entry.index, by: -1) },
      onMoveLater: { moveWorkspace(at: entry.index, by: 1) },
      onRemove: { removeWorkspace(at: entry.index) },
      onSetDynamicInChain: { setDynamicInChain($0, workspaceID: entry.workspaceID) },
      onDragBegan: { beginDragging(entry.id) },
      onDragEnded: { endDragging(entry.id) },
    )
    // Keep the target on the row itself. A transparent overlay here steals
    // pointer hit-testing from the handle and prevents its drag from starting.
    .dropDestination(for: String.self) { payloads, _ in
      dropWorkspaces(payloads, onto: entry.id)
    } isTargeted: { targeted in
      updateDropTarget(entry.id, isTargeted: targeted)
    }
    .overlay(alignment: .top) {
      insertionLine(
        visible: dropIndicator == DropIndicator(entryID: entry.id, after: false)
      )
    }
    .overlay(alignment: .bottom) {
      insertionLine(
        visible: dropIndicator == DropIndicator(entryID: entry.id, after: true)
      )
    }
  }

  private func updateDropTarget(
    _ entryID: WorkspaceChainReferenceEntry.ID,
    isTargeted: Bool,
  ) {
    withAnimation(.easeOut(duration: 0.12)) {
      if isTargeted {
        dropTargetEntryID = entryID
      } else if dropTargetEntryID == entryID {
        dropTargetEntryID = nil
      }
    }
  }

  private func insertionLine(visible: Bool) -> some View {
    Capsule()
      .fill(.tint)
      .frame(height: 2)
      .padding(.horizontal, 4)
      .opacity(visible ? 1 : 0)
      .scaleEffect(x: visible ? 1 : 0.92)
      .animation(.easeOut(duration: 0.12), value: visible)
      .allowsHitTesting(false)
  }

  private func referenceIssue(
    for entry: WorkspaceChainReferenceEntry,
    profile: Profile,
  ) -> String? {
    guard let workspace = profile.workspaces[id: entry.workspaceID] else {
      return String(localized: "This workspace no longer exists. Remove it to repair the chain.")
    }
    if workspace.kind == .scratchpad {
      return String(localized: "Scratchpads cannot join workspace chains. Remove it to repair the chain.")
    }
    if entry.id.occurrence > 0 {
      return String(localized: "This workspace appears more than once. Remove the duplicate.")
    }
    if workspacesUsedByOtherChains(in: profile).contains(entry.workspaceID) {
      return String(
        localized: "Already used by another workspace chain. Remove it here or edit the other chain."
      )
    }
    return nil
  }

  private func candidateWorkspaces(in profile: Profile) -> [Workspace] {
    let selected = Set(draft.workspaceIDs)
    let usedElsewhere = workspacesUsedByOtherChains(in: profile)
    return profile.workspaces.filter { workspace in
      workspace.kind == .normal
        && !selected.contains(workspace.id)
        && !usedElsewhere.contains(workspace.id)
    }
  }

  private func workspacesUsedByOtherChains(in profile: Profile) -> Set<Workspace.ID> {
    Set(otherChains(in: profile).flatMap(\.workspaceIDs))
  }

  private func otherChains(in profile: Profile) -> [WorkspaceChain] {
    var chains = profile.workspaceChains
    if let index = editedChainIndex(in: chains) {
      chains.remove(at: index)
    }
    return chains
  }

  /// Before Save, the immutable snapshot is the concurrency guard: if it no
  /// longer exists, the editor must report an external change. After the
  /// synchronous Save, that exact value has legitimately been replaced (and a
  /// duplicate internal ID may have been repaired), so identify the submitted
  /// chain by its user-authored content for the one dismissal frame.
  private func editedChainIndex(in chains: [WorkspaceChain]) -> Int? {
    guard isCommitting else {
      return original.flatMap { chains.firstIndex(of: $0) }
    }
    let submittedName = normalizedChainName(draft.name)
    return chains.firstIndex { chain in
      chain.workspaceIDs == draft.workspaceIDs
        && chain.dynamicWorkspaceIDs == draft.dynamicWorkspaceIDs
        && normalizedChainName(chain.name) == submittedName
    } ?? original.flatMap { chains.firstIndex(of: $0) }
  }

  private func normalizedChainName(_ name: String?) -> String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private func addWorkspace(_ workspace: Workspace) {
    guard
      workspace.kind == .normal,
      !draft.workspaceIDs.contains(workspace.id)
    else { return }
    draft.workspaceIDs.append(workspace.id)
    isWorkspacePickerPresented = false
  }

  private func removeWorkspace(at index: Int) {
    guard draft.workspaceIDs.indices.contains(index) else { return }
    let workspaceID = draft.workspaceIDs.remove(at: index)
    draft.dynamicWorkspaceIDs.removeAll { $0 == workspaceID }
  }

  private func setDynamicInChain(_ isDynamic: Bool, workspaceID: Workspace.ID) {
    draft.dynamicWorkspaceIDs.removeAll { $0 == workspaceID }
    if isDynamic { draft.dynamicWorkspaceIDs.append(workspaceID) }
    draft.normalizeDynamicWorkspaceIDs()
  }

  private func moveWorkspace(at index: Int, by offset: Int) {
    let destination = index + offset
    guard
      draft.workspaceIDs.indices.contains(index),
      draft.workspaceIDs.indices.contains(destination)
    else { return }
    withAnimation(.snappy(duration: 0.2)) {
      draft.workspaceIDs.swapAt(index, destination)
      draft.normalizeDynamicWorkspaceIDs()
    }
  }

  private func beginDragging(_ entryID: WorkspaceChainReferenceEntry.ID) {
    activeDragEntryID = entryID
  }

  private func endDragging(_ entryID: WorkspaceChainReferenceEntry.ID) {
    guard activeDragEntryID == entryID else { return }
    withAnimation(.easeOut(duration: 0.12)) {
      activeDragEntryID = nil
      dropTargetEntryID = nil
    }
  }

  private func dropWorkspaces(
    _ payloads: [String],
    onto targetID: WorkspaceChainReferenceEntry.ID,
  ) -> Bool {
    guard
      let payload = payloads.first,
      let sourceID = WorkspaceChainReferenceEntry.ID(dragPayload: payload),
      let sourceIndex = selectedEntries.firstIndex(where: { $0.id == sourceID }),
      let targetIndex = selectedEntries.firstIndex(where: { $0.id == targetID })
    else { return false }

    guard sourceIndex != targetIndex else {
      activeDragEntryID = nil
      dropTargetEntryID = nil
      return true
    }

    var reordered = draft.workspaceIDs
    let movedWorkspaceID = reordered.remove(at: sourceIndex)
    let after = sourceIndex < targetIndex
    var insertionIndex = targetIndex + (after ? 1 : 0)
    if sourceIndex < insertionIndex {
      insertionIndex -= 1
    }
    insertionIndex = min(max(insertionIndex, reordered.startIndex), reordered.endIndex)

    withAnimation(.snappy(duration: 0.2)) {
      reordered.insert(movedWorkspaceID, at: insertionIndex)
      draft.workspaceIDs = reordered
      draft.normalizeDynamicWorkspaceIDs()
      activeDragEntryID = nil
      dropTargetEntryID = nil
    }
    return true
  }

  private func save() {
    guard validationMessage == nil else { return }
    // `Store.send` updates synchronously. Freeze draft validation while the
    // saved replacement remains onscreen during dismissal. The reducer still
    // rejects structural conflicts independently and presents the parent alert.
    draft.normalizeDynamicWorkspaceIDs()
    isCommitting = true
    store.send(.saveWorkspaceChain(original: original, updated: draft))
    dismiss()
  }

}

// MARK: - WorkspaceChainReferenceEntry

private struct WorkspaceChainReferenceEntry: Identifiable {
  struct ID: Hashable {

    // MARK: Lifecycle

    init(workspaceID: Workspace.ID, occurrence: Int) {
      self.workspaceID = workspaceID
      self.occurrence = occurrence
    }

    init?(dragPayload: String) {
      guard
        let separator = dragPayload.lastIndex(of: ":"),
        let workspaceID = UUID(uuidString: String(dragPayload[..<separator])),
        let occurrence = Int(dragPayload[dragPayload.index(after: separator)...]),
        occurrence >= 0
      else { return nil }
      self.init(workspaceID: workspaceID, occurrence: occurrence)
    }

    // MARK: Internal

    let workspaceID: Workspace.ID
    let occurrence: Int

    var dragPayload: String {
      "\(workspaceID.uuidString):\(occurrence)"
    }

  }

  let id: ID
  let index: Int
  let workspaceID: Workspace.ID
}

// MARK: - WorkspaceChainWorkspaceRow

private struct WorkspaceChainWorkspaceRow: View {
  let dragPayload: String
  let name: String
  let symbolName: String
  let displayHint: DisplayName?
  let isDynamicInChain: Bool
  let showsPlacement: Bool
  let issue: String?
  let position: Int
  let positionCount: Int
  let canMoveEarlier: Bool
  let canMoveLater: Bool
  let onMoveEarlier: () -> Void
  let onMoveLater: () -> Void
  let onRemove: () -> Void
  let onSetDynamicInChain: (Bool) -> Void
  let onDragBegan: () -> Void
  let onDragEnded: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal")
        .font(.body.weight(.medium))
        .foregroundStyle(.tertiary)
        .frame(width: 24, height: 28)
        .contentShape(Rectangle())
        .draggable(dragPayload) {
          Label(name, systemImage: symbolName)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .onAppear(perform: onDragBegan)
            .onDisappear(perform: onDragEnded)
        }
        .help("Drag to reorder")
        .accessibilityLabel("Reorder \(name)")
        .accessibilityValue("Position \(position) of \(positionCount)")
        .accessibilityHint("Drag to change the workspace order")
        .accessibilityActions {
          if canMoveEarlier {
            Button("Move earlier", action: onMoveEarlier)
          }
          if canMoveLater {
            Button("Move later", action: onMoveLater)
          }
        }

      Image(systemName: symbolName)
        .foregroundStyle(issue == nil ? Color.accentColor : Color.orange)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(name)
        if showsPlacement {
          if let displayHint {
            WorkspaceChainPlacementMenu(
              displayHint: displayHint,
              isDynamicInChain: isDynamicInChain,
              onSelect: onSetDynamicInChain,
            )
          } else {
            WorkspaceChainPlacementLabel(displayHint: nil)
          }
        }
        if let issue {
          Text(issue)
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(role: .destructive, action: onRemove) {
        Image(systemName: "minus.circle.fill")
          .foregroundStyle(.red)
      }
      .buttonStyle(.borderless)
      .help("Remove from workspace chain")
      .accessibilityLabel("Remove \(name) from workspace chain")
    }
  }
}

// MARK: - WorkspaceChainPlacementLabel

private struct WorkspaceChainPlacementLabel: View {
  let displayHint: DisplayName?

  var body: some View {
    Group {
      if let displayHint {
        Text("Pinned to \(displayHint.name)")
      } else {
        Label("Dynamic · follows the pointer", systemImage: "cursorarrow.motionlines")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

// MARK: - WorkspaceChainPlacementMenu

/// A pinned workspace can opt into dynamic placement for this chain without
/// changing its ordinary workspace pin.
private struct WorkspaceChainPlacementMenu: View {

  // MARK: Internal

  let displayHint: DisplayName
  let isDynamicInChain: Bool
  let onSelect: (Bool) -> Void

  var body: some View {
    Menu {
      Button {
        onSelect(false)
      } label: {
        Label(
          "Pinned to \(displayHint.name)",
          systemImage: isDynamicInChain ? "display" : "checkmark",
        )
      }
      Button {
        onSelect(true)
      } label: {
        Label(
          "Dynamic in this chain",
          systemImage: isDynamicInChain ? "checkmark" : "cursorarrow.motionlines",
        )
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: isDynamicInChain ? "cursorarrow.motionlines" : "display")
        Text(placementName)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityLabel("Placement in this chain")
    .accessibilityValue(placementName)
    .help("Choose how this workspace is placed when the chain runs")
  }

  // MARK: Private

  private var placementName: String {
    if isDynamicInChain {
      return String(localized: "Dynamic in this chain")
    }
    return String(localized: "Pinned to \(displayHint.name)")
  }

}

// MARK: - WorkspaceChainWorkspacePicker

/// Mirrors the app picker: searchable native rows, one click to add, and a
/// stable empty state when every eligible workspace is already used.
private struct WorkspaceChainWorkspacePicker: View {

  // MARK: Internal

  let workspaces: [Workspace]
  let onSelect: (Workspace) -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      List(filteredWorkspaces) { workspace in
        Button {
          onSelect(workspace)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: workspace.symbolIconName ?? "square.stack.3d.up")
              .foregroundStyle(.tint)
              .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
              Text(workspace.name)
              WorkspaceChainPlacementLabel(displayHint: workspace.displayHint)
            }
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .overlay {
        if filteredWorkspaces.isEmpty {
          ContentUnavailableView {
            Label(emptyStateTitle, systemImage: "magnifyingglass")
          } description: {
            if workspaces.isEmpty {
              Text("Create a normal workspace, or remove one from another workspace chain.")
            } else {
              Text("No workspace matches “\(query)”.")
            }
          }
        }
      }
      .navigationTitle("Add Workspace")
      .searchable(text: $query, prompt: "Search workspaces")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
    .frame(width: 420, height: 480)
  }

  // MARK: Private

  @State private var query = ""

  private var emptyStateTitle: LocalizedStringResource {
    workspaces.isEmpty ? "No Workspaces Available" : "No Matches"
  }

  private var filteredWorkspaces: [Workspace] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return workspaces }
    return workspaces.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
  }

}
