// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

// MARK: - DemoControl

/// Where a demo app listens for commands, and where `democtl` sends them.
///
/// The control channel owns app lifetime, activation and window count. Editable
/// work is driven through native controls and persisted by StoryRepository;
/// there is no remote command for jumping a view to a staged content state.
public enum DemoControl {

  // MARK: Public

  /// Directory holding one socket per running demo app.
  ///
  /// `DEMOLAB_CONTROL_DIR` overrides it so a lab run can keep its sockets with
  /// the rest of its state; the default keeps them out of the way when an app is
  /// opened by hand. A UNIX socket path has a hard `sun_path` limit, so both are
  /// kept short.
  public static var directory: URL {
    if let override = ProcessInfo.processInfo.environment["DEMOLAB_CONTROL_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("demolab", isDirectory: true)
  }

  public static func socket(for bundleIdentifier: String) -> URL {
    // The last identifier component keeps the path well inside `sun_path`.
    let leaf = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    return directory.appendingPathComponent("\(leaf).sock")
  }

  public static func ensureDirectory() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

}

// MARK: - DemoControlServer

/// A one-line-per-request UNIX socket server.
///
/// Deliberately tiny and synchronous: one connection at a time, one line in, one
/// line out. A demo app is never under load, and a simple accept loop cannot
/// reorder or coalesce commands the way a best-effort notification can.
public final class DemoControlServer: @unchecked Sendable {

  // MARK: Lifecycle

  /// - Parameter handler: runs on the main actor and returns the reply line.
  public init(bundleIdentifier: String, handler: @escaping @MainActor (DemoControlRequest) -> String) {
    self.bundleIdentifier = bundleIdentifier
    self.handler = handler
  }

  // MARK: Public

  public let bundleIdentifier: String

  /// Binds and starts accepting. A failure here is reported and then ignored:
  /// an app that cannot be scripted is still a perfectly good window to tile,
  /// and refusing to launch would break every scene that only needs the window.
  public func start() {
    do {
      try bind()
    } catch {
      FileHandle.standardError.write(
        Data("\(bundleIdentifier): control channel unavailable: \(error)\n".utf8)
      )
      return
    }
    let thread = Thread { [weak self] in self?.acceptLoop() }
    thread.name = "dev.PangMo5.DemoLab.control"
    thread.start()
  }

  public func stop() {
    lock.lock()
    let fd = listener
    listener = -1
    lock.unlock()
    if fd >= 0 { close(fd) }
    try? FileManager.default.removeItem(at: DemoControl.socket(for: bundleIdentifier))
  }

  // MARK: Private

  private let handler: @MainActor (DemoControlRequest) -> String
  private let lock = NSLock()
  private var listener: Int32 = -1

  private func bind() throws {
    try DemoControl.ensureDirectory()
    let url = DemoControl.socket(for: bundleIdentifier)
    // A socket left behind by a crashed run would make bind() fail with EADDRINUSE.
    try? FileManager.default.removeItem(at: url)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DemoControlError.socketFailed(errno) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = url.path
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else {
      close(fd)
      throw DemoControlError.pathTooLong(path)
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, capacity - 1)
      }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
    }
    guard bound == 0 else {
      close(fd)
      throw DemoControlError.bindFailed(errno, path)
    }
    guard Darwin.listen(fd, 8) == 0 else {
      close(fd)
      throw DemoControlError.listenFailed(errno)
    }
    lock.lock()
    listener = fd
    lock.unlock()
  }

  private func acceptLoop() {
    while true {
      lock.lock()
      let fd = listener
      lock.unlock()
      guard fd >= 0 else { return }

      let client = Darwin.accept(fd, nil, nil)
      guard client >= 0 else {
        if errno == EINTR { continue }
        return
      }
      defer { close(client) }

      guard let line = Self.readLine(from: client) else { continue }
      let request = DemoControlRequest(line: line)
      // Every command touches window or view state, so it has to land on the
      // main actor; the reply is only sent once it actually has.
      let reply = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(request) } }
      _ = (reply + "\n").withCString { Darwin.send(client, $0, strlen($0), 0) }
    }
  }

  private static func readLine(from fd: Int32) -> String? {
    var buffer = [UInt8]()
    var byte: UInt8 = 0
    while buffer.count < 4096 {
      let read = recv(fd, &byte, 1, 0)
      if read <= 0 { break }
      if byte == UInt8(ascii: "\n") { break }
      buffer.append(byte)
    }
    guard !buffer.isEmpty else { return nil }
    return String(decoding: buffer, as: UTF8.self)
  }

}

// MARK: - DemoControlRequest

public struct DemoControlRequest: Sendable {

  // MARK: Lifecycle

  public init(line: String) {
    let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    verb = fields.first.map { String($0).lowercased() } ?? ""
    argument = fields.count > 1 ? String(fields[1]) : ""
  }

  // MARK: Public

  public let verb: String
  /// Everything after the verb, unsplit, so a caption can contain spaces.
  public let argument: String

  public var integerArgument: Int? { Int(argument.trimmingCharacters(in: .whitespaces)) }

}

// MARK: - DemoControlError

public enum DemoControlError: Error, CustomStringConvertible {
  case socketFailed(Int32)
  case bindFailed(Int32, String)
  case listenFailed(Int32)
  case pathTooLong(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .socketFailed(let code): "socket() failed (errno \(code))"
    case .bindFailed(let code, let path): "bind(\(path)) failed (errno \(code))"
    case .listenFailed(let code): "listen() failed (errno \(code))"
    case .pathTooLong(let path): "socket path is too long for sun_path: \(path)"
    }
  }
}

// MARK: - DemoControlClient

/// The sending half, used by `democtl`.
public enum DemoControlClient {

  // MARK: Public

  public static func isListening(bundleIdentifier: String) -> Bool {
    (try? send("ping", to: bundleIdentifier)) != nil
  }

  @discardableResult
  public static func send(_ line: String, to bundleIdentifier: String) throws -> String {
    let url = DemoControl.socket(for: bundleIdentifier)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DemoControlError.socketFailed(errno) }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = url.path
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw DemoControlError.pathTooLong(path) }
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
      path.withCString { source in
        strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, capacity - 1)
      }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
    }
    guard connected == 0 else { throw DemoControlError.bindFailed(errno, path) }

    _ = (line + "\n").withCString { Darwin.send(fd, $0, strlen($0), 0) }

    var buffer = [UInt8](repeating: 0, count: 1024)
    let read = recv(fd, &buffer, buffer.count, 0)
    guard read > 0 else { return "" }
    return String(decoding: buffer[0..<read], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

}
