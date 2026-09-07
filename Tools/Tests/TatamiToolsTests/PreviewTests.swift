// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import TatamiToolsKit

@Test
func `preview streams full and ranged media`() async throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  try fixture.directory.at("index.html").write("<p>Preview</p>")
  try fixture.directory.at("movie.mp4").write("0123456789")
  let server = PreviewServer(directory: fixture.directory, workspace: testWorkspace, port: 8769)
  try await server.application().test(.router) { client in
    try await client.execute(uri: "/movie.mp4", method: .get) { response in
      #expect(response.status == .ok)
      #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "0123456789")
      #expect(response.headers[.contentType] == "video/mp4")
      #expect(response.headers[.cacheControl] == "no-cache")
      #expect(response.headers[.init("X-Tatami-Preview-Root")!] == server.rootHash)
    }
    for (range, body, contentRange) in [
      ("bytes=2-4", "234", "bytes 2-4/10"),
      ("bytes=-3", "789", "bytes 7-9/10"),
      ("bytes=8-", "89", "bytes 8-9/10"),
      ("bytes=8-999", "89", "bytes 8-9/10"),
    ] {
      try await client.execute(uri: "/movie.mp4", method: .get, headers: [.range: range]) { response in
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == contentRange)
        #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == body)
      }
    }
    for range in ["bytes=10-", "bytes=-0", "bytes=9-2", "bytes=999999999999999999999999-", "bytes=1-2,4-5", "invalid"] {
      try await client.execute(uri: "/movie.mp4", method: .get, headers: [.range: range]) { response in
        #expect(response.status == .rangeNotSatisfiable)
        #expect(response.headers[.contentRange] == "bytes */10")
      }
    }
    try await client.execute(uri: "/movie.mp4", method: .head) { response in
      #expect(response.status == .ok)
      #expect(response.body.readableBytes == 0)
      #expect(response.headers[.contentLength] == "10")
    }
    try await client.execute(uri: "/", method: .get) { response in #expect(response.status == .ok) }
    try await client.execute(uri: "/%2e%2e/README.md", method: .get) { response in #expect(response.status != .ok) }
  }
}

@Test
func `preview root accepts equivalent directory URL representations`() async throws {
  let fixture = try TemporaryFixture()
  defer { fixture.remove() }
  try fixture.directory.at("index.html").write("root document")
  let path = fixture.directory.path
  for directory in [
    URL(fileURLWithPath: path, isDirectory: false),
    URL(fileURLWithPath: path, isDirectory: true),
    URL(fileURLWithPath: path + "/", isDirectory: true),
  ] {
    let server = PreviewServer(directory: directory, workspace: testWorkspace, port: 8769)
    try await server.application().test(.router) { client in
      try await client.execute(uri: "/", method: .get) { response in
        #expect(response.status == .ok, "Directory URL: \(directory.absoluteString)")
        #expect(String(decoding: response.body.readableBytesView, as: UTF8.self) == "root document")
      }
    }
  }
}
