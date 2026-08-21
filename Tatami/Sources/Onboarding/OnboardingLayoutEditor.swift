// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI
import TatamiKit

// MARK: - OnboardingLayoutEditor

struct OnboardingLayoutEditor: View {

  // MARK: Lifecycle

  init(
    tree: BSPNode<SlotID>?,
    apps: [SlotID: MacApp],
    selectedSlot: SlotID?,
    fullscreenSlots: Set<SlotID>,
    windowOrder: [SlotID] = [],
    innerGap: Int,
    outerGap: Int,
    specialMode: LayoutMode?,
    allowsEditing: Bool,
    height: CGFloat = 300,
    pointerLocation: OnboardingDemoPoint? = nil,
    tracksPointerPosition: Bool = false,
    onTileTapped: @escaping (SlotID) -> Void,
    onTileHovered: @escaping (SlotID, OnboardingDemoPoint) -> Void = { _, _ in },
    onTileMoved: @escaping ([BSPSide], [BSPSide], DropZone) -> Void,
    onDividerResized: @escaping ([BSPSide], CGFloat) -> Void,
  ) {
    self.tree = tree
    self.apps = apps
    self.selectedSlot = selectedSlot
    self.fullscreenSlots = fullscreenSlots
    self.windowOrder = windowOrder
    self.innerGap = innerGap
    self.outerGap = outerGap
    self.specialMode = specialMode
    self.allowsEditing = allowsEditing
    self.height = height
    self.pointerLocation = pointerLocation
    self.tracksPointerPosition = tracksPointerPosition
    self.onTileTapped = onTileTapped
    self.onTileHovered = onTileHovered
    self.onTileMoved = onTileMoved
    self.onDividerResized = onDividerResized
  }

  // MARK: Internal

  let tree: BSPNode<SlotID>?
  let apps: [SlotID: MacApp]
  let selectedSlot: SlotID?
  let fullscreenSlots: Set<SlotID>
  let windowOrder: [SlotID]
  let innerGap: Int
  let outerGap: Int
  let specialMode: LayoutMode?
  let allowsEditing: Bool
  let height: CGFloat
  let pointerLocation: OnboardingDemoPoint?
  let tracksPointerPosition: Bool
  let onTileTapped: (SlotID) -> Void
  let onTileHovered: (SlotID, OnboardingDemoPoint) -> Void
  let onTileMoved: ([BSPSide], [BSPSide], DropZone) -> Void
  let onDividerResized: ([BSPSide], CGFloat) -> Void

  var body: some View {
    GeometryReader { geometry in
      let bounds = CGRect(origin: .zero, size: geometry.size)
      let contentBounds = bounds.insetBy(dx: CGFloat(outerGap), dy: CGFloat(outerGap))
      let primarySlot = selectedSlot ?? tree?.windows.first
      let unmanagedBandHeight = specialMode == .unmanaged ? 58.0 : 0
      let tileBounds = CGRect(
        x: contentBounds.minX,
        y: contentBounds.minY,
        width: contentBounds.width,
        height: max(contentBounds.height - unmanagedBandHeight, 1),
      )
      let baseTree = layoutTree(removing: primarySlot)
      let editedTree = pendingRatio.map { pending in
        baseTree?.applying(.setRatio(path: pending.path, ratio: pending.ratio))
      } ?? baseTree
      let activeFullscreenSlots = Set(fullscreenSlots.filter { slot in
        tree?.windows.contains(slot) == true && apps[slot] != nil
      })
      let fullscreenStack = orderedFullscreenStack(
        active: activeFullscreenSlots,
        treeOrder: tree?.windows ?? [],
      )
      let frontmostFullscreenSlot =
        selectedSlot.flatMap { activeFullscreenSlots.contains($0) ? $0 : nil }
          ?? fullscreenStack.last
      let renderedTree = layoutTree(
        editedTree,
        removingFullscreen: activeFullscreenSlots,
      )
      let regions = renderedTree?.leafRegions(in: tileBounds, gap: CGFloat(innerGap)) ?? []
      let dividers = renderedTree?.branchRegions(in: tileBounds, gap: CGFloat(innerGap)) ?? []
      let displayedPointerLocation = tracksPointerPosition
        ? livePointerLocation ?? pointerLocation
        : pointerLocation

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 14)
          .fill(Color(nsColor: .windowBackgroundColor))
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(Color.primary.opacity(0.08))

        ForEach(fullscreenStack, id: \.self) { fullscreenSlot in
          if let app = apps[fullscreenSlot] {
            Button {
              onTileTapped(fullscreenSlot)
            } label: {
              tile(
                app: app,
                slot: fullscreenSlot,
                selected: selectedSlot == fullscreenSlot,
              )
            }
            .buttonStyle(.plain)
            .frame(width: contentBounds.width, height: contentBounds.height)
            .position(x: contentBounds.midX, y: contentBounds.midY)
            .zIndex(fullscreenZIndex(for: fullscreenSlot, in: fullscreenStack))
          }
        }

        ForEach(regions, id: \.path) { region in
          if
            let slot = region.leaf.topWindow,
            let app = apps[slot],
            activeFullscreenSlots.isEmpty || selectedSlot == slot
          {
            tileView(
              app: app,
              slot: slot,
              region: region,
              allRegions: regions,
              allowsDragging: activeFullscreenSlots.isEmpty,
            )
            .zIndex(activeFullscreenSlots.isEmpty ? 0 : 3)
          }
        }

        if allowsEditing, activeFullscreenSlots.isEmpty {
          ForEach(dividers, id: \.path) { divider in
            dividerHandle(divider)
          }
        }

        if let overlay = dropOverlay(regions: regions), activeFullscreenSlots.isEmpty {
          dropOverlayView(target: overlay.target, zone: overlay.zone)
            .allowsHitTesting(false)
        }

        if
          activeFullscreenSlots.isEmpty,
          let drag = tileDrag,
          let source = regions.first(where: { $0.path == drag.source }),
          let slot = source.leaf.topWindow,
          let app = apps[slot]
        {
          dragGhost(app: app, at: drag.location)
        }

        if
          specialMode == .floating,
          let primarySlot,
          let app = apps[primarySlot],
          activeFullscreenSlots.isEmpty || !activeFullscreenSlots.contains(primarySlot)
        {
          floatingCard(app: app, in: contentBounds)
            .contentShape(.rect)
            .onTapGesture { onTileTapped(primarySlot) }
            .zIndex(activeFullscreenSlots.isEmpty ? 0 : 3)
        }

        if
          specialMode == .unmanaged,
          let primarySlot,
          let app = apps[primarySlot],
          activeFullscreenSlots.isEmpty || !activeFullscreenSlots.contains(primarySlot)
        {
          unmanagedBand(app: app, in: contentBounds, height: unmanagedBandHeight)
            .contentShape(.rect)
            .onTapGesture { onTileTapped(primarySlot) }
            .zIndex(activeFullscreenSlots.isEmpty ? 0 : 3)
        }

        if let displayedPointerLocation {
          Image(systemName: "cursorarrow")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
            .position(
              x: bounds.minX + CGFloat(displayedPointerLocation.x) * bounds.width,
              y: bounds.minY + CGFloat(displayedPointerLocation.y) * bounds.height,
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(4)
        }
      }
      .compositingGroup()
      .clipShape(.rect(cornerRadius: 14))
      .coordinateSpace(.named(coordinateSpace))
      .onContinuousHover(coordinateSpace: .named(coordinateSpace)) { phase in
        switch phase {
        case .active(let location):
          let normalizedLocation = OnboardingDemoPoint(
            x: location.x / max(bounds.width, 1),
            y: location.y / max(bounds.height, 1),
          )
          if tracksPointerPosition, livePointerLocation != normalizedLocation {
            livePointerLocation = normalizedLocation
          }
          let slot = slot(
            at: location,
            contentBounds: contentBounds,
            regions: regions,
            primarySlot: primarySlot,
            fullscreenSlot: frontmostFullscreenSlot,
            unmanagedBandHeight: unmanagedBandHeight,
          )
          guard slot != lastHoveredSlot else { return }
          lastHoveredSlot = slot
          guard let slot else { return }
          onTileHovered(slot, normalizedLocation)

        case .ended:
          lastHoveredSlot = nil
        }
      }
    }
    .frame(height: height)
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: tree)
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: fullscreenSlots)
    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: specialMode)
    .onChange(of: pointerLocation) { _, newValue in
      guard tracksPointerPosition, livePointerLocation != newValue else { return }
      livePointerLocation = newValue
    }
  }

  // MARK: Private

  @State private var pendingRatio: (path: [BSPSide], ratio: CGFloat)?
  @State private var tileDrag: (source: [BSPSide], location: CGPoint)?
  @State private var lastHoveredSlot: SlotID?
  @State private var livePointerLocation: OnboardingDemoPoint?

  private let coordinateSpace = "onboarding-layout-canvas"

  private func layoutTree(removing primarySlot: SlotID?) -> BSPNode<SlotID>? {
    guard let tree else { return nil }
    guard
      let specialMode,
      specialMode != .tiled,
      let primarySlot
    else { return tree }
    return tree.removing(primarySlot)
  }

  private func layoutTree(
    _ tree: BSPNode<SlotID>?,
    removingFullscreen fullscreenSlots: Set<SlotID>,
  ) -> BSPNode<SlotID>? {
    guard !fullscreenSlots.isEmpty else { return tree }
    return tree?.removingAll(fullscreenSlots)
  }

  private func orderedFullscreenStack(
    active fullscreenSlots: Set<SlotID>,
    treeOrder: [SlotID],
  ) -> [SlotID] {
    var result = treeOrder.filter(fullscreenSlots.contains)
    for slot in windowOrder.reversed() where fullscreenSlots.contains(slot) {
      result.removeAll { $0 == slot }
      result.append(slot)
    }
    return result
  }

  private func fullscreenZIndex(
    for slot: SlotID,
    in stack: [SlotID],
  ) -> Double {
    if selectedSlot == slot { return 3 }
    guard let index = stack.firstIndex(of: slot), !stack.isEmpty else { return 1 }
    return 1 + Double(index) / Double(stack.count)
  }

  private func tileView(
    app: MacApp,
    slot: SlotID,
    region: BSPNode<SlotID>.LeafRegion,
    allRegions: [BSPNode<SlotID>.LeafRegion],
    allowsDragging: Bool,
  ) -> some View {
    let isDragging = tileDrag?.source == region.path
    return Button {
      onTileTapped(slot)
    } label: {
      tile(app: app, slot: slot, selected: selectedSlot == slot)
    }
    .buttonStyle(.plain)
    .frame(width: region.rect.width, height: region.rect.height)
    .position(x: region.rect.midX, y: region.rect.midY)
    .opacity(isDragging ? 0.28 : 1)
    .simultaneousGesture(
      tileDragGesture(
        region: region,
        allRegions: allRegions,
        allowsDragging: allowsDragging,
      )
    )
  }

  private func slot(
    at location: CGPoint,
    contentBounds: CGRect,
    regions: [BSPNode<SlotID>.LeafRegion],
    primarySlot: SlotID?,
    fullscreenSlot: SlotID?,
    unmanagedBandHeight: CGFloat,
  ) -> SlotID? {
    if
      let fullscreenSlot,
      selectedSlot != fullscreenSlot,
      let selectedRegion = regions.first(where: { $0.leaf.topWindow == selectedSlot }),
      selectedRegion.rect.contains(location)
    {
      return selectedSlot
    }
    if specialMode == .floating, let primarySlot {
      let width = contentBounds.width * 0.34
      let height = contentBounds.height * 0.42
      let center = CGPoint(
        x: contentBounds.maxX - contentBounds.width * 0.19,
        y: contentBounds.minY + contentBounds.height * 0.25,
      )
      let frame = CGRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height,
      )
      if frame.contains(location) { return primarySlot }
    }
    if
      specialMode == .unmanaged,
      let primarySlot,
      CGRect(
        x: contentBounds.minX,
        y: contentBounds.maxY - unmanagedBandHeight,
        width: contentBounds.width,
        height: unmanagedBandHeight,
      ).contains(location)
    {
      return primarySlot
    }
    if let fullscreenSlot, contentBounds.contains(location) {
      return fullscreenSlot
    }
    return regions.first(where: { $0.rect.contains(location) })?.leaf.topWindow
  }

  private func tile(app: MacApp, slot: SlotID, selected: Bool) -> some View {
    VStack(spacing: 7) {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 36, height: 36)
      Text(app.name)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
      if slot.occurrence > 0 {
        Text("Window \(slot.occurrence + 1)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: .rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          selected ? Color.accentColor : Color.primary.opacity(0.12),
          lineWidth: selected ? 2.5 : 1,
        )
    }
  }

  private func tileDragGesture(
    region: BSPNode<SlotID>.LeafRegion,
    allRegions: [BSPNode<SlotID>.LeafRegion],
    allowsDragging: Bool,
  ) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in
        guard allowsEditing, allowsDragging else { return }
        if tileDrag == nil { NSCursor.closedHand.set() }
        tileDrag = (region.path, value.location)
      }
      .onEnded { value in
        guard allowsEditing, allowsDragging else { return }
        defer {
          tileDrag = nil
          NSCursor.arrow.set()
        }
        guard
          let drop = dropTarget(
            regions: allRegions,
            source: region.path,
            point: value.location,
          )
        else { return }
        onTileMoved(region.path, drop.path, drop.zone)
      }
  }

  private func dividerHandle(_ divider: BSPNode<SlotID>.BranchRegion) -> some View {
    let vertical = divider.axis == .vertical
    let x = vertical
      ? divider.rect.minX + divider.ratio * divider.rect.width
      : divider.rect.midX
    let y = vertical
      ? divider.rect.midY
      : divider.rect.minY + divider.ratio * divider.rect.height
    let active = pendingRatio?.path == divider.path
    return Rectangle()
      .fill(.clear)
      .contentShape(.rect)
      .frame(
        width: vertical ? 12 : divider.rect.width,
        height: vertical ? divider.rect.height : 12,
      )
      .overlay {
        Capsule()
          .fill(Color.secondary.opacity(active ? 0.72 : 0.34))
          .frame(
            width: vertical ? 3 : max(18, divider.rect.width * 0.2),
            height: vertical ? max(18, divider.rect.height * 0.2) : 3,
          )
      }
      .position(x: x, y: y)
      .gesture(dividerDragGesture(divider))
      .onHover { hovering in
        if hovering {
          (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else {
          NSCursor.arrow.set()
        }
      }
  }

  private func dividerDragGesture(_ divider: BSPNode<SlotID>.BranchRegion) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
      .onChanged { value in
        let raw = divider.axis == .vertical
          ? (value.location.x - divider.rect.minX) / max(divider.rect.width, 1)
          : (value.location.y - divider.rect.minY) / max(divider.rect.height, 1)
        pendingRatio = (divider.path, min(0.9, max(0.1, raw)))
      }
      .onEnded { _ in
        if let pendingRatio {
          onDividerResized(pendingRatio.path, pendingRatio.ratio)
        }
        pendingRatio = nil
      }
  }

  private func dropTarget(
    regions: [BSPNode<SlotID>.LeafRegion],
    source: [BSPSide],
    point: CGPoint,
  ) -> (path: [BSPSide], zone: DropZone)? {
    guard
      let target = regions.first(where: { $0.path != source && $0.rect.contains(point) }),
      let zone = DropZone.quadrant(point: point, in: target.rect)
    else { return nil }
    return (target.path, zone)
  }

  private func dropOverlay(
    regions: [BSPNode<SlotID>.LeafRegion]
  ) -> (target: CGRect, zone: DropZone)? {
    guard
      let tileDrag,
      let drop = dropTarget(regions: regions, source: tileDrag.source, point: tileDrag.location),
      let target = regions.first(where: { $0.path == drop.path })
    else { return nil }
    return (target.rect, drop.zone)
  }

  private func dropOverlayView(target: CGRect, zone: DropZone) -> some View {
    let highlighted = zoneRect(in: target, zone: zone)
    return ZStack {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .frame(width: target.width, height: target.height)
        .position(x: target.midX, y: target.midY)
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.accentColor.opacity(0.3))
        .frame(width: highlighted.width, height: highlighted.height)
        .position(x: highlighted.midX, y: highlighted.midY)
    }
  }

  private func zoneRect(in rect: CGRect, zone: DropZone) -> CGRect {
    switch zone {
    case .swap: rect
    case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
  }

  private func dragGhost(app: MacApp, at point: CGPoint) -> some View {
    HStack(spacing: 7) {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 20, height: 20)
      Text(app.name)
        .font(.caption)
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(.regularMaterial, in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.accentColor, lineWidth: 1.5)
    }
    .shadow(radius: 5, y: 2)
    .fixedSize()
    .position(x: point.x, y: point.y - 8)
    .allowsHitTesting(false)
  }

  private func floatingCard(app: MacApp, in bounds: CGRect) -> some View {
    VStack(spacing: 8) {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 34, height: 34)
      Text(app.name)
        .font(.callout.weight(.medium))
      Label("Floating", systemImage: "rectangle.on.rectangle")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .frame(width: bounds.width * 0.34, height: bounds.height * 0.42)
    .background(.regularMaterial, in: .rect(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.accentColor, lineWidth: 2)
    }
    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    .position(
      x: bounds.maxX - bounds.width * 0.19,
      y: bounds.minY + bounds.height * 0.25,
    )
  }

  private func unmanagedBand(app: MacApp, in bounds: CGRect, height: CGFloat) -> some View {
    HStack(spacing: 9) {
      AppIcon(bundleIdentifier: app.bundleIdentifier, iconPath: app.iconPath)
        .frame(width: 24, height: 24)
      Text(app.name)
        .font(.callout.weight(.medium))
      Spacer()
      Label("Left untouched", systemImage: "nosign")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .frame(width: bounds.width, height: max(height - 8, 1))
    .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          Color.secondary.opacity(0.28),
          style: StrokeStyle(lineWidth: 1, dash: [5, 4]),
        )
    }
    .position(x: bounds.midX, y: bounds.maxY - height / 2)
  }

}
