import Dependencies
import DependenciesMacros
import Foundation
import OSLog

// MARK: - ProfileSessionStoreClient

/// Persists *session* state that isn't a setting — the active profile and
/// workspace MRU — to its own JSON file next to `config.toml`, the same way
/// tiling memory lives in `layouts.json`. Keeping it out of `config.toml` means
/// switching never rewrites (and normalizes / strips comments from) the user's
/// hand-editable settings file, while the last display/workspace assignment
/// still survives a restart.
@DependencyClient
struct ProfileSessionStoreClient: Sendable {
  var load: @Sendable () async -> ProfileSession = { ProfileSession() }
  var saveActiveProfileId: @Sendable (UUID?) async -> Void
  var saveWorkspaceState:
    @Sendable (_ displayWorkspaceHistory: [DisplayName: [UUID]], _ workspaceMRU: [UUID])
    async -> Void
}

// MARK: DependencyKey

extension ProfileSessionStoreClient: DependencyKey {
  static let liveValue: ProfileSessionStoreClient = {
    let store = ProfileSessionStore()
    return ProfileSessionStoreClient(
      load: { await store.load() },
      saveActiveProfileId: { id in await store.saveActiveProfileId(id) },
      saveWorkspaceState: { history, mru in
        await store.saveWorkspaceState(
          displayWorkspaceHistory: history,
          workspaceMRU: mru,
        )
      },
    )
  }()

  static let testValue = ProfileSessionStoreClient(
    load: { ProfileSession() },
    saveActiveProfileId: { _ in },
    saveWorkspaceState: { _, _ in },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var profileSessionStore: ProfileSessionStoreClient {
    get { self[ProfileSessionStoreClient.self] }
    set { self[ProfileSessionStoreClient.self] = newValue }
  }
}

// MARK: - ProfileSession

/// On-disk shape. New fields decode with empty defaults so an existing
/// active-profile-only file migrates in place on the first workspace switch.
struct ProfileSession: Codable, Hashable, Sendable {

  // MARK: Lifecycle

  init(
    activeProfileId: UUID? = nil,
    displayWorkspaceHistory: [DisplayWorkspaceHistory] = [],
    workspaceMRU: [UUID] = [],
  ) {
    self.activeProfileId = activeProfileId
    self.displayWorkspaceHistory = displayWorkspaceHistory
    self.workspaceMRU = workspaceMRU
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activeProfileId = try container.decodeIfPresent(UUID.self, forKey: .activeProfileId)
    displayWorkspaceHistory =
      try container.decodeIfPresent(
        [DisplayWorkspaceHistory].self,
        forKey: .displayWorkspaceHistory,
      ) ?? []
    workspaceMRU = try container.decodeIfPresent([UUID].self, forKey: .workspaceMRU) ?? []
  }

  // MARK: Internal

  struct DisplayWorkspaceHistory: Codable, Hashable, Sendable {
    var display: DisplayName
    var workspaceIds: [UUID]
  }

  var activeProfileId: UUID?
  var displayWorkspaceHistory: [DisplayWorkspaceHistory]
  var workspaceMRU: [UUID]

  var historyByDisplay: [DisplayName: [UUID]] {
    displayWorkspaceHistory.reduce(into: [DisplayName: [UUID]]()) { result, entry in
      for workspaceId in entry.workspaceIds
        where !result[entry.display, default: []].contains(workspaceId)
      {
        result[entry.display, default: []].append(workspaceId)
      }
    }
  }

}

// MARK: - ProfileSessionStore

/// Single small JSON file (`profile-session.json`) next to `config.toml`. One
/// serial actor owns all I/O; the whole thing is tiny so a full rewrite per
/// save is fine.
private actor ProfileSessionStore {

  // MARK: Internal

  func load() -> ProfileSession {
    loaded()
  }

  func saveActiveProfileId(_ id: UUID?) {
    var session = loaded()
    guard session.activeProfileId != id else { return }
    session.activeProfileId = id
    cached = session
    write(session)
  }

  func saveWorkspaceState(
    displayWorkspaceHistory: [DisplayName: [UUID]],
    workspaceMRU: [UUID],
  ) {
    var session = loaded()
    let history = displayWorkspaceHistory
      .map {
        ProfileSession.DisplayWorkspaceHistory(
          display: $0.key,
          workspaceIds: $0.value,
        )
      }
      .sorted {
        ($0.display.uuid ?? $0.display.name) < ($1.display.uuid ?? $1.display.name)
      }
    guard
      session.displayWorkspaceHistory != history
      || session.workspaceMRU != workspaceMRU
    else { return }
    session.displayWorkspaceHistory = history
    session.workspaceMRU = workspaceMRU
    cached = session
    write(session)
  }

  // MARK: Private

  private let fileURL = ConfigLocation.directory
    .appendingPathComponent("profile-session.json", isDirectory: false)
  private var cached: ProfileSession?

  private func loaded() -> ProfileSession {
    if let cached { return cached }
    let session = read()
    cached = session
    return session
  }

  private func read() -> ProfileSession {
    // A missing file is the normal first-run state; an unreadable one just
    // resets the selection to the default profile. This is derived state, not
    // user data, so a decode failure isn't surfaced as a report.
    guard let data = try? Data(contentsOf: fileURL) else { return ProfileSession() }
    return (try? JSONDecoder().decode(ProfileSession.self, from: data)) ?? ProfileSession()
  }

  private func write(_ session: ProfileSession) {
    do {
      try ConfigLocation.ensureDirectoryExists()
      let data = try JSONEncoder().encode(session)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      logger.error("profile-session save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "ProfileSession")
