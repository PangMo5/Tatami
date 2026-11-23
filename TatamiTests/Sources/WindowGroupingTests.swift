// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiKit

struct WindowGroupingTests {

  // MARK: Internal

  @Test
  func `enabling groups existing windows and disabling keeps manual stacks`() throws {
    let initial = BSPNode<WindowKey>.branch(BSPBranch(
      split: .vertical,
      ratio: 0.3,
      left: .leaf(BSPLeaf(windowList: [browser, secondBrowser])),
      right: .branch(BSPBranch(split: .horizontal, ratio: 0.5, left: .leaf(thirdBrowser), right: .leaf(terminal))),
    ))
    let grouping = AppWindowGrouping(workspace: workspace(grouped: true), sharedApps: [])
    let grouped = try #require(grouping.reconcile(initial, in: workArea, settings: AppSettings()))
    #expect(grouped.leafCount == 2)
    let anchorPath = try #require(grouped.pathTo(window: browser))
    #expect(grouped.pathTo(window: thirdBrowser) == anchorPath)

    let snapshot = LayoutSnapshot(liveTree: grouped, fullscreenZoomed: [])
    let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: JSONEncoder().encode(snapshot))
    let restored = try #require(BSPNode<WindowKey>.hydrate(template: decoded.tree, keys: initial.windows))
    let ungrouped = try #require(AppWindowGrouping().reconcile(restored, in: workArea, settings: AppSettings()))
    #expect(ungrouped.leafCount == 3)
    #expect(ungrouped.pathTo(window: browser) == ungrouped.pathTo(window: secondBrowser))
    #expect(ungrouped.pathTo(window: browser) != ungrouped.pathTo(window: thirdBrowser))
    #expect(ungrouped.frames(in: workArea, gap: 0)[terminal]?.width == 700)
  }

  @Test
  func `new and closed windows within a stack keep the tile subdivisions`() throws {
    let initial = BSPNode<WindowKey>.branch(BSPBranch(
      split: .vertical,
      ratio: 0.3,
      left: .leaf(browser),
      right: .leaf(terminal),
    ))
    let grouped = try #require(WorkspaceActivationFeature.mergeTree(
      existing: initial,
      target: [browser, terminal, secondBrowser],
      focused: { terminal },
      insertionPoint: terminal,
      workArea: workArea,
      settings: AppSettings(),
      grouping: AppWindowGrouping(workspace: workspace(grouped: true), sharedApps: []),
    ))
    #expect(grouped.hasSameTileSubdivisions(as: initial))
    #expect(grouped.frames(in: workArea, gap: 0)[terminal] == initial.frames(in: workArea, gap: 0)[terminal])
    #expect(grouped.pathTo(window: browser) == grouped.pathTo(window: secondBrowser))
    let closed = try #require(grouped.removing(browser))
    #expect(closed.hasSameTileSubdivisions(as: grouped))
    #expect(closed.frames(in: workArea, gap: 0)[terminal] == grouped.frames(in: workArea, gap: 0)[terminal])
  }

  @Test
  func `directional drop moves the complete automatic stack`() throws {
    let initial = BSPNode<WindowKey>.branch(BSPBranch(
      split: .vertical,
      ratio: 0.3,
      left: .leaf(browser),
      right: .leaf(terminal),
    ))
    let grouped = try #require(initial.stackingAutomatically(secondBrowser, on: browser))
    let moved = grouped.warpingInto(source: secondBrowser, target: terminal, axis: .horizontal, child: .second)
    #expect(moved.pathTo(window: browser) == [.right])
    #expect(moved.pathTo(window: secondBrowser) == [.right])
    #expect(moved.pathTo(window: terminal) == [.left])
    let ungrouped = try #require(AppWindowGrouping().reconcile(moved, in: workArea, settings: AppSettings()))
    #expect(ungrouped.leafCount == 3)
  }

  @Test
  func `a named group can contain multiple apps and all assigned apps can share one tile`() throws {
    let group = StackGroup(name: "Research", bundleIdentifiers: [browser.bundleId, terminal.bundleId])
    var workspace = workspace(grouped: false)
    workspace.apps.append(AppAssignment(bundleIdentifier: terminal.bundleId, name: "Terminal"))
    workspace.stackGroups = [group]
    let grouping = AppWindowGrouping(workspace: workspace, sharedApps: [])
    #expect(grouping.group(for: browser) == .workspace(group.id))
    #expect(grouping.group(for: terminal) == .workspace(group.id))
    let initial = BSPNode<WindowKey>.branch(BSPBranch(
      split: .vertical,
      ratio: 0.3,
      left: .leaf(browser),
      right: .leaf(terminal),
    ))
    let grouped = try #require(grouping.reconcile(initial, in: workArea, settings: AppSettings()))
    #expect(grouped.leafCount == 1)
    workspace.stackGroups = []
    workspace.stackAllAssignedApps = true
    let all = AppWindowGrouping(workspace: workspace, sharedApps: [])
    #expect(all.group(for: browser) == .allAssigned)
    #expect(all.group(for: terminal) == .allAssigned)
    #expect(all.reconcile(grouped, in: workArea, settings: AppSettings()) == grouped)
  }

  @Test
  func `workspace group precedes the corresponding shared group`() {
    let shared = SharedApp(bundleIdentifier: browser.bundleId, name: "Browser")
    let group = StackGroup(name: "Shared", bundleIdentifiers: [browser.bundleId])
    let local = workspace(grouped: true)
    #expect(AppWindowGrouping(workspace: local, sharedApps: [shared], sharedGroups: [group])
      .group(for: browser) == local.stackGroups.first.map { .workspace($0.id) })
    #expect(AppWindowGrouping(workspace: Workspace(name: "Host"), sharedApps: [shared], sharedGroups: [group])
      .group(for: browser) == .shared(group.id))
    #expect(AppWindowGrouping(
      workspace: Workspace(name: "Borrow", kind: .scratchpad),
      sharedApps: [shared],
      sharedGroups: [group],
    )
    .group(for: browser) == nil)
  }

  @Test
  func `toggling always on top keeps group membership`() {
    let workspace = workspace(grouped: true)
    let group = StackGroup(name: "Shared", bundleIdentifiers: [browser.bundleId])
    let shared = SharedApp(bundleIdentifier: browser.bundleId, name: "Browser")
    let profile = Profile(name: "Test", workspaces: [workspace])
    var config = AppConfig(profiles: [profile], sharedApps: [shared], activeProfileId: profile.id, sharedStackGroups: [group])
    let originalSharedGroups = config.sharedStackGroups
    _ = config.toggleFloating(bundleId: browser.bundleId, name: "Browser", in: workspace.id)
    let floating = config.activeProfile?.workspaces[id: workspace.id]
    #expect(floating?.apps.first?.layout == .floating)
    #expect(floating?.stackGroups == workspace.stackGroups)
    _ = config.toggleFloating(bundleId: browser.bundleId, name: "Browser", in: workspace.id)
    #expect(config.activeProfile?.workspaces[id: workspace.id] == workspace)
    _ = config.toggleSharedFloating(bundleId: browser.bundleId, name: "Browser")
    #expect(config.sharedStackGroups == originalSharedGroups)
    _ = config.toggleSharedFloating(bundleId: browser.bundleId, name: "Browser")
    #expect(config.sharedApps == [shared])
    #expect(config.sharedStackGroups == originalSharedGroups)
  }

  // MARK: Private

  private let browser = WindowKey(pid: 1, windowID: 10, bundleId: "app.browser")
  private let secondBrowser = WindowKey(pid: 1, windowID: 11, bundleId: "app.browser")
  private let thirdBrowser = WindowKey(pid: 1, windowID: 12, bundleId: "app.browser")
  private let terminal = WindowKey(pid: 2, windowID: 20, bundleId: "app.terminal")
  private let workArea = CGRect(x: 0, y: 0, width: 1000, height: 800)

  private func workspace(grouped: Bool) -> Workspace {
    Workspace(
      name: "Browser",
      apps: [AppAssignment(bundleIdentifier: browser.bundleId, name: "Browser")],
      stackGroups: grouped ? [StackGroup(name: "Browser", bundleIdentifiers: [browser.bundleId])] : [],
    )
  }

}
