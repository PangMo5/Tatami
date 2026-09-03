// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - WorkspaceChain

/// A symmetric group of workspaces that switch together across displays.
///
/// The chain stores workspace identity only. A workspace's destination is
/// resolved when the chain runs: connected pinned workspaces use `displayHint`,
/// while ordinary or chain-specific dynamic workspaces claim a free display.
/// There is no anchor or parent; one profile owns the canonical group.
public struct WorkspaceChain: Identifiable, Hashable, Sendable, Codable {

  // MARK: Lifecycle

  public init(
    id: UUID = UUID(),
    name: String? = nil,
    workspaceIDs: [Workspace.ID] = [],
    dynamicWorkspaceIDs: [Workspace.ID] = [],
  ) {
    self.id = id
    self.name = name
    self.workspaceIDs = workspaceIDs
    self.dynamicWorkspaceIDs = dynamicWorkspaceIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    // A missing list is a semantic error surfaced by validation, not a reason
    // to discard the user's entire config file.
    workspaceIDs = try container.decodeIfPresent(
      [Workspace.ID].self,
      forKey: .workspaceIDs,
    ) ?? []
    dynamicWorkspaceIDs = try container.decodeIfPresent(
      [Workspace.ID].self,
      forKey: .dynamicWorkspaceIDs,
    ) ?? []
  }

  // MARK: Public

  public var id: UUID
  /// Optional user-facing label. It has no effect on activation semantics.
  public var name: String?
  /// Stable workspace identities in user-authored order. Names and displays
  /// are deliberately not persisted, so renaming or reconnecting cannot break
  /// the chain definition.
  public var workspaceIDs: [Workspace.ID]
  /// Workspaces explicitly assigned dynamic companion placement in this chain.
  /// Their stored order still comes from `workspaceIDs`; this subset only
  /// overrides placement within the chain and does not change the workspace.
  public var dynamicWorkspaceIDs: [Workspace.ID]

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encode(workspaceIDs, forKey: .workspaceIDs)
    if !dynamicWorkspaceIDs.isEmpty {
      try container.encode(dynamicWorkspaceIDs, forKey: .dynamicWorkspaceIDs)
    }
  }

  /// An ordinarily dynamic workspace remains dynamic without redundant config.
  /// A pinned workspace becomes dynamic only when this chain explicitly opts in.
  public func isDynamicInChain(_ workspace: Workspace) -> Bool {
    workspace.isDynamic || dynamicWorkspaceIDs.contains(workspace.id)
  }

  /// Repair supplemental placement metadata without changing membership or
  /// priority: discard foreign IDs, remove duplicates, and retain chain order.
  public mutating func normalizeDynamicWorkspaceIDs() {
    let dynamicWorkspaceIDs = Set(dynamicWorkspaceIDs)
    self.dynamicWorkspaceIDs = workspaceIDs.filter(dynamicWorkspaceIDs.contains)
  }

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case dynamicWorkspaceIDs = "dynamicWorkspaceIds"
    case workspaceIDs = "workspaceIds"
  }

}

// MARK: - WorkspaceChainValidationIssue

/// Semantic problems Codable cannot express. Invalid chains remain in the
/// configuration for the Settings UI to repair, but are excluded at runtime.
public enum WorkspaceChainValidationIssue: Hashable, Sendable {
  case duplicateChainID(chainId: WorkspaceChain.ID)
  case tooFewWorkspaces(chainId: WorkspaceChain.ID)
  case duplicateWorkspace(
    chainId: WorkspaceChain.ID,
    workspaceId: Workspace.ID,
  )
  case duplicateDynamicWorkspace(
    chainId: WorkspaceChain.ID,
    workspaceId: Workspace.ID,
  )
  case dynamicWorkspaceOutsideChain(
    chainId: WorkspaceChain.ID,
    workspaceId: Workspace.ID,
  )
  /// V1 deliberately permits a workspace in at most one chain in its profile.
  /// This keeps one workspace activation from resolving to competing groups.
  case workspaceInMultipleChains(
    workspaceId: Workspace.ID,
    chainIds: [WorkspaceChain.ID],
  )
  case unknownWorkspace(
    chainId: WorkspaceChain.ID,
    workspaceId: Workspace.ID,
  )
  case scratchpadWorkspace(
    chainId: WorkspaceChain.ID,
    workspaceId: Workspace.ID,
  )

  // MARK: Public

  /// Every chain made unsafe by this issue. Runtime lookup excludes the whole
  /// chain instead of silently applying a partial or order-dependent group.
  public var affectedChainIDs: Set<WorkspaceChain.ID> {
    switch self {
    case .duplicateChainID(let chainId),
         .tooFewWorkspaces(let chainId),
         .duplicateWorkspace(let chainId, _),
         .duplicateDynamicWorkspace(let chainId, _),
         .dynamicWorkspaceOutsideChain(let chainId, _),
         .unknownWorkspace(let chainId, _),
         .scratchpadWorkspace(let chainId, _):
      [chainId]

    case .workspaceInMultipleChains(_, let chainIds):
      Set(chainIds)
    }
  }
}

// MARK: - WorkspaceChainValidation

public struct WorkspaceChainValidation: Equatable, Sendable {
  public init(
    validChains: [WorkspaceChain],
    issues: [WorkspaceChainValidationIssue],
  ) {
    self.validChains = validChains
    self.issues = issues
  }

  /// Chains safe to execute. Invalid definitions remain in `Profile` so the
  /// user can see and repair hand-edited conflicts.
  public var validChains: [WorkspaceChain]
  public var issues: [WorkspaceChainValidationIssue]

  public var isValid: Bool {
    issues.isEmpty
  }
}

extension Profile {
  /// Validate profile-scoped references and the one-workspace-per-chain V1
  /// contract. Display placement is intentionally not validated here: it is
  /// derived from each workspace and current runtime state when switching.
  public func validateWorkspaceChains() -> WorkspaceChainValidation {
    var issues = [WorkspaceChainValidationIssue]()
    let duplicateChainIDs = Set(
      Dictionary(grouping: workspaceChains, by: \.id)
        .filter { $0.value.count > 1 }
        .keys
    )
    for chain in workspaceChains where duplicateChainIDs.contains(chain.id) {
      let issue = WorkspaceChainValidationIssue.duplicateChainID(chainId: chain.id)
      if !issues.contains(issue) { issues.append(issue) }
    }

    var chainIDsByWorkspace = [Workspace.ID: [WorkspaceChain.ID]]()
    for chain in workspaceChains {
      if chain.workspaceIDs.count < 2 {
        issues.append(.tooFewWorkspaces(chainId: chain.id))
      }

      var workspacesSeenInChain = Set<Workspace.ID>()
      for workspaceId in chain.workspaceIDs {
        if !workspacesSeenInChain.insert(workspaceId).inserted {
          issues.append(.duplicateWorkspace(
            chainId: chain.id,
            workspaceId: workspaceId,
          ))
        }

        guard let workspace = workspaces[id: workspaceId] else {
          issues.append(.unknownWorkspace(
            chainId: chain.id,
            workspaceId: workspaceId,
          ))
          continue
        }
        if workspace.kind == .scratchpad {
          issues.append(.scratchpadWorkspace(
            chainId: chain.id,
            workspaceId: workspaceId,
          ))
        }
      }

      var dynamicWorkspacesSeen = Set<Workspace.ID>()
      let memberIDs = Set(chain.workspaceIDs)
      for workspaceId in chain.dynamicWorkspaceIDs {
        if !dynamicWorkspacesSeen.insert(workspaceId).inserted {
          issues.append(.duplicateDynamicWorkspace(
            chainId: chain.id,
            workspaceId: workspaceId,
          ))
        }
        if !memberIDs.contains(workspaceId) {
          issues.append(.dynamicWorkspaceOutsideChain(
            chainId: chain.id,
            workspaceId: workspaceId,
          ))
        }
      }

      // Count a duplicated entry only once for cross-chain validation; the
      // duplicate-within-chain issue above already describes that problem.
      for workspaceId in workspacesSeenInChain {
        if chainIDsByWorkspace[workspaceId]?.contains(chain.id) != true {
          chainIDsByWorkspace[workspaceId, default: []].append(chain.id)
        }
      }
    }

    for workspace in workspaces {
      guard let chainIds = chainIDsByWorkspace[workspace.id], chainIds.count > 1 else { continue }
      issues.append(.workspaceInMultipleChains(
        workspaceId: workspace.id,
        chainIds: chainIds,
      ))
    }
    // Preserve diagnostics for unknown IDs too, in deterministic UUID order.
    let knownWorkspaceIDs = Set(workspaces.map(\.id))
    for workspaceId in chainIDsByWorkspace.keys
      .filter({ !knownWorkspaceIDs.contains($0) })
      .sorted(by: { $0.uuidString < $1.uuidString })
    {
      guard let chainIds = chainIDsByWorkspace[workspaceId], chainIds.count > 1 else { continue }
      issues.append(.workspaceInMultipleChains(
        workspaceId: workspaceId,
        chainIds: chainIds,
      ))
    }

    let invalidChainIDs = issues.reduce(into: Set<WorkspaceChain.ID>()) {
      $0.formUnion($1.affectedChainIDs)
    }
    return WorkspaceChainValidation(
      validChains: workspaceChains.filter { !invalidChainIDs.contains($0.id) },
      issues: issues,
    )
  }

  /// Resolve the validated symmetric chain containing this workspace.
  public func validWorkspaceChain(
    containing workspaceId: Workspace.ID
  ) -> WorkspaceChain? {
    validateWorkspaceChains().validChains.first { chain in
      chain.workspaceIDs.contains(workspaceId)
    }
  }

  /// Remove a workspace from every chain after deletion or conversion to a
  /// scratchpad. A surviving two-or-more-workspace group keeps its symmetric
  /// meaning; groups that can no longer form a chain are removed.
  public mutating func removeWorkspaceFromWorkspaceChains(_ workspaceId: Workspace.ID) {
    workspaceChains = workspaceChains.compactMap { chain in
      var chain = chain
      chain.workspaceIDs.removeAll { $0 == workspaceId }
      chain.dynamicWorkspaceIDs.removeAll { $0 == workspaceId }
      return chain.workspaceIDs.count >= 2 ? chain : nil
    }
  }

  /// Used by selective profile duplication: copying only part of a chain would
  /// silently create a different group, so drop it unless every workspace
  /// still identifies a normal workspace in this profile.
  public mutating func removeIncompleteWorkspaceChains() {
    let normalWorkspaceIDs = Set(workspaces.lazy.filter { $0.kind == .normal }.map(\.id))
    workspaceChains.removeAll { chain in
      chain.workspaceIDs.count < 2
        || chain.workspaceIDs.contains { !normalWorkspaceIDs.contains($0) }
    }
  }
}
