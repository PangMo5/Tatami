import Dependencies
import DependenciesMacros
import Foundation
import OSLog

/// Persists *session* state that isn't a setting — currently just which profile
/// is active — to its own JSON file next to `config.toml`, the same way tiling
/// memory lives in `layouts.json`. Keeping it out of `config.toml` means a
/// profile switch never rewrites (and normalizes / strips comments from) the
/// user's hand-editable settings file, and the selection still survives a
/// restart. Injected into `AppConfig.activeProfileId` at startup.
@DependencyClient
struct ProfileSessionStoreClient: Sendable {
  var loadActiveProfileId: @Sendable () async -> UUID?
  var saveActiveProfileId: @Sendable (UUID?) async -> Void
}

extension ProfileSessionStoreClient: DependencyKey {
  static let liveValue: ProfileSessionStoreClient = {
    let store = ProfileSessionStore()
    return ProfileSessionStoreClient(
      loadActiveProfileId: { await store.load() },
      saveActiveProfileId: { id in await store.save(id) }
    )
  }()

  static let testValue = ProfileSessionStoreClient(
    loadActiveProfileId: { nil },
    saveActiveProfileId: { _ in }
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var profileSessionStore: ProfileSessionStoreClient {
    get { self[ProfileSessionStoreClient.self] }
    set { self[ProfileSessionStoreClient.self] = newValue }
  }
}

/// On-disk shape. A struct (not a bare UUID) so more session fields can join
/// later without a format break.
private struct ProfileSession: Codable, Hashable, Sendable {
  var activeProfileId: UUID?
}

/// Single small JSON file (`profile-session.json`) next to `config.toml`. One
/// serial actor owns all I/O; the whole thing is tiny so a full rewrite per
/// save is fine.
private actor ProfileSessionStore {
  private let fileURL = ConfigLocation.directory
    .appendingPathComponent("profile-session.json", isDirectory: false)
  private var cached: ProfileSession?

  func load() -> UUID? {
    loaded().activeProfileId
  }

  func save(_ id: UUID?) {
    var session = loaded()
    guard session.activeProfileId != id else { return }
    session.activeProfileId = id
    cached = session
    write(session)
  }

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
