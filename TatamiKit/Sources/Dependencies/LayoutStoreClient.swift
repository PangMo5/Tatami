import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import YYJSON

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
/// tree so a workspace can restore its BSP layout and which
/// (bundle-identified) windows were fullscreen-zoomed at the time of
/// the last save. Parent-zoom (per-leaf, single-tile) is carried by
/// the leaf itself inside `tree`.
public struct LayoutSnapshot: Codable, Hashable, Sendable {
  public var tree: BSPNode<String>
  /// Bundle identifiers of the *fullscreen*-zoomed windows at save
  /// time. Tatami-specific multi-window fullscreen: each one renders
  /// at the workspace work area and is excluded from the rest of the
  /// tree's layout. On hydration, each entry re-attaches to the first
  /// live window matching that bundle id.
  public var fullscreenZoomedBundleIds: [String]

  public init(tree: BSPNode<String>, fullscreenZoomedBundleIds: [String] = []) {
    self.tree = tree
    self.fullscreenZoomedBundleIds = fullscreenZoomedBundleIds
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
    // A missing file is the normal first-run state; a file that exists but
    // doesn't decode means stored layouts are being dropped — surface that.
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    do {
      return try YYJSONDecoder().decode([String: LayoutSnapshot].self, from: data)
    } catch {
      @Dependency(\.errorReporter) var reporter
      reporter.report(
        "Layouts",
        "layouts.json could not be read — saved layouts reset",
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
        "layouts.json could not be saved — layout changes won't persist",
        ErrorReportClient.describe(error)
      )
    }
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "LayoutStore")
