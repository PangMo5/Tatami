import CoreGraphics
import SwiftUI
import TatamiKit

// MARK: - Resolved layout (payload-agnostic rendering source)

/// The layout to preview for one workspace: the *live* window tree when the
/// workspace is active, or a bundle-id *template* (persisted snapshot, else
/// synthesized from the tiled apps) otherwise. Fullscreen-zoomed windows are
/// trimmed out of the tile layout — exactly as `computeFrames` does — and shown
/// in a separate fullscreen band, so the remaining tiles reshape and stay
/// editable. Because trimming changes the tree shape, edit ops computed against
/// the trimmed layout are mapped back to *full-tree* paths before they're sent.
enum ResolvedLayout: Equatable {
  case live(BSPNode<WindowKey>, zoomed: Set<WindowKey>)
  /// Bundle-id template. `zoomedBundleIds` is a *list* (not a set): a workspace
  /// can hold several windows of the same app, and each fullscreen entry is one
  /// window — matching `LayoutSnapshot.fullscreenZoomedBundleIds`.
  case template(BSPNode<String>, zoomedBundleIds: [String])

  static func resolve(
    workspace: Workspace,
    sharedApps: [SharedApp],
    isActive: Bool,
    liveTree: BSPNode<WindowKey>?,
    liveZoomed: Set<WindowKey>,
    snapshot: LayoutSnapshot?,
    autoBalance: AutoBalanceMode
  ) -> ResolvedLayout? {
    // Only the *currently active* workspace has an authoritative live tree.
    // A workspace that was active earlier keeps a stale tree in `tilingTrees`,
    // but editing it would route to the wrong (active) workspace — so treat
    // any non-active workspace as a saved template.
    if isActive, let liveTree, !liveTree.windows.isEmpty {
      return .live(liveTree, zoomed: liveZoomed)
    }
    let tiled = tiledLayoutBundleIds(workspace: workspace, sharedApps: sharedApps)
    guard var template = snapshot?.tree ?? BSPNode<String>.synthesizedTemplate(tiledBundleIds: tiled),
          !template.windows.isEmpty
    else { return nil }
    // Activation applies auto-balance to the tree it builds (and to a restored
    // snapshot) — mirror it so the inactive preview matches. Balancing only
    // re-weights ratios, so edit-op paths are unaffected.
    if autoBalance != .none { template = template.balanced(axis: autoBalance) }
    return .template(template, zoomedBundleIds: snapshot?.fullscreenZoomedBundleIds ?? [])
  }

  var isLive: Bool { if case .live = self { return true } else { return false } }

  var hasFullscreen: Bool {
    switch self {
    case .live(let t, let z): return z.contains { t.pathTo(window: $0) != nil }
    case .template(let t, let z): let w = Set(t.windows); return z.contains { w.contains($0) }
    }
  }

  func applyingLocal(_ op: LayoutEditOp?) -> ResolvedLayout {
    guard let op else { return self }
    switch self {
    case .live(let t, let z): return .live(t.applying(op), zoomed: z)
    case .template(let t, let z): return .template(t.applying(op), zoomedBundleIds: z)
    }
  }

  /// Tiles + dividers for the *non-zoomed* windows, laid out in `rect` after
  /// trimming the fullscreen-zoomed ones (so the rest reshapes to fill).
  func renderRegions(in rect: CGRect, hidden: Set<String>) -> (tiles: [RenderLeaf], dividers: [RenderDivider]) {
    switch self {
    case .live(let tree, let zoomed):
      guard let trimmed = Self.trim(tree, removing: zoomed) else { return ([], []) }
      let tiles = trimmed.leafRegions(in: rect, gap: 0).map { r in
        RenderLeaf(path: r.path, rect: r.rect, bundleIds: r.leaf.windowList.map(\.bundleId),
                   liveKey: r.leaf.windowList.first)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    case .template(let tree, let zoomedBundleIds):
      guard let trimmed = Self.trimTemplate(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden)
      else { return ([], []) }
      let tiles = trimmed.leafRegions(in: rect, gap: 0).map { r in
        RenderLeaf(path: r.path, rect: r.rect, bundleIds: r.leaf.windowList, liveKey: nil)
      }
      let dividers = trimmed.branchRegions(in: rect, gap: 0).map {
        RenderDivider(path: $0.path, rect: $0.rect, axis: $0.axis, ratio: $0.ratio)
      }
      return (tiles, dividers)
    }
  }

  func fullscreenItems() -> [(bundleId: String, liveKey: WindowKey?)] {
    switch self {
    case .live(let tree, let zoomed):
      return zoomed
        .filter { tree.pathTo(window: $0) != nil }
        .sorted { $0.windowID < $1.windowID }
        .map { (bundleId: $0.bundleId, liveKey: $0) }
    case .template(let tree, let zoomedBundleIds):
      let present = Set(tree.windows)
      return zoomedBundleIds.filter { present.contains($0) }.sorted().map { (bundleId: $0, liveKey: nil) }
    }
  }

  // MARK: Trimmed → full-tree path mapping

  func fullLeafPath(trimmedLeafPath: [BSPSide], hidden: Set<String>) -> [BSPSide]? {
    switch self {
    case .live(let tree, let zoomed):
      guard let trimmed = Self.trim(tree, removing: zoomed),
            case .leaf(let leaf) = trimmed.subtree(at: trimmedLeafPath),
            let rep = leaf.windowList.first
      else { return nil }
      return tree.pathTo(window: rep)
    case .template(let tree, let zoomedBundleIds):
      guard let trimmed = Self.trimTemplate(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden),
            case .leaf(let leaf) = trimmed.subtree(at: trimmedLeafPath),
            let rep = leaf.windowList.first
      else { return nil }
      return tree.pathTo(window: rep)
    }
  }

  func fullBranchPath(trimmedBranchPath: [BSPSide], hidden: Set<String>) -> [BSPSide]? {
    switch self {
    case .live(let tree, let zoomed):
      guard let trimmed = Self.trim(tree, removing: zoomed),
            case .branch(let b) = trimmed.subtree(at: trimmedBranchPath),
            let l = b.left.windows.first, let r = b.right.windows.first,
            let lp = tree.pathTo(window: l), let rp = tree.pathTo(window: r)
      else { return nil }
      return Self.commonPrefix(lp, rp)
    case .template(let tree, let zoomedBundleIds):
      guard let trimmed = Self.trimTemplate(tree, zoomedBundleIds: zoomedBundleIds, hidden: hidden),
            case .branch(let b) = trimmed.subtree(at: trimmedBranchPath),
            let l = b.left.windows.first, let r = b.right.windows.first,
            let lp = tree.pathTo(window: l), let rp = tree.pathTo(window: r)
      else { return nil }
      return Self.commonPrefix(lp, rp)
    }
  }

  private static func trim(_ tree: BSPNode<WindowKey>, removing zoomed: Set<WindowKey>) -> BSPNode<WindowKey>? {
    var trimmed: BSPNode<WindowKey>? = tree
    for key in zoomed where tree.pathTo(window: key) != nil { trimmed = trimmed?.removing(key) }
    return trimmed
  }

  /// Trim the template for rendering: drop every window of a `hidden` app (a
  /// shared app with no live window — it wouldn't tile on switch), and drop the
  /// fullscreen-zoomed windows by count per bundle id (so a workspace with
  /// several windows of one app trims only as many as are zoomed). Tokenizes to
  /// distinguish same-bundle-id leaves, then maps back to bundle ids.
  private static func trimTemplate(
    _ tree: BSPNode<String>,
    zoomedBundleIds: [String],
    hidden: Set<String>
  ) -> BSPNode<String>? {
    guard !zoomedBundleIds.isEmpty || !hidden.isEmpty else { return tree }
    var counts: [String: Int] = [:]
    for bid in zoomedBundleIds { counts[bid, default: 0] += 1 }
    let (tokenized, back) = tree.tokenized()
    var remove: Set<Int> = []
    for token in tokenized.windows where hidden.contains(back[token]!) { remove.insert(token) }
    for (bid, count) in counts {
      let matching = tokenized.windows.filter { back[$0] == bid }
      remove.formUnion(matching.prefix(count))
    }
    guard !remove.isEmpty else { return tree }
    var trimmed: BSPNode<Int>? = tokenized
    for token in remove { trimmed = trimmed?.removing(token) }
    return trimmed?.mapWindows { back[$0]! }
  }

  private static func commonPrefix(_ a: [BSPSide], _ b: [BSPSide]) -> [BSPSide] {
    var result: [BSPSide] = []
    for (x, y) in zip(a, b) {
      if x == y { result.append(x) } else { break }
    }
    return result
  }
}

/// One preview tile (a BSP leaf), positioned in canvas coordinates.
struct RenderLeaf: Identifiable {
  var path: [BSPSide]
  var rect: CGRect
  var bundleIds: [String]
  var liveKey: WindowKey?
  var id: [BSPSide] { path }
  var representative: String? { bundleIds.first }
  var stackCount: Int { bundleIds.count }
}

/// One split divider (a BSP branch), positioned in canvas coordinates.
struct RenderDivider: Identifiable {
  var path: [BSPSide]
  var rect: CGRect
  var axis: BSPSplitAxis
  var ratio: CGFloat
  var id: [BSPSide] { path }
}

private struct FullscreenItem: Identifiable, Equatable {
  var index: Int
  var bundleId: String
  var liveKey: WindowKey?
  var id: Int { index }
}

private struct SelectedTile: Equatable {
  var path: [BSPSide]
  var bundleId: String
  var liveKey: WindowKey?
}

/// A workspace member that isn't tiled — floating (mirrored above the tiles) or
/// ignored (left alone). Shown in a band, not the BSP canvas.
private struct NonTiledApp: Identifiable {
  var bundleId: String
  var name: String
  var iconPath: String?
  var mode: LayoutMode
  var isShared: Bool
  var id: String { bundleId }
}

/// In-progress divider resize: the trimmed path (for the active-handle
/// highlight) plus the mapped full-tree path (what's actually edited).
private struct PendingRatio: Equatable {
  var trimmedPath: [BSPSide]
  var fullPath: [BSPSide]
  var ratio: CGFloat
}

// MARK: - Preview view

/// Graphical layout preview + editor at the top of a workspace's detail. Tiles
/// are drawn proportionally; drag a split divider to resize, drag a tile onto
/// another to move it (5-zone drop like the live window drag) or onto the
/// fullscreen band to fullscreen it, drag a fullscreen chip back onto the tiles
/// to restore it, tap a tile to select it, and use the toolbar to rotate / flip
/// / balance / toggle a split / fullscreen. A scratchpad shows the screen with
/// the scratchpad docked at its borrow edge + width, the rest dimmed as host.
struct WorkspaceLayoutPreview: View {
  let workspace: Workspace
  let resolved: ResolvedLayout?
  let settings: AppSettings
  let sharedApps: [SharedApp]
  let windowTitles: [WindowKey: String]
  /// Bundle ids with a currently-discoverable window — a shared app not here is
  /// hidden and is omitted from the preview (it wouldn't tile on switch).
  let presentBundleIds: Set<String>
  /// The workspace's async preview data (snapshot + window info) has loaded;
  /// until then a loading indicator is shown instead of a partial render.
  let previewReady: Bool
  let onEdit: (LayoutEditOp) -> Void
  /// Fullscreen-zoom (`zoomIn: true`) or restore (`false`) a window. `liveKey`
  /// is present only for the active workspace (per-window toggle); otherwise
  /// the inactive path toggles by bundle-id count.
  let onToggleFullscreen: (_ bundleId: String, _ liveKey: WindowKey?, _ zoomIn: Bool) -> Void

  @State private var pendingRatio: PendingRatio?
  @State private var tileDrag: (source: [BSPSide], location: CGPoint)?
  @State private var chipDrag: (item: FullscreenItem, location: CGPoint)?
  @State private var selectedTile: SelectedTile?

  private let coordinateSpace = "layoutCanvas"
  private let canvasAspect: CGFloat = 16.0 / 10.0
  private let maxTileAreaHeight: CGFloat = 240
  private let bandHeight: CGFloat = 56
  private let bandGap: CGFloat = 8

  private var current: ResolvedLayout? { resolved }

  private var hasFullscreen: Bool { current?.hasFullscreen ?? false }

  /// Shared tiled apps with no live window — hidden, so omitted from the
  /// rendered tiles (kept in the template so editing paths still resolve).
  private var hiddenSharedBundleIds: Set<String> {
    Set(sharedApps.filter { $0.layout == .tiled }.map(\.bundleIdentifier))
      .subtracting(presentBundleIds)
  }
  /// Vertical offset of the tile area — below the fullscreen band when present.
  private var tileAreaTop: CGFloat { hasFullscreen ? bandHeight + bandGap : 0 }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Show the indicator until this workspace's preview data has actually
      // loaded (snapshot + window info) — one settled render instead of
      // flickering through the load burst. No timer.
      if !previewReady {
        loadingPlaceholder
      } else if current == nil {
        emptyState
      } else {
        toolbar
        canvas
        if !nonTiledApps.isEmpty { nonTiledBand }
        footnote
      }
    }
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

  private var nonTiledApps: [NonTiledApp] {
    var out: [NonTiledApp] = []
    for app in workspace.apps where app.layout != .tiled {
      out.append(NonTiledApp(bundleId: app.bundleIdentifier, name: app.name,
                             iconPath: app.iconPath, mode: app.layout, isShared: false))
    }
    // A scratchpad borrows only its own apps; shared apps belong to the host.
    if workspace.kind != .scratchpad {
      for app in sharedApps where app.layout != .tiled {
        out.append(NonTiledApp(bundleId: app.bundleIdentifier, name: app.name,
                               iconPath: app.iconPath, mode: app.layout, isShared: true))
      }
    }
    return out
  }

  private var nonTiledBand: some View {
    VStack(alignment: .leading, spacing: 3) {
      Label("Not tiled", systemImage: "rectangle.dashed")
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(nonTiledApps) { app in nonTiledChip(app) }
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
    .help(nonTiledHelp(app))
  }

  private func nonTiledHelp(_ app: NonTiledApp) -> String {
    let mode = app.mode == .floating ? "Floating — kept above the tiles" : "Ignored — left where it is"
    return app.isShared ? "\(mode) · Shared (in every workspace)" : mode
  }

  private func isShared(_ bundleId: String) -> Bool {
    sharedApps.contains { $0.bundleIdentifier == bundleId }
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
      toolButton("rotate.right", help: "Rotate 90°") { edit(.rotate(degrees: 90)) }
      toolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip left ↔ right") {
        edit(.mirror(axis: .vertical))
      }
      toolButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip top ↔ bottom") {
        edit(.mirror(axis: .horizontal))
      }
      toolButton("square.grid.2x2", help: "Balance — equalize splits") { edit(.balance) }

      Divider().frame(height: 16)

      toolButton(
        "rectangle.split.2x1",
        help: "Toggle split orientation of the selected tile",
        enabled: selectedTile != nil
      ) {
        if let sel = selectedTile,
           let full = current?.fullLeafPath(trimmedLeafPath: sel.path, hidden: hiddenSharedBundleIds) {
          edit(.toggleOrientation(leafPath: full))
        }
      }
      toolButton(
        "arrow.up.left.and.arrow.down.right",
        help: "Fullscreen the selected tile",
        enabled: selectedTile != nil
      ) {
        if let sel = selectedTile {
          onToggleFullscreen(sel.bundleId, sel.liveKey, true)
          selectedTile = nil
        }
      }
    }
  }

  private func toolButton(
    _ symbol: String,
    help: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help(help)
  }

  private func edit(_ op: LayoutEditOp) {
    onEdit(op)
    selectedTile = nil
  }

  // MARK: Canvas (fullscreen band + tile area share one coordinate space)

  private var canvas: some View {
    GeometryReader { geo in
      let fullscreen = fullscreenList
      let bandRect = CGRect(x: 0, y: 0, width: geo.size.width, height: hasFullscreen ? bandHeight : 0)
      let tileArea = CGSize(width: geo.size.width, height: geo.size.height - tileAreaTop)
      let canvasRect = fittedCanvas(in: tileArea).offsetBy(dx: 0, dy: tileAreaTop)
      let dock = dockRect(in: canvasRect)
      let effective = current?.applyingLocal(pendingRatio.map { .setRatio(path: $0.fullPath, ratio: $0.ratio) })
      let regions = effective?.renderRegions(in: dock, hidden: hiddenSharedBundleIds) ?? (tiles: [], dividers: [])
      let labels = tileLabels(regions.tiles)

      ZStack(alignment: .topLeading) {
        if hasFullscreen {
          fullscreenBand(fullscreen, in: bandRect)
        }

        RoundedRectangle(cornerRadius: 8)
          .fill(Color.secondary.opacity(chipDrag != nil ? 0.18 : 0.10))
          .frame(width: canvasRect.width, height: canvasRect.height)
          .position(x: canvasRect.midX, y: canvasRect.midY)
          .onTapGesture { selectedTile = nil }

        if workspace.kind == .scratchpad {
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
          tileView(leaf, allLeaves: regions.tiles, label: labels[leaf.path] ?? "")
        }
        ForEach(regions.dividers) { divider in
          dividerHandle(divider)
        }
        if let overlay = dropOverlay(leaves: regions.tiles) {
          overlay.allowsHitTesting(false)
        }
        if let drag = tileDrag, let source = regions.tiles.first(where: { $0.path == drag.source }) {
          dragGhost(bundleId: source.representative ?? "", label: labels[drag.source] ?? "", at: drag.location)
        }
        if let chip = chipDrag {
          dragGhost(
            bundleId: chip.item.bundleId,
            label: chipLabel(bundleId: chip.item.bundleId, liveKey: chip.item.liveKey),
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
    (current?.fullscreenItems() ?? []).enumerated().map { idx, item in
      FullscreenItem(index: idx, bundleId: item.bundleId, liveKey: item.liveKey)
    }
  }

  private var footnote: some View {
    HStack(spacing: 6) {
      Image(systemName: (current?.isLive == true) ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
        .font(.caption2)
      Text((current?.isLive == true)
        ? "Live — edits re-tile your windows now."
        : "Saved layout — edits apply on next activation.")
        .font(.caption)
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

  private func fullscreenBand(_ items: [FullscreenItem], in rect: CGRect) -> some View {
    // Highlight when a tile is being dragged toward the band (drop = fullscreen).
    let armed = tileDrag != nil
    return VStack(alignment: .leading, spacing: 3) {
      Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
        .font(.caption2.bold())
        .foregroundStyle(.secondary)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(items) { item in
            fullscreenChip(item)
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

  private func fullscreenChip(_ item: FullscreenItem) -> some View {
    let dragging = chipDrag?.item == item
    return HStack(spacing: 6) {
      AppIcon(bundleIdentifier: item.bundleId, iconPath: iconPath(for: item.bundleId))
        .frame(width: 18, height: 18)
      Text(chipLabel(bundleId: item.bundleId, liveKey: item.liveKey))
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
    .onTapGesture { onToggleFullscreen(item.bundleId, item.liveKey, false) }
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
          onToggleFullscreen(item.bundleId, item.liveKey, false)
        }
      }
  }

  // MARK: Tile

  private func tileView(_ leaf: RenderLeaf, allLeaves: [RenderLeaf], label: String) -> some View {
    let isDragging = tileDrag?.source == leaf.path
    let isSelected = selectedTile?.path == leaf.path
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
      if isSelected {
        selectedTile = nil
      } else if let bid = leaf.representative {
        selectedTile = SelectedTile(path: leaf.path, bundleId: bid, liveKey: leaf.liveKey)
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
        // Dropped on the fullscreen band → fullscreen this window. (The band is
        // only present once a window is zoomed or via the toolbar button; the
        // top strip can't collide with tiles because they start below it.)
        if hasFullscreen, value.location.y < bandHeight, let bid = leaf.representative {
          onToggleFullscreen(bid, leaf.liveKey, true)
          return
        }
        guard let drop = dropTarget(leaves: allLeaves, source: leaf.path, at: value.location),
              let sourceFull = current?.fullLeafPath(trimmedLeafPath: leaf.path, hidden: hiddenSharedBundleIds),
              let targetFull = current?.fullLeafPath(trimmedLeafPath: drop.path, hidden: hiddenSharedBundleIds)
        else { return }
        edit(.relocate(source: sourceFull, target: targetFull, zone: drop.zone))
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
        let ratio = min(0.9, max(0.1, raw))
        if let pending = pendingRatio, pending.trimmedPath == divider.path {
          pendingRatio = PendingRatio(trimmedPath: pending.trimmedPath, fullPath: pending.fullPath, ratio: ratio)
        } else if let full = current?.fullBranchPath(trimmedBranchPath: divider.path, hidden: hiddenSharedBundleIds) {
          pendingRatio = PendingRatio(trimmedPath: divider.path, fullPath: full, ratio: ratio)
        }
      }
      .onEnded { _ in
        if let pending = pendingRatio {
          onEdit(.setRatio(path: pending.fullPath, ratio: pending.ratio))
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

  private func dropOverlay(leaves: [RenderLeaf]) -> AnyView? {
    guard let drag = tileDrag,
          let drop = dropTarget(leaves: leaves, source: drag.source, at: drag.location),
          let target = leaves.first(where: { $0.path == drop.path })
    else { return nil }
    let zoneRect = zoneRect(in: target.rect, zone: drop.zone)
    return AnyView(
      ZStack {
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(Color.accentColor, lineWidth: 2)
          .frame(width: target.rect.width, height: target.rect.height)
          .position(x: target.rect.midX, y: target.rect.midY)
        RoundedRectangle(cornerRadius: 4)
          .fill(Color.accentColor.opacity(0.35))
          .frame(width: zoneRect.width, height: zoneRect.height)
          .position(x: zoneRect.midX, y: zoneRect.midY)
      }
    )
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
    workspace.borrowEdge ?? settings.switching.borrowDefaultEdge ?? .right
  }

  private var resolvedFraction: CGFloat {
    CGFloat(workspace.borrowFraction ?? settings.switching.borrowFraction)
  }

  private func dockRect(in canvas: CGRect) -> CGRect {
    guard workspace.kind == .scratchpad else { return canvas }
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

  // MARK: App metadata lookup

  private func iconPath(for bundleId: String) -> String? {
    workspace.apps.first { $0.bundleIdentifier == bundleId }?.iconPath
      ?? sharedApps.first { $0.bundleIdentifier == bundleId }?.iconPath
  }

  private func appName(for bundleId: String) -> String {
    workspace.apps.first { $0.bundleIdentifier == bundleId }?.name
      ?? sharedApps.first { $0.bundleIdentifier == bundleId }?.name
      ?? bundleId
  }

  /// Live window titles grouped by bundle id (sorted by window id) so several
  /// windows of one app can be distinguished — even for an inactive workspace,
  /// since the fetch discovers windows by bundle id regardless of activation.
  private var titlesByBundle: [String: [String]] {
    var grouped: [String: [(CGWindowID, String)]] = [:]
    for (key, title) in windowTitles {
      grouped[key.bundleId, default: []].append((key.windowID, title))
    }
    return grouped.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
  }

  /// Per-tile display labels. A live tile uses its exact window's title; an
  /// inactive tile (bundle-id template) takes the nth title of that app, by
  /// occurrence order, so repeated same-app tiles read distinctly.
  private func tileLabels(_ tiles: [RenderLeaf]) -> [[BSPSide]: String] {
    let byBundle = titlesByBundle
    var counts: [String: Int] = [:]
    var out: [[BSPSide]: String] = [:]
    for tile in tiles {
      guard let bid = tile.representative else { continue }
      if let key = tile.liveKey, let title = windowTitles[key], !title.isEmpty {
        out[tile.path] = title
        continue
      }
      let occurrence = counts[bid, default: 0]
      counts[bid] = occurrence + 1
      if let titles = byBundle[bid], occurrence < titles.count {
        out[tile.path] = titles[occurrence]
      } else {
        out[tile.path] = appName(for: bid)
      }
    }
    return out
  }

  private func chipLabel(bundleId: String, liveKey: WindowKey?) -> String {
    if let key = liveKey, let title = windowTitles[key], !title.isEmpty { return title }
    return titlesByBundle[bundleId]?.first ?? appName(for: bundleId)
  }
}
