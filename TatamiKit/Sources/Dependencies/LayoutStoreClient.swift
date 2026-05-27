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
  public var save: @Sendable (UUID, BSPNode<String>) -> Void
  public var load: @Sendable (UUID) -> BSPNode<String>?
  public var clear: @Sendable (UUID) -> Void
}

extension LayoutStoreClient: DependencyKey {
  public static let liveValue: LayoutStoreClient = {
    let store = LayoutStore()
    return LayoutStoreClient(
      save: { store.save(workspaceId: $0, tree: $1) },
      load: { store.load(workspaceId: $0) },
      clear: { store.clear(workspaceId: $0) }
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
/// `[workspaceUUID: BSPNode<String>]` map. Reads/writes are guarded by
/// a lock; the whole map is small (one tree per workspace) so a full
/// rewrite per save is fine.
private final class LayoutStore: @unchecked Sendable {
  private let lock = NSLock()
  private let fileURL = ConfigLocation.directory
    .appendingPathComponent("layouts.json", isDirectory: false)

  func save(workspaceId: UUID, tree: BSPNode<String>) {
    lock.lock(); defer { lock.unlock() }
    var map = readMap()
    map[workspaceId.uuidString] = tree
    writeMap(map)
  }

  func load(workspaceId: UUID) -> BSPNode<String>? {
    lock.lock(); defer { lock.unlock() }
    return readMap()[workspaceId.uuidString]
  }

  func clear(workspaceId: UUID) {
    lock.lock(); defer { lock.unlock() }
    var map = readMap()
    guard map.removeValue(forKey: workspaceId.uuidString) != nil else { return }
    writeMap(map)
  }

  private func readMap() -> [String: BSPNode<String>] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    return (try? JSONDecoder().decode([String: BSPNode<String>].self, from: data)) ?? [:]
  }

  private func writeMap(_ map: [String: BSPNode<String>]) {
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
