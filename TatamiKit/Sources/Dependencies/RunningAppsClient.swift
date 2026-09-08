// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import Dependencies
import DependenciesMacros
import Foundation
import os

/// AppKit can report -1 for a live application (observed with Preview).
/// Recover the process from its WindowServer ownership, verifying application
/// identity rather than matching a display name or guessing a process.
func applicationProcessIdentifiers(
  _ applications: [NSRunningApplication]
) async -> [NSRunningApplication: pid_t] {
  @Dependency(\.runningApps) var runningApps
  return await runningApps.processIdentifiers(applications)
}

func applicationProcessIdentifier(_ app: NSRunningApplication) async -> pid_t? {
  await applicationProcessIdentifiers([app])[app]
}

/// Reducer and notification callbacks may read a known identity, but must never
/// trigger WindowServer discovery synchronously.
func cachedApplicationProcessIdentifier(_ app: NSRunningApplication) -> pid_t? {
  @Dependency(\.runningApps) var runningApps
  return runningApps.cachedProcessIdentifier(app)
}

func isFrontmostApplication(pid: pid_t) -> Bool {
  guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
  return NSWorkspace.shared.frontmostApplication?.isEqual(app) == true
}

func resolveApplicationProcessIdentifier(
  reportedPID: pid_t,
  windowOwnerPIDs: [pid_t],
  belongsToApplication: (pid_t) -> Bool,
) -> pid_t? {
  if reportedPID > 0 { return reportedPID }
  let matching = Set(windowOwnerPIDs).filter { $0 > 0 && belongsToApplication($0) }
  // Ambiguous ownership is not evidence for selecting an arbitrary process.
  return matching.count == 1 ? matching.first : nil
}

// MARK: - ApplicationProcessIdentifierCache

/// Cache only proven process identities. Every reuse validates ownership;
/// negative results are not cached because a launching app can gain a window.
struct ApplicationProcessIdentifierCache<Application: Hashable & Sendable>: Sendable {

  // MARK: Internal

  mutating func removeTerminated(where isTerminated: (Application) -> Bool) {
    entries = entries.filter { !isTerminated($0.key) }
  }

  mutating func resolve(
    application: Application,
    reportedPID: pid_t,
    belongsToApplication: (pid_t) -> Bool,
    windowOwnerPIDs: () -> [pid_t],
  ) -> pid_t? {
    if reportedPID > 0 {
      entries.removeValue(forKey: application)
      return reportedPID
    }
    if let pid = entries[application], belongsToApplication(pid) {
      return pid
    }
    let pid = resolveApplicationProcessIdentifier(
      reportedPID: reportedPID,
      windowOwnerPIDs: windowOwnerPIDs(),
      belongsToApplication: belongsToApplication,
    )
    entries[application] = pid
    return pid
  }

  // MARK: Private

  private var entries = [Application: pid_t]()

}

// MARK: - ApplicationProcessResolver

private final class ApplicationProcessResolver: Sendable {

  // MARK: Lifecycle

  init() { }

  // MARK: Internal

  func identifiers(_ applications: [NSRunningApplication]) async -> [NSRunningApplication: pid_t] {
    @Dependency(\.debugLog) var debugLog
    return await worker.run {
      let resolved = self.cache.withLock { cache in
        cache.removeTerminated { $0.isTerminated }
        var result = [NSRunningApplication: pid_t]()
        var ownerPIDs: [pid_t]?
        for app in applications where !app.isTerminated {
          var scanned = false
          let reportedPID = app.processIdentifier
          let pid = cache.resolve(
            application: app,
            reportedPID: reportedPID,
            belongsToApplication: { pid in
              guard let owner = NSRunningApplication(processIdentifier: pid), !owner.isTerminated
              else { return false }
              return owner.isEqual(app)
            },
            windowOwnerPIDs: {
              scanned = true
              if ownerPIDs == nil {
                let windows = CGWindowListCopyWindowInfo(
                  [.optionAll, .excludeDesktopElements],
                  kCGNullWindowID,
                ) as? [[String: Any]] ?? []
                ownerPIDs = windows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
              }
              return ownerPIDs ?? []
            },
          )
          result[app] = pid
          if scanned {
            debugLog.log(
              "ProcessIdentity",
              "\(app.bundleIdentifier ?? "?") reportedPID=\(reportedPID) windowOwnerPID=\(pid.map(String.init) ?? "unresolved")",
            )
          }
        }
        return result
      }
      self.published.withLock { known in
        known = known.filter { !$0.key.isTerminated }
        for app in applications { known[app] = resolved[app] }
      }
      return resolved
    }
  }

  func cachedIdentifier(_ app: NSRunningApplication) -> pid_t? {
    guard !app.isTerminated else { return nil }
    let reported = app.processIdentifier
    if reported > 0 { return reported }
    guard
      let pid = published.withLock({ $0[app] }),
      let owner = NSRunningApplication(processIdentifier: pid),
      !owner.isTerminated, owner.isEqual(app)
    else { return nil }
    return pid
  }

  // MARK: Private

  private let worker = BlockingWorkQueue(label: "dev.PangMo5.Tatami.process-identity")
  private let cache = OSAllocatedUnfairLock(initialState: ApplicationProcessIdentifierCache<NSRunningApplication>())
  private let published = OSAllocatedUnfairLock(initialState: [NSRunningApplication: pid_t]())

}

// MARK: - RunningAppsClient

/// Snapshot of the macOS apps currently runnable by the user. Wrapping
/// `NSWorkspace.shared.runningApplications` behind a `@Dependency` lets
/// reducers stay testable.
@DependencyClient
struct RunningAppsClient: Sendable {
  var current: @Sendable () -> [MacApp] = { [] }
  var resolveInstalled: @Sendable ([String]) async -> [MacApp] = { bundleIds in
    bundleIds.map { MacApp(bundleIdentifier: $0, name: $0) }
  }

  var processIdentifiers: @Sendable ([NSRunningApplication]) async
    -> [NSRunningApplication: pid_t] = { _ in [:] }
  var cachedProcessIdentifier: @Sendable (NSRunningApplication) -> pid_t? = { _ in nil }
}

// MARK: DependencyKey

extension RunningAppsClient: DependencyKey {
  /// UI callers capture this snapshot on the main actor. AppKit allows these
  /// reads from other threads; its time-varying application properties update
  /// as the main run loop advances. This isolation is our caller/cache policy,
  /// not an AppKit requirement.
  static let liveValue: RunningAppsClient = {
    let resolver = ApplicationProcessResolver()
    let metadataWorker = BlockingWorkQueue(label: "dev.PangMo5.Tatami.installed-apps")
    return RunningAppsClient(
      current: {
        MainActor.assumeIsolated {
          NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> MacApp? in
              guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else {
                return nil
              }
              return MacApp(
                bundleIdentifier: bundleId,
                name: app.localizedName ?? bundleId,
                iconPath: app.bundleURL?.path,
              )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
      },
      resolveInstalled: { bundleIds in
        await metadataWorker.run {
          bundleIds.map { bundleId in
            guard
              let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleId
              )
            else {
              return MacApp(bundleIdentifier: bundleId, name: bundleId)
            }
            let bundle = Bundle(url: url)
            let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
              ?? bundle?.infoDictionary?["CFBundleName"] as? String
              ?? url.deletingPathExtension().lastPathComponent
            return MacApp(
              bundleIdentifier: bundleId,
              name: name,
              iconPath: url.path,
            )
          }
        }
      },
      processIdentifiers: { await resolver.identifiers($0) },
      cachedProcessIdentifier: { resolver.cachedIdentifier($0) },
    )
  }()

  static let testValue = RunningAppsClient(
    current: { [] },
    resolveInstalled: { bundleIds in
      bundleIds.map { MacApp(bundleIdentifier: $0, name: $0) }
    },
    processIdentifiers: { _ in [:] },
    cachedProcessIdentifier: { _ in nil },
  )
  static let previewValue = RunningAppsClient(
    current: {
      [
        MacApp(bundleIdentifier: "com.apple.Safari", name: "Safari"),
        MacApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"),
        MacApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
      ]
    },
    resolveInstalled: { bundleIds in
      bundleIds.map { MacApp(bundleIdentifier: $0, name: $0) }
    },
    processIdentifiers: { _ in [:] },
    cachedProcessIdentifier: { _ in nil },
  )
}

extension DependencyValues {
  var runningApps: RunningAppsClient {
    get { self[RunningAppsClient.self] }
    set { self[RunningAppsClient.self] = newValue }
  }
}
