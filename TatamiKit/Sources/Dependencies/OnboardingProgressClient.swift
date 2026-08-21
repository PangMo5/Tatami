// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import DependenciesMacros
import Foundation

// MARK: - OnboardingProgressClient

@DependencyClient
struct OnboardingProgressClient: Sendable {
  var hasCompleted: @Sendable () async -> Bool = { false }
  var load: @Sendable () async -> OnboardingProgress? = { nil }
  var save: @Sendable (OnboardingProgress) async -> Void = { _ in }
  var complete: @Sendable () async -> Void = { }
  var requestResumeAfterRelaunch: @Sendable () async -> Void = { }
  var consumeResumeAfterRelaunch: @Sendable () async -> Bool = { false }
}

// MARK: DependencyKey

extension OnboardingProgressClient: DependencyKey {
  static let liveValue: OnboardingProgressClient = {
    let store = OnboardingProgressStore()
    return OnboardingProgressClient(
      hasCompleted: { await store.hasCompleted() },
      load: { await store.load() },
      save: { await store.save($0) },
      complete: { await store.complete() },
      requestResumeAfterRelaunch: { await store.requestResumeAfterRelaunch() },
      consumeResumeAfterRelaunch: { await store.consumeResumeAfterRelaunch() },
    )
  }()

  static let testValue = OnboardingProgressClient()
  static let previewValue = testValue
}

extension DependencyValues {
  var onboardingProgress: OnboardingProgressClient {
    get { self[OnboardingProgressClient.self] }
    set { self[OnboardingProgressClient.self] = newValue }
  }
}

// MARK: - OnboardingProgressStore

private actor OnboardingProgressStore {

  // MARK: Internal

  func hasCompleted() -> Bool {
    defaults.integer(forKey: Self.completionKey) >= Self.schemaVersion
  }

  func load() -> OnboardingProgress? {
    guard let data = defaults.data(forKey: Self.progressKey) else { return nil }
    return try? JSONDecoder().decode(OnboardingProgress.self, from: data)
  }

  func save(_ progress: OnboardingProgress) {
    guard let data = try? JSONEncoder().encode(progress) else { return }
    defaults.set(data, forKey: Self.progressKey)
  }

  func complete() {
    defaults.set(Self.schemaVersion, forKey: Self.completionKey)
    defaults.removeObject(forKey: Self.progressKey)
    defaults.removeObject(forKey: Self.resumeAfterRelaunchKey)
  }

  func requestResumeAfterRelaunch() {
    defaults.set(true, forKey: Self.resumeAfterRelaunchKey)
    // This process exits immediately after setting the intent. Synchronize at
    // this explicit process boundary so the replacement process cannot race
    // the normally asynchronous defaults write.
    defaults.synchronize()
  }

  func consumeResumeAfterRelaunch() -> Bool {
    guard defaults.bool(forKey: Self.resumeAfterRelaunchKey) else { return false }
    defaults.removeObject(forKey: Self.resumeAfterRelaunchKey)
    defaults.synchronize()
    return true
  }

  // MARK: Private

  private static let completionKey = "onboarding.completedSchemaVersion"
  private static let progressKey = "onboarding.progress.v1"
  private static let resumeAfterRelaunchKey = "onboarding.resumeAfterRelaunch"
  private static let schemaVersion = 1

  private let defaults = UserDefaults.standard

}
