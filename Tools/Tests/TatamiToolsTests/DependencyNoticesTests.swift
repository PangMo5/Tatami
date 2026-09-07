// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TatamiToolsKit

@Test
func `dependency notices use pinned blobs instead of modified checkouts`() async throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  let workspace = Workspace(root: fixture.directory)
  let checkout = workspace.tools.at(".build/checkouts/example")
  try checkout.makeDirectory()
  try checkout.at("LICENSE").write("Pinned license text.\n")
  try checkout.at("Sources/Component/NOTICE.txt").write("Component notice.\n")
  try await runProcess(["git", "init", "--quiet", checkout.path])
  try await runProcess(["git", "-C", checkout.path, "add", "."])
  try await runProcess([
    "git",
    "-C",
    checkout.path,
    "-c",
    "user.name=Notice Test",
    "-c",
    "user.email=notice@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "-m",
    "Fixture",
  ])
  let revision = trim(try await runProcess(["git", "-C", checkout.path, "rev-parse", "HEAD"], capture: true))
  let lock = JSON.object([("pins", .array([.object([
    ("identity", .string("example")),
    ("location", .string("https://example.invalid/example.git")),
    ("state", .object([("version", .string("1.0.0")), ("revision", .string(revision))])),
  ])]))])
  try lock.write(workspace.tools.at("Package.resolved"))
  try checkout.at("LICENSE").write("Uncommitted replacement.\n")
  let builder = DependencyNotices(workspace: workspace)
  let rendered = try await builder.rendered()
  #expect(rendered.contains("Pinned license text."))
  #expect(rendered.contains("Component notice."))
  #expect(rendered.contains(revision))
  #expect(!rendered.contains("Uncommitted replacement."))
  try await builder.build(check: false)
  try await builder.build(check: true)
  try workspace.tools.at("THIRD_PARTY_NOTICES.md").write("stale")
  await #expect(throws: (any Error).self) { try await builder.build(check: true) }
}
