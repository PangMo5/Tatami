import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Persists per-workspace BSP layout snapshots so workspaces with
/// `tilingMemory == .persistent` keep their split axes + ratios across
/// app restarts. Snapshots are keyed by workspace UUID and store a
/// `BSPNode<String>` (bundle-id leaves) — `WindowKey`s are process-
/// scoped and meaningless after a restart, so we serialize the shape
/// and re-hydrate it against live windows on the next activation.
@DependencyClient
public struct LayoutStoreClient: Sendable {
  public var save: @Sendable (UUID, LayoutSnapshot) -> Void
  public var load: @Sendable (UUID) async -> LayoutSnapshot?
  public var clear: @Sendable (UUID) -> Void
}

/// On-disk shape of one workspace's tiling memory. Stored alongside the
/// tree so a workspace can restore both its BSP layout and which
/// (bundle-identified) windows were zoomed at the time of the last save.
public struct LayoutSnapshot: Codable, Hashable, Sendable {
  public var tree: BSPNode<String>
  /// Bundle identifiers of the zoomed windows at save time. On hydration
  /// each entry re-attaches to the first live window matching that
  /// bundle id; with multiple zoomed windows from the same app only one
  /// of them is restored, mirroring the tree hydration heuristic.
  public var zoomedBundleIds: [String]

  public init(tree: BSPNode<String>, zoomedBundleIds: [String] = []) {
    self.tree = tree
    self.zoomedBundleIds = zoomedBundleIds
  }

  private enum CodingKeys: String, CodingKey {
    case tree
    case zoomedBundleIds
    case zoomedBundleId // legacy single-zoom field
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.tree = try c.decode(BSPNode<String>.self, forKey: .tree)
    if let many = try? c.decode([String].self, forKey: .zoomedBundleIds) {
      self.zoomedBundleIds = many
    } else if let one = try? c.decode(String.self, forKey: .zoomedBundleId) {
      // Pre-multi-zoom snapshots stored a single bundle id; promote it.
      self.zoomedBundleIds = [one]
    } else {
      self.zoomedBundleIds = []
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(tree, forKey: .tree)
    try c.encode(zoomedBundleIds, forKey: .zoomedBundleIds)
  }
}

extension LayoutStoreClient: DependencyKey {
  public static let liveValue: LayoutStoreClient = {
    let store = LayoutStore()
    return LayoutStoreClient(
      save: { id, snapshot in
        Task { await store.save(workspaceId: id, snapshot: snapshot) }
      },
      load: { id in await store.load(workspaceId: id) },
      clear: { id in Task { await store.clear(workspaceId: id) } }
    )
  }()

  public static let testValue = LayoutStoreClient(
    save: { _, _ in },
    load: { _ in nil },
    clear: { _ in }
  )
  public static let previewValue = testValue
}

extension DependencyValues {
  public var layoutStore: LayoutStoreClient {
    get { self[LayoutStoreClient.self] }
    set { self[LayoutStoreClient.self] = newValue }
  }
}

/// Single JSON file (`layouts.json`) next to `config.toml`, holding a
/// `[workspaceUUID: LayoutSnapshot]` map. The actor's serial executor
/// is the only writer/reader, so concurrent activations can't race on
/// the file. The whole map is small (one snapshot per workspace) so a
/// full rewrite per save is fine.
private actor LayoutStore {
  private let fileURL = ConfigLocation.directory
    .appendingPathComponent("layouts.json", isDirectory: false)

  func save(workspaceId: UUID, snapshot: LayoutSnapshot) {
    var map = readMap()
    map[workspaceId.uuidString] = snapshot
    writeMap(map)
  }

  func load(workspaceId: UUID) -> LayoutSnapshot? {
    readMap()[workspaceId.uuidString]
  }

  func clear(workspaceId: UUID) {
    var map = readMap()
    guard map.removeValue(forKey: workspaceId.uuidString) != nil else { return }
    writeMap(map)
  }

  private func readMap() -> [String: LayoutSnapshot] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    let decoder = JSONDecoder()
    if let map = try? decoder.decode([String: LayoutSnapshot].self, from: data) {
      return map
    }
    // Backward compatibility: pre-snapshot layouts stored a bare
    // `BSPNode<String>` per workspace. Promote them to snapshots with
    // no zoom recorded; the next save rewrites the file in the new shape.
    if let legacy = try? decoder.decode([String: BSPNode<String>].self, from: data) {
      return legacy.mapValues { LayoutSnapshot(tree: $0) }
    }
    return [:]
  }

  private func writeMap(_ map: [String: LayoutSnapshot]) {
    do {
      try ConfigLocation.ensureDirectoryExists()
      let data = try JSONEncoder().encode(map)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      logger.error("layout save failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "LayoutStore")
