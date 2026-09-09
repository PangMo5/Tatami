// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CustomDump
import Dependencies
import Foundation
import Testing
@testable import TatamiKit

struct LayoutStoreTests {
  @Test(arguments: [false, true])
  func `unreadable layouts reject mutations and recover without losing other workspaces`(corruptJSON: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("layouts.json")
    let existingID = UUID(0)
    let newID = UUID(1)
    let existing = LayoutSnapshot(tree: .leaf(SlotID(bundleId: "existing", occurrence: 0)))
    let new = LayoutSnapshot(tree: .leaf(SlotID(bundleId: "new", occurrence: 0)))
    let original = try JSONEncoder().encode([existingID.uuidString: existing])
    let unreadable = corruptJSON ? Data("{broken".utf8) : original
    try unreadable.write(to: url)
    if !corruptJSON {
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    let reports = LockIsolated<[String]>([])
    let resolves = LockIsolated<[String]>([])
    try await withDependencies {
      $0.errorReporter.report = { domain, _, _ in reports.withValue { $0.append(domain) } }
      $0.errorReporter.resolve = { domain in resolves.withValue { $0.append(domain) } }
    } operation: {
      let store = LayoutStore(fileURL: url)
      let unavailable = await store.load(workspaceId: existingID)
      #expect(unavailable == nil)
      await store.save(workspaceId: newID, snapshot: new)
      await store.clear(workspaceId: existingID)
      let copied = await store.copyLayouts([existingID: newID])
      let removed = await store.removeLayouts([existingID])
      #expect(!copied && !removed)
      #expect(!reports.value.isEmpty)
      #expect(resolves.value.isEmpty)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      expectNoDifference(try Data(contentsOf: url), unreadable)

      // Repair the file without recreating the store: failed reads must not
      // publish an empty cache that discards the recovered workspace.
      if corruptJSON { try original.write(to: url) }
      await store.save(workspaceId: newID, snapshot: new)
      let disk = try JSONDecoder().decode([String: LayoutSnapshot].self, from: Data(contentsOf: url))
      expectNoDifference(disk, [existingID.uuidString: existing, newID.uuidString: new])
      let recovered = await store.load(workspaceId: existingID)
      expectNoDifference(recovered, existing)
      #expect(resolves.value.contains("Layouts"))
    }
  }

  @Test
  func `missing layouts create the directory and persist the first snapshot`() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("layouts.json")
    let id = UUID(0)
    let snapshot = LayoutSnapshot(tree: .leaf(SlotID(bundleId: "first", occurrence: 0)))
    let reports = LockIsolated<[String]>([])
    await withDependencies {
      $0.errorReporter.report = { domain, _, _ in reports.withValue { $0.append(domain) } }
      $0.errorReporter.resolve = { _ in }
    } operation: {
      let store = LayoutStore(fileURL: url)
      await store.save(workspaceId: id, snapshot: snapshot)
      let freshStore = LayoutStore(fileURL: url)
      let saved = await freshStore.load(workspaceId: id)
      expectNoDifference(saved, snapshot)
      #expect(reports.value.isEmpty)
    }
  }
}
