// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import SwiftUI
import TatamiKit

private struct FullscreenItem: Identifiable, Equatable {
  var index: Int
  var bundleId: String
  var liveKey: WindowKey?
  /// Slot of this fullscreen window (nil when live) — lets restore target the
  /// exact same-app window's occurrence in an inactive preview.
  var slot: SlotID?
  var id: Int { index }
}

private struct LayoutDropOverlay: View {
  var targetRect: CGRect
  var zoneRect: CGRect

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5)
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .frame(width: targetRect.width, height: targetRect.height)
        .position(x: targetRect.midX, y: targetRect.midY)
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.accentColor.opacity(0.35))
        .frame(width: zoneRect.width, height: zoneRect.height)
        .position(x: zoneRect.midX, y: zoneRect.midY)
    }
  }
}

// MARK: - Preview view

/// Graphical layout preview + editor at the top of a workspace's detail. A pure
/// renderer over `WorkspaceLayoutFeature`: it draws `store.resolved`, forwards
/// gestures as intent actions, and keeps only transient drag state locally.
/// Drag a split divider to resize, drag a tile onto another to move it (5-zone
/// drop) or onto the fullscreen band to fullscreen it, drag a fullscreen chip
/// back to restore it, tap a tile to select it, and use the toolbar to rotate /
/// flip / balance / toggle a split / fullscreen. A scratchpad shows the screen
/// with the scratchpad docked at its borrow edge + width, the rest dimmed.
struct WorkspaceLayoutPreview: View {
  let store: StoreOf<WorkspaceLayoutFeature>

  /// In-progress divider resize (trimmed branch path + ratio) — committed on
  /// release. Transient, so it stays view-local.
  @State private var pendingRatio: (trimmedPath: [BSPSide], ratio: CGFloat)?
  @State private var tileDrag: (source: [BSPSide], location: CGPoint)?
  @State private var chipDrag: (item: FullscreenItem, location: CGPoint)?

  private let coordinateSpace = "layoutCanvas"
  private let canvasAspect: CGFloat = 16.0 / 10.0
  private let maxTileAreaHeight: CGFloat = 240
  private let bandHeight: CGFloat = 56
  private let bandGap: CGFloat = 8

  private var resolved: ResolvedLayout? { store.resolved }
  private var hidden: Set<String> { store.hiddenSharedBundleIds }
  private var hasFullscreen: Bool { resolved?.hasFullscreen ?? false }
  private var tileAreaTop: CGFloat { hasFullscreen ? bandHeight + bandGap : 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Indicator until this workspace's async loads (snapshot + window info)
      // settle — one render instead of flickering through the load burst.
      if !store.previewReady {
        loadingPlaceholder
      } else if resolved == nil {
        emptyState
      } else {
        toolbar
        canvas
        if !store.nonTiledApps.isEmpty { nonTiledBand }
        footnote
      }
    }
    .task(id: store.workspaceId) { store.send(.onAppear) }
    .task { store.send(.startObservingAppActivity) }
    .task(id: store.tiledBundleIds) { store.send(.loadWindowTitles(bundleIds: store.tiledBundleIds)) }
  }

  private var loadingPlaceholder: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading layout…").font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    .padding(.vertical, 8)
  }

  // MARK: Non-tiled band (floating + ignored, read-only)

  private var nonTiledBand: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Not tiled", systemImage: "rectangle.dashed")
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(store.nonTiledApps) { app in nonTiledChip(app) }
        }
        .padding(.horizontal, 2)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    )
  }

  private func nonTiledChip(_ app: NonTiledApp) -> some View {
    HStack(spacing: 5) {
      if app.isShared {
        Image(systemName: "square.on.square").font(.system(size: 9)).foregroundStyle(.secondary)
      }
      AppIcon(bundleIdentifier: app.bundleId, iconPath: app.iconPath)
        .frame(width: 18, height: 18)
      Text(app.name).font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
      Image(systemName: app.mode == .floating ? "rectangle.on.rectangle" : "nosign")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Capsule().fill(Color.secondary.opacity(0.12)))
    .help(String(localized: nonTiledHelp(app)))
    .contextMenu {
      Button {
        store.send(.revealApp(bundleId: app.bundleId, isShared: app.isShared))
      } label: {
        Label(
          app.isShared ? "Configure in Shared Apps" : "Configure in Apps",
          systemImage: "gearshape"
        )
      }
    }
  }

  private func nonTiledHelp(_ app: NonTiledApp) -> LocalizedStringResource {
    switch (app.mode, app.isShared) {
    case (.floating, true):
      "Always on Top. Kept above the tiles and shared with every workspace."
    case (.floating, false):
      "Always on Top. Kept above the tiles in this workspace."
    case (_, true):
      "Leave As Is. Kept in place and shared with every workspace."
    case (_, false):
      "Leave As Is. Kept in place in this workspace."
    }
  }

  private func isShared(_ bundleId: String) -> Bool {
    store.config.sharedApps.contains { $0.bundleIdentifier == bundleId }
  }

  // MARK: Empty

  private var emptyState: some View {
    HStack(spacing: 8) {
      Image(systemName: "rectangle.split.2x2").foregroundStyle(.secondary)
      Text("No tiled apps to lay out yet. Add tiled apps below to shape a layout.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 4) {
      Spacer()
      toolButton("rotate.right", help: "Rotate 90°") { store.send(.rotate) }
      toolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip left ↔ right") {
        store.send(.mirror(axis: .vertical))
      }
      toolButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip top ↔ bottom") {
        store.send(.mirror(axis: .horizontal))
      }
      toolButton("square.grid.2x2", help: "Balance all splits equally") { store.send(.balance) }

      Divider().frame(height: 16)

      toolButton(
        "rectangle.split.2x1",
        help: "Toggle split orientation of the selected tile",
        enabled: store.selectedTile != nil
      ) {
        store.send(.toggleOrientation)
      }
      toolButton(
        "arrow.up.left.and.arrow.down.right",
        help: "Fullscreen the selected tile",
        enabled: store.selectedTile != nil
      ) {
        if let sel = store.selectedTile {
          store.send(.toggleFullscreen(
            bundleId: sel.bundleId, liveKey: sel.liveKey, occurrence: sel.occurrence, zoomIn: true
          ))
        }
      }
    }
  }

  private func toolButton(
    _ symbol: String,
    help: LocalizedStringResource,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(String(localized: help))
  }

  // MARK: Canvas (fullscreen band + tile area share one coordinate space)

  private var canvas: some View {
    GeometryReader { geo in
      let fullscreen = fullscreenList
      let bandRect = CGRect(x: 0, y: 0, width: geo.size.width, height: hasFullscreen ? bandHeight : 0)
      let tileArea = CGSize(width: geo.size.width, height: geo.size.height - tileAreaTop)
      let canvasRect = fittedCanvas(in: tileArea).offsetBy(dx: 0, dy: tileAreaTop)
      let dock = dockRect(in: canvasRect)
      let regions = resolved?.renderRegions(
        in: dock, hidden: hidden,
        pendingRatio: pendingRatio.map { ($0.trimmedPath, $0.ratio) }
      ) ?? (tiles: [], dividers: [])
      let labels = windowLabels(fullscreen: fullscreen, tiles: regions.tiles)

      ZStack(alignment: .topLeading) {
        if hasFullscreen {
          fullscreenBand(fullscreen, labels: labels.chips, in: bandRect)
        }

        RoundedRectangle(cornerRadius: 8)
          .fill(Color.secondary.opacity(chipDrag != nil ? 0.18 : 0.10))
          .frame(width: canvasRect.width, height: canvasRect.height)
          .position(x: canvasRect.midX, y: canvasRect.midY)
          .onTapGesture { store.send(.backgroundTapped) }

        if store.workspace?.kind == .scratchpad {
          hostLabel(canvas: canvasRect, dock: dock)
          RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.35)))
            .frame(width: dock.width, height: dock.height)
            .position(x: dock.midX, y: dock.midY)
        }

        if regions.tiles.isEmpty {
          Text(chipDrag != nil ? "Drop here to restore" : "All windows fullscreen")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .position(x: dock.midX, y: dock.midY)
        }

        ForEach(regions.tiles) { leaf in
          tileView(leaf, allLeaves: regions.tiles, label: labels.tiles[leaf.path] ?? "")
        }
        ForEach(regions.dividers) { divider in
          dividerHandle(divider)
        }
        if let rects = dropOverlayRects(leaves: regions.tiles) {
          LayoutDropOverlay(targetRect: rects.target, zoneRect: rects.zone)
            .allowsHitTesting(false)
        }
        if let drag = tileDrag, let source = regions.tiles.first(where: { $0.path == drag.source }) {
          dragGhost(bundleId: source.representative ?? "", label: labels.tiles[drag.source] ?? "", at: drag.location)
        }
        if let chip = chipDrag {
          dragGhost(
            bundleId: chip.item.bundleId,
            label: labels.chips[chip.item.index] ?? "",
            at: chip.location
          )
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      .coordinateSpace(name: coordinateSpace)
      .onContinuousHover(coordinateSpace: .named(coordinateSpace)) { phase in
        guard tileDrag == nil, chipDrag == nil else { return }
        switch phase {
        case .active(let loc): updateCursor(at: loc, regions: regions)
        case .ended: NSCursor.arrow.set()
        }
      }
    }
    .frame(height: maxTileAreaHeight + tileAreaTop)
  }

  private var fullscreenList: [FullscreenItem] {
    (resolved?.fullscreenItems() ?? []).enumerated().map { idx, item in
      FullscreenItem(index: idx, bundleId: item.bundleId, liveKey: item.liveKey, slot: item.slot)
    }
  }

  private var footnote: some View {
    HStack(spacing: 6) {
      Image(systemName: (resolved?.isLive == true) ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
        .font(.caption2)
      if resolved?.isLive == true {
        Text("Live. Edits re-tile your windows now.")
          .font(.caption)
      } else {
        Text("Saved layout. Edits apply on next activation.")
          .font(.caption)
      }
    }
    .foregroundStyle(.secondary)
  }

  // MARK: Cursor (single source of truth over the whole canvas)

  private func updateCursor(at loc: CGPoint, regions: (tiles: [RenderLeaf], dividers: [RenderDivider])) {
    if let divider = regions.dividers.first(where: { dividerHitRect($0).contains(loc) }) {
      (divider.axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    } else if regions.tiles.contains(where: { $0.rect.contains(loc) }) {
      NSCursor.openHand.set()
    } else {
      NSCursor.arrow.set()
    }
  }

  private func dividerHitRect(_ divider: RenderDivider) -> CGRect {
    let thickness: CGFloat = 10
    let isVertical = divider.axis == .vertical
    let x = isVertical ? divider.rect.minX + divider.ratio * divider.rect.width : divider.rect.midX
    let y = isVertical ? divider.rect.midY : divider.rect.minY + divider.ratio * divider.rect.height
    let w = isVertical ? thickness : divider.rect.width
    let h = isVertical ? divider.rect.height : thickness
    return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
  }

  // MARK: Fullscreen band (drag target + draggable chips)

  private func fullscreenBand(
    _ items: [FullscreenItem], labels: [Int: String], in rect: CGRect
  ) -> some View {
    let armed = tileDrag != nil
    return VStack(alignment: .leading, spacing: 3) {
      Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(items) { item in
            fullscreenChip(item, label: labels[item.index] ?? "")
          }
        }
        .padding(.horizontal, 2)
      }
    }
    .padding(8)
    .frame(width: rect.width, height: rect.height, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(armed ? 0.22 : 0.08)))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.accentColor.opacity(armed ? 0.9 : 0.4),
                      style: StrokeStyle(lineWidth: armed ? 2 : 1, dash: [4, 3]))
    )
    .position(x: rect.midX, y: rect.midY)
  }

  private func fullscreenChip(_ item: FullscreenItem, label: String) -> some View {
    let dragging = chipDrag?.item == item
    return HStack(spacing: 6) {
      AppIcon(bundleIdentifier: item.bundleId, iconPath: iconPath(for: item.bundleId))
        .frame(width: 18, height: 18)
      Text(label)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 150)
      Image(systemName: "arrow.down.right.and.arrow.up.left")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
    .opacity(dragging ? 0.4 : 1)
    .help("Tap or drag onto the tiles to restore")
    .onTapGesture {
      store.send(.toggleFullscreen(
        bundleId: item.bundleId, liveKey: item.liveKey, occurrence: item.slot?.occurrence, zoomIn: false
      ))
    }
    .gesture(chipDragGesture(item))
  }

  private func chipDragGesture(_ item: FullscreenItem) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in
        if chipDrag == nil { NSCursor.closedHand.set() }
        chipDrag = (item, value.location)
      }
      .onEnded { value in
        defer {
          chipDrag = nil
          NSCursor.arrow.set()
        }
        // Dropped below the band, onto the tile area → restore (re-tile).
        if value.location.y > bandHeight {
          store.send(.toggleFullscreen(
            bundleId: item.bundleId, liveKey: item.liveKey, occurrence: item.slot?.occurrence, zoomIn: false
          ))
        }
      }
  }

  // MARK: Tile

  private func tileView(_ leaf: RenderLeaf, allLeaves: [RenderLeaf], label: String) -> some View {
    let isDragging = tileDrag?.source == leaf.path
    let isSelected = store.selectedTile?.path == leaf.path
    return ZStack {
      RoundedRectangle(cornerRadius: 5)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                          lineWidth: isSelected ? 2.5 : 1)
        )
      VStack(spacing: 3) {
        if let bid = leaf.representative {
          AppIcon(bundleIdentifier: bid, iconPath: iconPath(for: bid))
            .frame(width: min(28, leaf.rect.height * 0.4), height: min(28, leaf.rect.height * 0.4))
          if leaf.rect.height > 44, leaf.rect.width > 54 {
            Text(label)
              .font(.caption2)
              .lineLimit(1)
              .truncationMode(.middle)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4)
          }
        }
      }
      if leaf.stackCount > 1 {
        Text("\(leaf.stackCount)")
          .font(.caption2.bold())
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.accentColor.opacity(0.8)))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(3)
      }
      if let bid = leaf.representative, isShared(bid) {
        Image(systemName: "square.on.square")
          .font(.system(size: 9))
          .foregroundStyle(.white)
          .padding(3)
          .background(Circle().fill(Color.accentColor.opacity(0.75)))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(3)
          .help("Shared app — in every workspace")
      }
    }
    .padding(2)
    .frame(width: leaf.rect.width, height: leaf.rect.height)
    .position(x: leaf.rect.midX, y: leaf.rect.midY)
    .opacity(isDragging ? 0.3 : 1)
    .onTapGesture {
      if let bid = leaf.representative {
        store.send(.tileTapped(
          path: leaf.path, bundleId: bid, liveKey: leaf.liveKey, occurrence: leaf.slot?.occurrence
        ))
      }
    }
    .gesture(tileDragGesture(leaf, allLeaves: allLeaves))
  }

  private func tileDragGesture(_ leaf: RenderLeaf, allLeaves: [RenderLeaf]) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in
        if tileDrag == nil { NSCursor.closedHand.set() }
        tileDrag = (leaf.path, value.location)
      }
      .onEnded { value in
        defer {
          tileDrag = nil
          NSCursor.arrow.set()
        }
        // Dropped on the fullscreen band → fullscreen this window.
        if hasFullscreen, value.location.y < bandHeight, let bid = leaf.representative {
          store.send(.toggleFullscreen(
            bundleId: bid, liveKey: leaf.liveKey, occurrence: leaf.slot?.occurrence, zoomIn: true
          ))
          return
        }
        guard let drop = dropTarget(leaves: allLeaves, source: leaf.path, at: value.location) else { return }
        store.send(.tileMoved(sourceTrimmedPath: leaf.path, targetTrimmedPath: drop.path, zone: drop.zone))
      }
  }

  // MARK: Drag ghost

  private func dragGhost(bundleId: String, label: String, at point: CGPoint) -> some View {
    HStack(spacing: 6) {
      AppIcon(bundleIdentifier: bundleId, iconPath: iconPath(for: bundleId))
        .frame(width: 18, height: 18)
      Text(label)
        .font(.caption)
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
    .shadow(radius: 4, y: 2)
    .fixedSize()
    .position(x: point.x, y: point.y - 6)
    .allowsHitTesting(false)
  }

  // MARK: Divider

  private func dividerHandle(_ divider: RenderDivider) -> some View {
    let thickness: CGFloat = 10
    let isVertical = divider.axis == .vertical
    let x = isVertical ? divider.rect.minX + divider.ratio * divider.rect.width : divider.rect.midX
    let y = isVertical ? divider.rect.midY : divider.rect.minY + divider.ratio * divider.rect.height
    let isActive = pendingRatio?.trimmedPath == divider.path
    return Rectangle()
      .fill(Color.clear)
      .contentShape(Rectangle())
      .frame(
        width: isVertical ? thickness : divider.rect.width,
        height: isVertical ? divider.rect.height : thickness
      )
      .overlay(
        Capsule()
          .fill(Color.secondary.opacity(isActive ? 0.7 : 0.35))
          .frame(
            width: isVertical ? 3 : max(16, divider.rect.width * 0.2),
            height: isVertical ? max(16, divider.rect.height * 0.2) : 3
          )
      )
      .position(x: x, y: y)
      .gesture(dividerDragGesture(divider))
  }

  private func dividerDragGesture(_ divider: RenderDivider) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in
        let raw: CGFloat = divider.axis == .vertical
          ? (value.location.x - divider.rect.minX) / max(divider.rect.width, 1)
          : (value.location.y - divider.rect.minY) / max(divider.rect.height, 1)
        pendingRatio = (divider.path, min(0.9, max(0.1, raw)))
      }
      .onEnded { _ in
        if let pending = pendingRatio {
          store.send(.dividerResized(trimmedBranchPath: pending.trimmedPath, ratio: pending.ratio))
        }
        pendingRatio = nil
      }
  }

  // MARK: Drop overlay

  private func dropTarget(leaves: [RenderLeaf], source: [BSPSide], at point: CGPoint) -> (path: [BSPSide], zone: DropZone)? {
    guard let target = leaves.first(where: { $0.path != source && $0.rect.contains(point) }),
          let zone = DropZone.quadrant(point: point, in: target.rect)
    else { return nil }
    return (target.path, zone)
  }

  private func dropOverlayRects(leaves: [RenderLeaf]) -> (target: CGRect, zone: CGRect)? {
    guard let drag = tileDrag,
          let drop = dropTarget(leaves: leaves, source: drag.source, at: drag.location),
          let target = leaves.first(where: { $0.path == drop.path })
    else { return nil }
    return (target.rect, zoneRect(in: target.rect, zone: drop.zone))
  }

  private func zoneRect(in rect: CGRect, zone: DropZone) -> CGRect {
    switch zone {
    case .swap: return rect
    case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
  }

  // MARK: Scratchpad dock geometry

  private var resolvedEdge: BorrowEdge {
    store.workspace?.borrowEdge ?? store.config.settings.switching.borrowDefaultEdge ?? .right
  }

  private var resolvedFraction: CGFloat {
    CGFloat(store.workspace?.borrowFraction ?? store.config.settings.switching.borrowFraction)
  }

  private func dockRect(in canvas: CGRect) -> CGRect {
    guard store.workspace?.kind == .scratchpad else { return canvas }
    let f = min(0.9, max(0.1, resolvedFraction))
    switch resolvedEdge {
    case .right: return CGRect(x: canvas.maxX - canvas.width * f, y: canvas.minY, width: canvas.width * f, height: canvas.height)
    case .left: return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width * f, height: canvas.height)
    case .top: return CGRect(x: canvas.minX, y: canvas.minY, width: canvas.width, height: canvas.height * f)
    case .bottom: return CGRect(x: canvas.minX, y: canvas.maxY - canvas.height * f, width: canvas.width, height: canvas.height * f)
    }
  }

  private func hostLabel(canvas: CGRect, dock: CGRect) -> some View {
    let center: CGPoint
    switch resolvedEdge {
    case .right: center = CGPoint(x: (canvas.minX + dock.minX) / 2, y: canvas.midY)
    case .left: center = CGPoint(x: (dock.maxX + canvas.maxX) / 2, y: canvas.midY)
    case .top: center = CGPoint(x: canvas.midX, y: (dock.maxY + canvas.maxY) / 2)
    case .bottom: center = CGPoint(x: canvas.midX, y: (canvas.minY + dock.minY) / 2)
    }
    return Text("Host workspace")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .position(x: center.x, y: center.y)
  }

  // MARK: Canvas geometry

  private func fittedCanvas(in size: CGSize) -> CGRect {
    var w = size.width
    var h = w / canvasAspect
    if h > size.height {
      h = size.height
      w = h * canvasAspect
    }
    return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
  }

  // MARK: App metadata + labels

  private func iconPath(for bundleId: String) -> String? {
    store.workspace?.apps.first { $0.bundleIdentifier == bundleId }?.iconPath
      ?? store.config.sharedApps.first { $0.bundleIdentifier == bundleId }?.iconPath
  }

  private func appName(for bundleId: String) -> String {
    store.workspace?.apps.first { $0.bundleIdentifier == bundleId }?.name
      ?? store.config.sharedApps.first { $0.bundleIdentifier == bundleId }?.name
      ?? bundleId
  }

  /// Labels for every rendered window — fullscreen chips *and* tiles. A live
  /// window uses its exact title (by key); an inactive one indexes the app's
  /// titles by its slot occurrence (windowID rank), which aligns with
  /// `titlesByBundle` (also windowID-sorted), so several windows of one app read
  /// distinctly and consistently across chips and tiles.
  private func windowLabels(fullscreen: [FullscreenItem], tiles: [RenderLeaf])
    -> (chips: [Int: String], tiles: [[BSPSide]: String]) {
    let byBundle = store.titlesByBundle
    let titles = store.windowTitles
    func label(_ bid: String, liveKey: WindowKey?, occurrence: Int?) -> String {
      if let key = liveKey, let title = titles[key], !title.isEmpty { return title }
      if let occurrence, let list = byBundle[bid], occurrence < list.count { return list[occurrence] }
      return appName(for: bid)
    }
    var chips: [Int: String] = [:]
    for item in fullscreen {
      chips[item.index] = label(item.bundleId, liveKey: item.liveKey, occurrence: item.slot?.occurrence)
    }
    var tileOut: [[BSPSide]: String] = [:]
    for tile in tiles where tile.representative != nil {
      tileOut[tile.path] = label(tile.representative!, liveKey: tile.liveKey, occurrence: tile.slot?.occurrence)
    }
    return (chips, tileOut)
  }
}
