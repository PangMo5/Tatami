import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

/// Pure value-type tests for `AppConfig.placeWorkspace` — the sidebar
/// drag-and-drop that both reorders within a section and moves rows between
/// the "Workspaces" and "Scratchpads" sections. `after` mirrors the insertion
/// line: land before the target (above its midline) or after it (below).
struct WorkspaceReorderTests {
  private func makeConfig(_ workspaces: [Workspace]) -> AppConfig {
    AppConfig(profiles: [
      Profile(name: "Default", workspaces: IdentifiedArray(uniqueElements: workspaces))
    ])
  }

  private func names(_ config: AppConfig) -> [String] {
    config.activeProfile?.workspaces.map(\.name) ?? []
  }

  private func kind(_ config: AppConfig, _ name: String) -> WorkspaceKind? {
    config.activeProfile?.workspaces.first { $0.name == name }?.kind
  }

  private func id(_ config: AppConfig, _ name: String) -> Workspace.ID {
    config.activeProfile!.workspaces.first { $0.name == name }!.id
  }

  // MARK: - Same-section reorder

  @Test
  func droppingAboveTargetLandsBeforeIt() {
    var config = makeConfig([
      Workspace(name: "A"), Workspace(name: "B"), Workspace(name: "C"),
    ])
    // Line above A → before A.
    config.placeWorkspace(id(config, "C"), kind: .normal, relativeTo: id(config, "A"), after: false)
    #expect(names(config) == ["C", "A", "B"])
  }

  @Test
  func droppingBelowLastTargetReachesTheEnd() {
    var config = makeConfig([
      Workspace(name: "A"), Workspace(name: "B"), Workspace(name: "C"),
    ])
    // Line below C → after C (the very end is reachable).
    config.placeWorkspace(id(config, "A"), kind: .normal, relativeTo: id(config, "C"), after: true)
    #expect(names(config) == ["B", "C", "A"])
  }

  @Test
  func droppingOntoSelfIsANoOp() {
    var config = makeConfig([Workspace(name: "A"), Workspace(name: "B")])
    let before = names(config)
    config.placeWorkspace(id(config, "A"), kind: .normal, relativeTo: id(config, "A"), after: true)
    #expect(names(config) == before)
  }

  @Test
  func reorderingLeavesTheOtherSectionInPlace() {
    var config = makeConfig([
      Workspace(name: "N0", kind: .normal),
      Workspace(name: "S0", kind: .scratchpad),
      Workspace(name: "N1", kind: .normal),
    ])
    // Reorder normals (N0 below N1) — S0's slot must be untouched.
    config.placeWorkspace(id(config, "N0"), kind: .normal, relativeTo: id(config, "N1"), after: true)
    #expect(names(config) == ["S0", "N1", "N0"])
    #expect(kind(config, "S0") == .scratchpad)
  }

  // MARK: - Cross-section move

  @Test
  func draggingIntoScratchpadsRetypesAndPositions() {
    var config = makeConfig([
      Workspace(name: "N0", kind: .normal),
      Workspace(name: "N1", kind: .normal),
      Workspace(name: "S0", kind: .scratchpad),
    ])
    config.placeWorkspace(id(config, "N0"), kind: .scratchpad, relativeTo: id(config, "S0"), after: false)
    #expect(names(config) == ["N1", "N0", "S0"])
    #expect(kind(config, "N0") == .scratchpad)
  }

  @Test
  func draggingScratchpadIntoWorkspacesRetypes() {
    var config = makeConfig([
      Workspace(name: "N0", kind: .normal),
      Workspace(name: "S0", kind: .scratchpad),
    ])
    config.placeWorkspace(id(config, "S0"), kind: .normal, relativeTo: id(config, "N0"), after: false)
    #expect(names(config) == ["S0", "N0"])
    #expect(kind(config, "S0") == .normal)
  }

  @Test
  func droppingWithNoTargetAppendsToTheKindSubset() {
    var config = makeConfig([
      Workspace(name: "N0", kind: .normal),
      Workspace(name: "N1", kind: .normal),
    ])
    // First scratchpad, dropped on the empty-section placeholder (no target).
    config.placeWorkspace(id(config, "N0"), kind: .scratchpad, relativeTo: nil, after: false)
    #expect(names(config) == ["N1", "N0"])
    #expect(kind(config, "N0") == .scratchpad)
  }
}
