import AppKit
import ComposableArchitecture
import Foundation
import Sharing

/// Tracks the active workspace per display, owns per-workspace BSP
/// trees, and dispatches activation + window-layout side effects.
@Reducer
public struct WorkspaceActivationFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.tatamiConfig) public var config = AppConfig()
    public var activeWorkspacesByDisplay: [DisplayName: Workspace.ID] = [:]
    public var previousWorkspaceID: Workspace.ID?
    public var isActivating = false
    /// Per-workspace BSP tree of bundle identifiers, kept in-memory only.
    public var tilingTrees: [Workspace.ID: BSPNode<String>] = [:]

    public init() {}

    public var primaryActiveWorkspaceID: Workspace.ID? {
      activeWorkspacesByDisplay.values.first
    }
  }

  public enum Action {
    case activate(workspaceId: Workspace.ID, setFocus: Bool)
    case activateNext
    case activatePrevious
    case activateRecent
    case moveFocusedAppTo(workspaceId: Workspace.ID)
    case focusedAppResolved(bundleId: String, workspaceId: Workspace.ID)
    case toggleFloatingOnFocusedApp
    case focusedFloatToggleResolved(bundleId: String, name: String)
    case togglePaused
    case bspSwap(BSPNode<String>.Side)
    case bspResize(axis: BSPNode<String>.SplitAxis, delta: CGFloat)
    case bspToggleOrientation
    case bspOpResolved(bundleId: String, op: BSPOp)
    case activationCompleted(workspaceId: Workspace.ID, display: DisplayName?)
  }

  /// Tag used to dispatch a BSP mutation once we've resolved the
  /// frontmost app's bundle ID from `NSWorkspace`.
  public enum BSPOp: Sendable, Hashable {
    case swap(BSPNode<String>.Side)
    case resize(axis: BSPNode<String>.SplitAxis, delta: CGFloat)
    case toggleOrientation
  }

  @Dependency(\.workspaceManager) var workspaceManager
  @Dependency(\.windowTiler) var windowTiler
  @Dependency(\.displays) var displays

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .activate(let workspaceId, let setFocus):
        return performActivate(
          workspaceId: workspaceId,
          setFocus: setFocus,
          state: &state
        )

      case .activateNext:
        return cycle(by: 1, state: &state)

      case .activatePrevious:
        return cycle(by: -1, state: &state)

      case .activateRecent:
        guard let id = state.previousWorkspaceID else { return .none }
        return .send(.activate(workspaceId: id, setFocus: true))

      case .moveFocusedAppTo(let workspaceId):
        return resolveFrontmost { bundleId in
          .focusedAppResolved(bundleId: bundleId, workspaceId: workspaceId)
        }

      case .focusedAppResolved(let bundleId, let workspaceId):
        state.$config.withLock { config in
          config.mutateActiveProfile { profile in
            for i in profile.workspaces.indices {
              profile.workspaces[i].apps.removeAll { $0.bundleIdentifier == bundleId }
            }
            if let idx = profile.workspaces.firstIndex(where: { $0.id == workspaceId }) {
              profile.workspaces[idx].apps.append(
                AppAssignment(bundleIdentifier: bundleId, name: bundleId)
              )
            }
          }
        }
        // Invalidate the destination workspace's tree so the next
        // activation rebuilds with the new participant.
        state.tilingTrees[workspaceId] = nil
        return .send(.activate(workspaceId: workspaceId, setFocus: true))

      case .toggleFloatingOnFocusedApp:
        return .run { send in
          let resolved = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map {
              (bundleId: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "")
            }
          }
          guard let resolved, !resolved.bundleId.isEmpty else { return }
          await send(
            .focusedFloatToggleResolved(bundleId: resolved.bundleId, name: resolved.name)
          )
        }

      case .focusedFloatToggleResolved(let bundleId, let name):
        state.$config.withLock { config in
          if config.floatingApps.contains(where: { $0.bundleIdentifier == bundleId }) {
            config.floatingApps.removeAll { $0.bundleIdentifier == bundleId }
          } else {
            config.floatingApps.append(
              FloatingApp(bundleIdentifier: bundleId, name: name.isEmpty ? bundleId : name)
            )
          }
        }
        return .none

      case .togglePaused:
        state.$config.withLock { config in
          config.settings.isPaused.toggle()
        }
        return .none

      case .bspSwap(let side):
        return resolveFrontmost { bundleId in
          .bspOpResolved(bundleId: bundleId, op: .swap(side))
        }

      case .bspResize(let axis, let delta):
        return resolveFrontmost { bundleId in
          .bspOpResolved(bundleId: bundleId, op: .resize(axis: axis, delta: delta))
        }

      case .bspToggleOrientation:
        return resolveFrontmost { bundleId in
          .bspOpResolved(bundleId: bundleId, op: .toggleOrientation)
        }

      case .bspOpResolved(let bundleId, let op):
        return applyBSPOp(bundleId: bundleId, op: op, state: &state)

      case .activationCompleted(let id, let display):
        state.isActivating = false
        if let display, let previous = state.activeWorkspacesByDisplay[display], previous != id {
          state.previousWorkspaceID = previous
        }
        if let display {
          state.activeWorkspacesByDisplay[display] = id
        }
        return .none
      }
    }
  }

  // MARK: - Activation

  private func performActivate(
    workspaceId: Workspace.ID,
    setFocus: Bool,
    state: inout State
  ) -> Effect<Action> {
    guard !state.config.settings.isPaused else { return .none }
    guard let profile = state.config.activeProfile,
          let workspace = profile.workspaces.first(where: { $0.id == workspaceId })
    else { return .none }
    guard !state.isActivating else { return .none }
    state.isActivating = true

    let targetDisplay = workspace.displayHint ?? displays.current()
    let peerBundleIds = Self.peerBundleIds(
      for: workspace,
      on: targetDisplay,
      in: profile
    )
    let request = ActivationRequest(
      workspace: workspace,
      floatingApps: state.config.floatingApps,
      targetDisplay: targetDisplay,
      displayPeerBundleIds: peerBundleIds,
      setFocus: setFocus,
      mouseFollowsFocus: setFocus && state.config.settings.mouseFollowsFocus,
      mouseHidesOnFocus: setFocus && state.config.settings.mouseHidesOnFocus
    )

    // Rebuild the BSP tree against the current set of assigned windows.
    let bundleIds = workspace.apps.map(\.bundleIdentifier)
    let tree = updatedTree(
      existing: state.tilingTrees[workspace.id],
      windows: bundleIds,
      mode: workspace.tilingMode
    )
    state.tilingTrees[workspace.id] = tree

    let settings = state.config.settings
    let mode = workspace.tilingMode
    let appBundleIds = workspace.apps.map(\.bundleIdentifier)

    return .run { [
      mgr = workspaceManager,
      tiler = windowTiler
    ] send in
      await mgr.activate(request)
      let frames = await MainActor.run {
        Self.computeFrames(
          mode: mode,
          tree: tree,
          appBundleIds: appBundleIds,
          settings: settings,
          targetDisplay: targetDisplay
        )
      }
      if !frames.isEmpty {
        await tiler.apply(
          FrameApplication(bundleIdToFrame: frames, targetDisplay: targetDisplay)
        )
      }
      await send(.activationCompleted(workspaceId: workspaceId, display: targetDisplay))
    }
  }

  // MARK: - BSP ops

  private func applyBSPOp(
    bundleId: String,
    op: BSPOp,
    state: inout State
  ) -> Effect<Action> {
    guard let workspaceId = state.primaryActiveWorkspaceID,
          let workspace = state.config.activeProfile?
            .workspaces.first(where: { $0.id == workspaceId }),
          workspace.tilingMode == .bsp,
          var tree = state.tilingTrees[workspaceId]
    else { return .none }

    switch op {
    case .swap(let side):
      guard let path = tree.pathTo(window: bundleId), !path.isEmpty else { return .none }
      let target = sibling(of: bundleId, in: tree, preferredSide: side) ?? firstLeaf(in: tree)
      guard let target, target != bundleId else { return .none }
      tree = tree.swapping(bundleId, target)
    case .resize(let axis, let delta):
      tree = tree.resizing(window: bundleId, axis: axis, delta: delta)
    case .toggleOrientation:
      tree = tree.togglingSplit(at: bundleId)
    }

    state.tilingTrees[workspaceId] = tree

    let display = workspace.displayHint ?? displays.current()
    let settings = state.config.settings
    let mode = workspace.tilingMode
    let appBundleIds = workspace.apps.map(\.bundleIdentifier)
    return .run { [tiler = windowTiler] _ in
      let frames = await MainActor.run {
        Self.computeFrames(
          mode: mode,
          tree: tree,
          appBundleIds: appBundleIds,
          settings: settings,
          targetDisplay: display
        )
      }
      await tiler.apply(
        FrameApplication(bundleIdToFrame: frames, targetDisplay: display)
      )
    }
  }

  /// Pick a sibling to swap with. For BSP we don't yet have geometric
  /// "neighbor in direction" lookup, so fall back to swapping with the
  /// nearest sibling on the requested side of the parent split.
  private func sibling(
    of window: String,
    in tree: BSPNode<String>,
    preferredSide: BSPNode<String>.Side
  ) -> String? {
    guard let path = tree.pathTo(window: window), !path.isEmpty else { return nil }
    let parentPath = Array(path.dropLast())
    return tree.firstLeafID(at: parentPath + [preferredSide == .left ? .left : .right])
      ?? tree.firstLeafID(at: parentPath + [path.last == .left ? .right : .left])
  }

  private func firstLeaf(in tree: BSPNode<String>) -> String? {
    tree.windows.first
  }

  // MARK: - Cycle

  private func cycle(by direction: Int, state: inout State) -> Effect<Action> {
    guard let workspaces = state.config.activeProfile?.workspaces, !workspaces.isEmpty
    else { return .none }
    let currentID = state.activeWorkspacesByDisplay.values.first
      ?? state.primaryActiveWorkspaceID
    let currentIndex = workspaces.firstIndex { $0.id == currentID } ?? -1
    let count = workspaces.count
    let nextIndex = (currentIndex + direction + count) % count
    return .send(.activate(workspaceId: workspaces[nextIndex].id, setFocus: true))
  }

  // MARK: - Helpers

  /// Either reuse the existing tree (if its windows match) or rebuild.
  private func updatedTree(
    existing: BSPNode<String>?,
    windows: [String],
    mode: TilingMode
  ) -> BSPNode<String>? {
    guard mode == .bsp else { return nil }
    let target = Set(windows)
    if let existing, Set(existing.windows) == target { return existing }
    let display = CGRect(x: 0, y: 0, width: 1, height: 1)  // shape-only for inserts
    return BSPNode.build(windows, in: display)
  }

  @MainActor
  static func computeFrames(
    mode: TilingMode,
    tree: BSPNode<String>?,
    appBundleIds: [String],
    settings: AppSettings,
    targetDisplay: DisplayName?
  ) -> [String: CGRect] {
    let workArea = ScreenGeometry.workArea(for: targetDisplay).insetBy(
      dx: CGFloat(settings.gapOuter),
      dy: CGFloat(settings.gapOuter)
    )
    switch mode {
    case .floating:
      return [:]
    case .stack:
      return Dictionary(uniqueKeysWithValues:
        appBundleIds.map { ($0, workArea) })
    case .bsp:
      return tree?.frames(in: workArea, gap: CGFloat(settings.gapInner)) ?? [:]
    }
  }

  private func resolveFrontmost(
    _ continuation: @escaping @Sendable (String) -> Action
  ) -> Effect<Action> {
    .run { send in
      let bundleId = await MainActor.run {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      }
      guard let bundleId, !bundleId.isEmpty else { return }
      await send(continuation(bundleId))
    }
  }

  private static func peerBundleIds(
    for workspace: Workspace,
    on display: DisplayName?,
    in profile: Profile
  ) -> Set<String> {
    profile.workspaces
      .filter { peer in
        peer.id != workspace.id && (display == nil || peer.displayHint == display)
      }
      .flatMap { $0.apps.map(\.bundleIdentifier) }
      .reduce(into: Set<String>()) { $0.insert($1) }
  }
}

extension BSPNode {
  /// Walks the tree following the given path and returns the leaf's
  /// window ID, if reachable.
  func firstLeafID(at path: [Side]) -> WindowID? {
    var current = self
    for side in path {
      guard case .branch(_, _, let left, let right) = current else { return nil }
      current = side == .left ? left : right
    }
    switch current {
    case .leaf(let id): return id
    case .branch(_, _, let left, _):
      var node = left
      while case .branch(_, _, let l, _) = node { node = l }
      if case .leaf(let id) = node { return id }
      return nil
    }
  }
}
