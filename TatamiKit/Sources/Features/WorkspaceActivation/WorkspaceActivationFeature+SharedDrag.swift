// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Foundation

extension WorkspaceActivationFeature.State.DragState {
  var windowKey: WindowKey? {
    switch self {
    case .idle: nil
    case .moving(let key): key
    case .resizing(let drag): drag.key
    case .dropping(let drop): drop.dragged
    case .transferring(let drop): drop.dragged
    }
  }
}

extension WorkspaceActivationFeature {

  // MARK: Internal

  func windowDragDecision(
    dragged: WindowKey,
    state: State,
    pointer: CGPoint? = nil,
  ) -> (drag: State.DragState, rect: CGRect?, zone: DropZone?) {
    if let transfer = sharedWindowDropDecision(dragged: dragged, state: state, pointer: pointer) {
      return (.transferring(transfer.drop), transfer.rect, transfer.drop.zone)
    }
    if let local = dropDecision(dragged: dragged, state: state, pointer: pointer) {
      return (.dropping(.init(dragged: dragged, target: local.target, zone: local.zone)), local.targetRect, local.zone)
    }
    return (.moving(dragged), nil, nil)
  }

  func dragPreviewEffect(rect: CGRect?, zone: DropZone?) -> Effect<Action> {
    .run { [dragPreview] _ in
      guard !Task.isCancelled else { return }
      if let rect {
        if let zone {
          await dragPreview.show(rect, zone)
        } else {
          await dragPreview.showEmpty(rect)
        }
      } else {
        await dragPreview.hide()
      }
    }
    .cancellable(id: CancelID.dragPreview, cancelInFlight: true)
  }

  /// Cross-display drops target only the active host. Borrowed blocks are not
  /// destinations, and ordinary within-tree swaps retain their existing rules.
  func sharedWindowDropDecision(
    dragged: WindowKey,
    state: State,
    pointer capturedPointer: CGPoint? = nil,
  ) -> (drop: State.SharedWindowDrop, rect: CGRect)? {
    guard
      !state.isActivating,
      !state.isTilingPaused,
      !state.isLayoutSuspended,
      state.config.sharedApps.contains(where: { $0.bundleIdentifier == dragged.bundleId && $0.layout == .tiled }),
      let source = state.workspaceOwning(dragged),
      state.canManageWorkspace(source),
      let sourceDisplay = state.displayShowing(source),
      state.tilingTrees[source]?.windows.contains(dragged) == true
    else { return nil }
    let pointer = capturedPointer ?? mouse.axLocation()
    let candidates = state.connectedDisplays.filter { displays.bounds($0).contains(pointer) }
    guard
      candidates.count == 1,
      let display = candidates.first,
      !display.matches(sourceDisplay),
      state.desktops.isAvailable(on: display),
      let destination = state.activeWorkspace(on: display),
      destination != source,
      state.canManageWorkspace(destination)
    else { return nil }
    let (_, area) = tilingContext(for: destination, state: state)
    guard area.contains(pointer) else { return nil }
    guard let tree = state.tilingTrees[destination] else {
      return (.init(dragged: dragged, source: source, destination: destination, display: display, target: nil, zone: nil), area)
    }
    let zoomed = state.fullscreenZoomed[destination] ?? []
    guard let visible = Self.treeTrimmingZoomed(tree, zoomed: zoomed) else { return nil }
    let frames = visible.frames(in: area, gap: CGFloat(state.config.settings.layout.gapInner))
    if
      let workspace = state.presentedWorkspace(destination),
      let target = visible.automaticStackTarget(for: dragged, groupForWindow: state.windowGrouping(in: workspace).group(for:)),
      let rect = frames[target]
    {
      return (
        .init(dragged: dragged, source: source, destination: destination, display: display, target: target, zone: nil),
        rect,
      )
    }
    guard
      let target = visible.windows.first(where: { frames[$0]?.contains(pointer) == true }),
      let rect = frames[target],
      let zone = DropZone.quadrant(point: pointer, in: rect, allowsSwap: false)
    else { return nil }
    return (.init(dragged: dragged, source: source, destination: destination, display: display, target: target, zone: zone), rect)
  }

  func applySharedWindowDrop(_ drop: State.SharedWindowDrop, state: inout State) -> Effect<Action> {
    guard
      drop.source != drop.destination,
      !state.isTilingPaused,
      !state.isLayoutSuspended,
      state.config.sharedApps.contains(where: { $0.bundleIdentifier == drop.dragged.bundleId && $0.layout == .tiled }),
      let sourceWorkspace = state.config.activeProfile?.workspaces[id: drop.source],
      let destinationWorkspace = state.config.activeProfile?.workspaces[id: drop.destination],
      state.activeWorkspace(on: drop.display) == drop.destination,
      state.connectedDisplays.contains(where: { $0.matches(drop.display) }),
      state.canManageWorkspace(drop.source),
      state.canManageWorkspace(drop.destination),
      state.workspaceOwning(drop.dragged) == drop.source,
      let source = state.tilingTrees[drop.source],
      source.windows.contains(drop.dragged)
    else { return rejectedSharedWindowDrop(drop, state: &state) }
    let destination: BSPNode<WindowKey>
    if
      let target = drop.target,
      drop.zone == nil,
      let tree = state.tilingTrees[drop.destination],
      let workspace = state.presentedWorkspace(drop.destination),
      let visible = Self.treeTrimmingZoomed(tree, zoomed: state.fullscreenZoomed[drop.destination] ?? []),
      visible.automaticStackTarget(for: drop.dragged, groupForWindow: state.windowGrouping(in: workspace).group(for:)) == target,
      let stacked = tree.stackingAutomatically(drop.dragged, on: target)
    {
      destination = stacked
    } else if
      let target = drop.target,
      let zone = drop.zone,
      zone != .swap,
      let tree = state.tilingTrees[drop.destination],
      let path = tree.pathTo(window: target),
      !tree.windows.contains(drop.dragged)
    {
      let axis: BSPSplitAxis = zone == .top || zone == .bottom ? .horizontal : .vertical
      let child: BSPChild = zone == .top || zone == .left ? .first : .second
      let seeded = tree.replacing(path: path) { node in
        guard case .leaf(var leaf) = node else { return node }
        leaf.preferredSplit = axis
        leaf.preferredChild = child
        leaf.insertDirection = nil
        return .leaf(leaf)
      }
      let (_, area) = tilingContext(for: drop.destination, state: state)
      destination = seeded.inserting(drop.dragged, near: target, in: area)
    } else if drop.target == nil, drop.zone == nil, state.tilingTrees[drop.destination] == nil {
      destination = .leaf(drop.dragged)
    } else {
      return rejectedSharedWindowDrop(drop, state: &state)
    }
    let remaining = source.removing(drop.dragged)
    // Publish both memberships atomically before AX work can emit new frames.
    state.tilingTrees[drop.source] = remaining
    state.tilingTrees[drop.destination] = destination
    state.sharedWindowDisplayOwners[drop.dragged] = drop.display
    state.fullscreenZoomed[drop.source]?.remove(drop.dragged)
    state.removeFromWindowMRU([drop.dragged], workspaceId: drop.source)
    state.mruWindows[drop.destination, default: []].removeAll { $0 == drop.dragged }
    state.mruWindows[drop.destination, default: []].insert(drop.dragged, at: 0)
    state.focusedDisplay = drop.display
    for workspace in [drop.source, drop.destination] {
      state.pendingLayoutRestorations[workspace] = nil
      state.layoutRestorationBindings[workspace] = nil
      state.unresolvedFullscreenZoomSlots[workspace] = nil
    }
    let sourcePersistence: Effect<Action> = remaining.map {
      persist($0, fullscreenZoomed: state.fullscreenZoomed[drop.source] ?? [], for: sourceWorkspace)
    } ?? .run { [layoutStore] _ in await layoutStore.clear(drop.source) }
    return .merge(
      flushPointerDrivenLayout(workspaceId: drop.source, state: &state),
      flushPointerDrivenLayout(workspaceId: drop.destination, state: &state),
      sourcePersistence,
      persist(destination, fullscreenZoomed: state.fullscreenZoomed[drop.destination] ?? [], for: destinationWorkspace),
      refreshMarkers(state: state),
    )
  }

  // MARK: Private

  private func rejectedSharedWindowDrop(_ drop: State.SharedWindowDrop, state: inout State) -> Effect<Action> {
    guard state.workspaceOwning(drop.dragged) == drop.source else { return .none }
    return retile(windowKey: drop.dragged, state: &state)
  }

}
