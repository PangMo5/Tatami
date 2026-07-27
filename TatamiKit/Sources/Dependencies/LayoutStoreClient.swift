import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import YYJSON

/// Persists per-workspace BSP layout snapshots so every workspace keeps its
/// split axes + ratios across app restarts. Snapshots are keyed by workspace
/// UUID and store a
/// `BSPNode<String>` (bundle-id leaves) — `WindowKey`s are process-
/// scoped and meaningless after a restart, so we serialize the shape
/// and re-hydrate it against live windows on the next activation.
@DependencyClient
struct LayoutStoreClient: Sendable {
  var save: @Sendable (UUID, LayoutSnapshot) async -> Void
  var load: @Sendable (UUID) async -> LayoutSnapshot?
  var clear: @Sendable (UUID) async -> Void
}

/// On-disk shape of one workspace's tiling memory. Stores the BSP layout keyed
/// by `SlotID` (bundle id + windowID-rank occurrence) so two windows of one app
/// keep distinct, arrangeable positions, plus which slots were fullscreen-zoomed
/// at save time. Parent-zoom (per-leaf, single-tile) is carried by the leaf
/// itself inside `tree`.
public struct LayoutSnapshot: Codable, Hashable, Sendable {
  /// Schema version. Absent/1 on disk = the legacy bundle-id shape
  /// (`BSPNode<String>` + `fullscreenZoomedBundleIds`), migrated on read.
  public var version: Int
  public var tree: BSPNode<SlotID>
  /// Slots that were *fullscreen*-zoomed at save time. Tatami-specific
  /// multi-window fullscreen: each renders at the workspace work area and is
  /// excluded from the rest of the tree's layout. SlotID-keyed (not a bundle-id
  /// count list) so which window of an app is zoomed is unambiguous.
  public var fullscreenZoomedSlots: [SlotID]

  public static let currentVersion = 2

  public init(tree: BSPNode<SlotID>, fullscreenZoomedSlots: [SlotID] = []) {
    self.version = Self.currentVersion
    self.tree = tree
    self.fullscreenZoomedSlots = fullscreenZoomedSlots
  }

  /// Migrate a legacy v1 snapshot (bundle-id tree + bundle-id zoom list) to v2.
  /// Occurrence is assigned by per-bundle appearance order in tree traversal,
  /// via `tokenized()` so a stacked leaf's list/order stay paired; zoom entries
  /// map to the Nth occurrence of their bundle by the same order.
  static func migratedFromV1(tree legacy: BSPNode<String>, zoomedBundleIds: [String]) -> LayoutSnapshot {
    let (tokenized, back) = legacy.tokenized()
    var counts: [String: Int] = [:]
    var slotForToken: [Int: SlotID] = [:]
    for token in tokenized.windows {
      let bundleId = back[token]!
      let occurrence = counts[bundleId, default: 0]
      counts[bundleId] = occurrence + 1
      slotForToken[token] = SlotID(bundleId: bundleId, occurrence: occurrence)
    }
    let slotTree = tokenized.mapWindows { slotForToken[$0]! }
    var zoomCounts: [String: Int] = [:]
    let zoomSlots = zoomedBundleIds.map { bundleId -> SlotID in
      let occurrence = zoomCounts[bundleId, default: 0]
      zoomCounts[bundleId] = occurrence + 1
      return SlotID(bundleId: bundleId, occurrence: occurrence)
    }
    return LayoutSnapshot(tree: slotTree, fullscreenZoomedSlots: zoomSlots)
  }
}

/// Per-entry decoder: reads a v2 snapshot, or migrates a legacy v1 one. Wrapped
/// so a single unreadable entry can be skipped (see `readMap`) instead of
/// resetting every workspace's layout.
private struct MigratingSnapshot: Decodable {
  let snapshot: LayoutSnapshot

  private enum CodingKeys: String, CodingKey {
    case version, tree, fullscreenZoomedSlots, fullscreenZoomedBundleIds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    if version >= 2 {
      let tree = try container.decode(BSPNode<SlotID>.self, forKey: .tree)
      let zoom = try container.decodeIfPresent([SlotID].self, forKey: .fullscreenZoomedSlots) ?? []
      snapshot = LayoutSnapshot(tree: tree, fullscreenZoomedSlots: zoom)
    } else {
      let legacyTree = try container.decode(BSPNode<String>.self, forKey: .tree)
      let legacyZoom = try container.decodeIfPresent([String].self, forKey: .fullscreenZoomedBundleIds) ?? []
      snapshot = LayoutSnapshot.migratedFromV1(tree: legacyTree, zoomedBundleIds: legacyZoom)
    }
  }
}

/// Decodes the whole `layouts.json` map, skipping any single entry that fails
/// to decode/migrate instead of letting one bad workspace reset all of them.
/// The top-level decode still throws if the file isn't a JSON object at all.
private struct ResilientSnapshotMap: Decodable {
  let map: [String: LayoutSnapshot]
  let skipped: [String]

  private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    var out: [String: LayoutSnapshot] = [:]
    var dropped: [String] = []
    for key in container.allKeys {
      if let entry = try? container.decode(MigratingSnapshot.self, forKey: key) {
        out[key.stringValue] = entry.snapshot
      } else {
        dropped.append(key.stringValue)
      }
    }
    map = out
    skipped = dropped
  }
}

extension LayoutStoreClient: DependencyKey {
  static let liveValue: LayoutStoreClient = {
    let store = LayoutStore()
    return LayoutStoreClient(
      save: { id, snapshot in await store.save(workspaceId: id, snapshot: snapshot) },
      load: { id in await store.load(workspaceId: id) },
      clear: { id in await store.clear(workspaceId: id) },
    )
  }()

  static let testValue = LayoutStoreClient(
    save: { _, _ in },
    load: { _ in nil },
    clear: { _ in },
  )
  static let previewValue = testValue
}

extension DependencyValues {
  var layoutStore: LayoutStoreClient {
    get { self[LayoutStoreClient.self] }
    set { self[LayoutStoreClient.self] = newValue }
  }
}

// MARK: - LayoutStore

/// Single JSON file (`layouts.json`) next to `config.toml`, holding a
/// `[workspaceUUID: LayoutSnapshot]` map. The actor's serial executor
/// is the only writer/reader, so concurrent activations can't race on
/// the file. The whole map is small (one snapshot per workspace) so a
/// full rewrite per save is fine.
private actor LayoutStore {
  private let fileURL = ConfigLocation.directory
    .appendingPathComponent("layouts.json", isDirectory: false)
  /// In-memory source of truth, read from disk once; saves write through.
  /// Re-reading + re-decoding the whole file before every save was pure
  /// disk churn (one full decode per committed resize/drag/BSP operation).
  private var cachedMap: [String: LayoutSnapshot]?

  // MARK: Internal

  func save(workspaceId: UUID, snapshot: LayoutSnapshot) {
    var map = loadedMap()
    guard map[workspaceId.uuidString] != snapshot else { return }
    map[workspaceId.uuidString] = snapshot
    cachedMap = map
    writeMap(map)
  }

  func load(workspaceId: UUID) -> LayoutSnapshot? {
    loadedMap()[workspaceId.uuidString]
  }

  func clear(workspaceId: UUID) {
    var map = loadedMap()
    guard map.removeValue(forKey: workspaceId.uuidString) != nil else { return }
    cachedMap = map
    writeMap(map)
  }

  private func loadedMap() -> [String: LayoutSnapshot] {
    if let cachedMap { return cachedMap }
    let loaded = readMap()
    cachedMap = loaded
    return loaded
  }

  private func readMap() -> [String: LayoutSnapshot] {
    // A missing file is the normal first-run state; a file that exists but
    // doesn't decode at all means stored layouts are being dropped — surface it.
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    @Dependency(\.errorReporter) var reporter
    do {
      // Decode per entry (v2 or migrated-v1) so one unreadable workspace is
      // skipped rather than resetting every workspace's layout.
      let decoded = try YYJSONDecoder().decode(ResilientSnapshotMap.self, from: data)
      if decoded.skipped.isEmpty {
        reporter.resolve("Layouts")
      } else {
        // Not silent: a skipped entry is a real (partial) loss, surface it.
        reporter.report(
          "Layouts",
          String(
            localized:
              "\(decoded.skipped.count) workspace layout(s) could not be read and were reset"
          ),
          "workspaceIds: \(decoded.skipped.joined(separator: ", "))"
        )
      }
      return decoded.map
    } catch {
      reporter.report(
        "Layouts",
        String(localized: "layouts.json could not be read — saved layouts reset"),
        ErrorReportClient.describe(error)
      )
      return [:]
    }
  }

  private func writeMap(_ map: [String: LayoutSnapshot]) {
    @Dependency(\.errorReporter) var reporter
    do {
      try ConfigLocation.ensureDirectoryExists()
      let data = try YYJSONEncoder().encode(map)
      try data.write(to: fileURL, options: .atomic)
      reporter.resolve("Layouts")
    } catch {
      logger.error("layout save failed: \(error.localizedDescription, privacy: .public)")
      reporter.report(
        "Layouts",
        String(localized: "layouts.json could not be saved — layout changes won't persist"),
        ErrorReportClient.describe(error)
      )
    }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "LayoutStore")
