// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import Foundation
import Sharing
import Testing
@testable import TatamiKit

@Suite(.serialized)
struct AsyncConfigStoreTests {
  @Test @MainActor
  func `initial loading returns while the disk lane is stalled`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let expected = AppConfig(profiles: [Profile(name: "Loaded")])
    try encodeTatamiConfig(expected).write(to: url)
    let release = DispatchSemaphore(value: 0)
    TatamiConfigTransactionCoordinator.queue.async {
      _ = release.wait(timeout: .now() + 3)
    }
    let store = AsyncConfigStore(url: url)
    let key = TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    )
    let config = Shared(wrappedValue: AppConfig(), key)
    #expect(config.isLoading)
    MainActor.assertIsolated()
    release.signal()
    try await config.load()
    #expect(config.wrappedValue.hasSamePersistedContent(as: expected))
  }

  @Test @MainActor
  func `queued edits are durable before flush and preserve the session profile`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let first = Profile(name: "First")
    let second = Profile(name: "Second")
    let initial = AppConfig(profiles: [first, second])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    config.withLock { $0.activeProfileId = second.id }
    config.withLock { $0.mutateProfile(first.id) { $0.name = "Renamed" } }
    await store.flush()
    let disk = try decodeTatamiConfig(Data(contentsOf: url))
    #expect(disk.profiles.first?.name == "Renamed")
    #expect(config.wrappedValue.activeProfileId == second.id)
    #expect(config.saveError == nil)
  }

  @Test
  func `failed publication rolls back the exchanged file`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let baseline = AppConfig(profiles: [Profile(name: "Original")])
    let data = try encodeTatamiConfig(baseline)
    try data.write(to: url)
    #expect(throws: (any Error).self) {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: data,
        with: AppConfig(profiles: [Profile(name: "Rejected")]),
        at: url,
        suppressDidSet: false,
        publish: { false },
      )
    }
    #expect(try Data(contentsOf: url) == data)
  }

  @Test
  func `failed first publication restores a missing file`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("config.toml")
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: nil,
        with: AppConfig(),
        at: url,
        suppressDidSet: false,
        publish: { false },
      )
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test(.timeLimit(.minutes(1))) @MainActor
  func `atomic external replacements keep the watcher attached and preserve the active profile`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let first = Profile(name: "First")
    let second = Profile(name: "Second")
    let initial = AppConfig(profiles: [first, second])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    let identity = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64
    config.withLock { $0.activeProfileId = second.id }
    await store.flush()
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64 == identity)

    let (updates, continuation) = AsyncStream<Result<AppConfig?, any Error>>.makeStream()
    let subscription = store.subscribe(SharedSubscriber(callback: { continuation.yield($0) }))
    defer { subscription.cancel()
      continuation.finish()
    }
    await store.flush()
    var iterator = updates.makeAsyncIterator()
    for name in ["External one", "External two"] {
      var external = initial
      external.mutateProfile(first.id) { $0.name = name }
      try encodeTatamiConfig(external).write(to: url, options: .atomic)
      let event = try #require(await iterator.next())
      let received = try event.get()
      let published = try #require(received)
      #expect(published.profiles.first?.name == name)
      #expect(published.activeProfileId == second.id)
    }
    #expect(config.wrappedValue.profiles.first?.name == "External two")
  }

  @Test
  func `rollback preserves an external replacement made during publication`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let external = Data("external-writer".utf8)
    #expect(throws: (any Error).self) {
      try TatamiConfigTransactionCoordinator.shared.replace(
        revision: nil,
        with: AppConfig(),
        at: url,
        suppressDidSet: false,
        publish: {
          do { try external.write(to: url, options: .atomic) }
          catch { Issue.record(error) }
          return false
        },
      )
    }
    #expect(try Data(contentsOf: url) == external)
  }

  @Test @MainActor
  func `configuration benchmark compares synchronous admission with the worker boundary`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profiles = (0..<8).map { p in
      Profile(name: "Profile \(p)", workspaces: .init(uniqueElements: (0..<16).map { w in
        Workspace(name: "Workspace \(w)", apps: (0..<4).map { a in
          AppAssignment(bundleIdentifier: "test.app.\(a)", name: "Application \(a)")
        })
      }))
    }
    let initial = AppConfig(profiles: profiles)
    let bytes = try encodeTatamiConfig(initial)
    let clock = ContinuousClock()
    func ms(_ start: ContinuousClock.Instant) -> Double {
      let elapsed = start.duration(to: clock.now).components
      return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }
    var samples = [[String: Double]]()
    for iteration in 0..<4 {
      var row: [String: Double] = ["iteration": Double(iteration), "bytes": Double(bytes.count)]
      for asynchronous in [false, true] {
        let url = directory.appendingPathComponent("\(iteration)-\(asynchronous).toml")
        try bytes.write(to: url)
        let diskStore = asynchronous ? AsyncConfigStore(url: url) : nil
        let started = clock.now
        let config = withDependencies { $0.defaultFileStorage = .fileSystem } operation: {
          Shared(wrappedValue: AppConfig(), TatamiConfigKey(
            base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
            store: diskStore,
          ))
        }
        let label = asynchronous ? "async" : "sync"
        row["\(label)_load_admission_ms"] = ms(started)
        if asynchronous { try await config.load() }
        row["\(label)_load_complete_ms"] = ms(started)
        let saveStarted = clock.now
        config.withLock { $0.mutateProfile(profiles[0].id) { $0.name = "Updated" } }
        row["\(label)_save_admission_ms"] = ms(saveStarted)
        if let diskStore { await diskStore.flush() }
        row["\(label)_save_complete_ms"] = ms(saveStarted)
        #expect(config.saveError == nil)
        #expect(try decodeTatamiConfig(Data(contentsOf: url)).profiles.first?.name == "Updated")
      }
      samples.append(row)
    }
    let report = FileManager.default.temporaryDirectory
      .appendingPathComponent("tatami-config-benchmark-\(ProcessInfo.processInfo.processIdentifier).json")
    try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]).write(to: report)
    print("CONFIG_BENCHMARK_REPORT \(report.path)")
  }

  @Test
  func `failed session write remains retryable for the same profile`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let parent = directory.appendingPathComponent("blocked")
    try Data("not-a-directory".utf8).write(to: parent)
    let url = parent.appendingPathComponent("session.json")
    let store = ProfileSessionStore(fileURL: url)
    let profile = UUID()
    await store.saveActiveProfileId(profile)
    #expect(await store.load().activeProfileId == nil)
    try FileManager.default.removeItem(at: parent)
    await store.saveActiveProfileId(profile)
    let saved = try JSONDecoder().decode(ProfileSession.self, from: Data(contentsOf: url))
    #expect(saved.activeProfileId == profile)
  }

  @Test @MainActor
  func `queued load cannot overwrite an edit admitted before publication`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let profile = Profile(name: "Original")
    let initial = AppConfig(profiles: [profile])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    let release = DispatchSemaphore(value: 0)
    TatamiConfigTransactionCoordinator.queue.async { _ = release.wait(timeout: .now() + 3) }
    let (updates, continuation) = AsyncStream<Result<AppConfig?, any Error>>.makeStream()
    defer { continuation.finish() }
    store.load(LoadContinuation { continuation.yield($0) })
    config.withLock { $0.mutateProfile(profile.id) { $0.name = "New edit" } }
    release.signal()
    var iterator = updates.makeAsyncIterator()
    let event = try #require(await iterator.next())
    let loaded = try event.get()
    #expect(loaded?.profiles.first?.name == "New edit")
    await store.flush()
    #expect(try decodeTatamiConfig(Data(contentsOf: url)).profiles.first?.name == "New edit")
  }

  @Test @MainActor
  func `an edit following durable publication still reaches disk`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let profile = Profile(name: "Original")
    let initial = AppConfig(profiles: [profile])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    var changed = initial
    changed.mutateProfile(profile.id) { $0.name = "Committed" }
    let committed = changed
    let bytes = try encodeTatamiConfig(committed)
    await withCheckedContinuation { continuation in
      TatamiConfigTransactionCoordinator.queue.async {
        do { try bytes.write(to: url, options: .atomic) }
        catch { Issue.record(error) }
        DispatchQueue.main.sync {
          ConfigPublication.$isPublishing.withValue(true) {
            config.withLock { $0 = committed }
            store.recordDurablePublication(committed)
          }
          config.withLock { $0.mutateProfile(profile.id) { $0.name = "Following edit" } }
        }
        store.didCommit(committed, data: bytes)
        continuation.resume()
      }
    }
    await store.flush()
    #expect(try decodeTatamiConfig(Data(contentsOf: url)).profiles.first?.name == "Following edit")
    #expect(config.saveError == nil)
  }

  @Test @MainActor
  func `flush reports a rejected save instead of implying durable success`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let profile = Profile(name: "Original")
    let initial = AppConfig(profiles: [profile])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    let release = DispatchSemaphore(value: 0)
    TatamiConfigTransactionCoordinator.queue.async { _ = release.wait(timeout: .now() + 3) }
    let external = Data("external-writer".utf8)
    try external.write(to: url, options: .atomic)
    config.withLock { $0.mutateProfile(profile.id) { $0.name = "Unsaved edit" } }
    release.signal()
    let failure = await store.flush()
    #expect(failure != nil)
    #expect(config.saveError != nil)
    #expect(try Data(contentsOf: url) == external)
  }

  @Test @MainActor
  func `an older automatic save cannot undo a durable publication`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.toml")
    let profile = Profile(name: "Original")
    let initial = AppConfig(profiles: [profile])
    try encodeTatamiConfig(initial).write(to: url)
    let store = AsyncConfigStore(url: url)
    let config = Shared(wrappedValue: initial, TatamiConfigKey(
      base: .fileStorage(url, decode: decodeTatamiConfig, encode: encodeTatamiConfig),
      store: store,
    ))
    try await config.load()
    var changed = initial
    changed.mutateProfile(profile.id) { $0.name = "Committed" }
    let committed = changed
    let bytes = try encodeTatamiConfig(committed)
    await withCheckedContinuation { continuation in
      TatamiConfigTransactionCoordinator.queue.async {
        do { try bytes.write(to: url, options: .atomic) }
        catch { Issue.record(error) }
        DispatchQueue.main.sync {
          // A profile/session-only automatic write is queued after this
          // transaction started, but before its in-memory publication.
          config.withLock { $0 = $0 }
          ConfigPublication.$isPublishing.withValue(true) {
            config.withLock { $0 = committed }
            store.recordDurablePublication(committed)
          }
        }
        store.didCommit(committed, data: bytes)
        continuation.resume()
      }
    }
    let failure = await store.flush()
    #expect(failure == nil)
    #expect(try decodeTatamiConfig(Data(contentsOf: url)).profiles.first?.name == "Committed")
  }
}
