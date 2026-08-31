// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import TatamiCLIProtocol
import YYJSON

// MARK: - SocketServerClient

/// Accepts CLI connections on a Unix domain socket and exposes incoming
/// `Request`s as an `AsyncStream`. Each request carries a continuation
/// the caller fulfills with a `Response`; the connection is closed after
/// the response is written.
///
/// The implementation uses POSIX sockets directly (Darwin) rather than
/// Network.framework: Unix domain sockets via NWListener are awkward and
/// this is a low-traffic, blocking-accept loop on a background queue.
@DependencyClient
struct SocketServerClient: Sendable {
  /// A pending CLI request along with a one-shot reply continuation.
  struct Incoming: Sendable {
    init(
      request: CLIMessage.Request,
      reply: CLIReply,
    ) {
      self.request = request
      self.reply = reply
    }

    let request: CLIMessage.Request
    /// Claim and finish the connection's one-shot response slot.
    let reply: CLIReply
  }

  /// Start the listener at `path`. Idempotent. Calling twice does nothing.
  var start: @Sendable (_ path: String) async throws -> Void
  var requests: @Sendable () -> AsyncStream<Incoming> = { AsyncStream { _ in } }
}

// MARK: DependencyKey

extension SocketServerClient: DependencyKey {
  static let liveValue: SocketServerClient = {
    let server = SocketServer()
    return SocketServerClient(
      start: { path in try await server.start(path: path) },
      requests: { server.stream },
    )
  }()

  static let testValue = SocketServerClient(
    start: { _ in },
    requests: { AsyncStream { _ in } },
  )

  static let previewValue = testValue
}

extension DependencyValues {
  var socketServer: SocketServerClient {
    get { self[SocketServerClient.self] }
    set { self[SocketServerClient.self] = newValue }
  }
}

// MARK: - SocketServer

private actor SocketServer {

  // MARK: Lifecycle

  init() {
    var continuation: AsyncStream<SocketServerClient.Incoming>.Continuation!
    stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
  }

  // MARK: Internal

  let stream: AsyncStream<SocketServerClient.Incoming>

  func start(path: String) throws {
    guard listenFD == nil else { return }
    let rawFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard rawFD >= 0 else { throw SocketError.create(errno) }
    let descriptor = OwnedFileDescriptor(rawValue: rawFD)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      throw SocketError.pathTooLong
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
      pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
        for (i, byte) in pathBytes.enumerated() {
          dst[i] = CChar(bitPattern: byte)
        }
        dst[pathBytes.count] = 0
      }
    }

    Darwin.unlink(path)

    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
        Darwin.bind(rawFD, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let saved = errno
      throw SocketError.bind(saved)
    }

    guard Darwin.listen(rawFD, 5) == 0 else {
      let saved = errno
      throw SocketError.listen(saved)
    }

    listenFD = consume descriptor
    debugLog.log("App", "dev CLI socket listening at \(path)")

    let listenFD = rawFD
    let continuation = continuation
    // POSIX `accept`/`read` are blocking syscalls and must NOT run on the
    // Swift cooperative thread pool: a parked pool thread starves every
    // other async task because the pool is sized to the core count. Run
    // the accept loop on a dedicated `Thread`, and hand each accepted
    // connection to a concurrent libdispatch queue (which grows its own
    // worker threads as workers block) so a slow reply can't wedge the
    // accept loop.
    let connections = DispatchQueue(
      label: "dev.PangMo5.Tatami.socket-connections",
      attributes: .concurrent,
    )
    let acceptThread = Thread {
      Self.acceptLoop(
        listenFD: listenFD,
        continuation: continuation,
        connections: connections,
      )
    }
    acceptThread.name = "dev.PangMo5.Tatami.socket-accept"
    acceptThread.qualityOfService = .utility
    acceptThread.start()
  }

  // MARK: Private

  @Dependency(\.debugLog) private var debugLog

  private let continuation: AsyncStream<SocketServerClient.Incoming>.Continuation
  private var listenFD: OwnedFileDescriptor?

  private static func acceptLoop(
    listenFD: Int32,
    continuation: AsyncStream<SocketServerClient.Incoming>.Continuation,
    connections: DispatchQueue,
  ) {
    while true {
      let clientFD = Darwin.accept(listenFD, nil, nil)
      if clientFD < 0 {
        if errno == EINTR { continue }
        logger.error("accept failed: \(errno) — exiting accept loop")
        return
      }
      connections.async {
        handleConnection(clientFD: clientFD, continuation: continuation)
      }
    }
  }

  private static func handleConnection(
    clientFD: Int32,
    continuation: AsyncStream<SocketServerClient.Incoming>.Continuation,
  ) {
    let descriptor = OwnedFileDescriptor(rawValue: clientFD)
    var noSigPipe: Int32 = 1
    guard
      Darwin.setsockopt(
        descriptor.rawValue,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size),
      ) == 0
    else {
      logger.error("setsockopt(SO_NOSIGPIPE) failed: \(errno)")
      return
    }
    guard let line = readLine(fd: descriptor.rawValue), !line.isEmpty else { return }
    guard
      let data = line.data(using: .utf8),
      let request = try? YYJSONDecoder().decode(CLIMessage.Request.self, from: data)
    else {
      writeResponse(fd: descriptor.rawValue, response: .failure("Invalid request format"))
      return
    }

    // Hand the request to the reducer and park *this* connection thread
    // until the reply closure fires. The semaphore is signalled from the
    // reply, so the thread sleeps (no CPU-burning poll) until woken or the
    // 5s deadline elapses.
    let responseBox = ResponseBox()
    let replied = DispatchSemaphore(value: 0)
    let incoming = SocketServerClient.Incoming(
      request: request,
      reply: CLIReply(
        claim: { responseBox.claim() },
        finish: { response in
          if responseBox.finish(response) { replied.signal() }
        },
        respond: { response in
          let responded = responseBox.respond(response)
          if responded { replied.signal() }
          return responded
        },
      ),
    )
    continuation.yield(incoming)

    if replied.wait(timeout: .now() + 5) == .timedOut {
      switch responseBox.expirePending() {
      case .expired:
        writeResponse(fd: descriptor.rawValue, response: .failure("Timeout"))
        return

      case .claimed:
        // Config mutations claim only at the final atomic replacement. Allow
        // a bounded grace period for that syscall and reducer acknowledgment;
        // if it still does not finish, report an explicitly unknown outcome
        // instead of leaking this worker forever or claiming a false failure.
        if replied.wait(timeout: .now() + 15) == .timedOut {
          switch responseBox.expireClaimed() {
          case .expired,
               .claimed:
            writeResponse(
              fd: descriptor.rawValue,
              response: .failure(
                "Command outcome is unknown; inspect current state before retrying"
              ),
            )
            return

          case .finished:
            break
          }
        }

      case .finished:
        break
      }
    }
    writeResponse(fd: descriptor.rawValue, response: responseBox.value ?? .failure("Timeout"))
  }

  private static func readLine(fd: Int32) -> String? {
    var buffer = [UInt8]()
    var byte: UInt8 = 0
    while true {
      let n = Darwin.read(fd, &byte, 1)
      if n <= 0 { break }
      if byte == 0x0A { break }
      buffer.append(byte)
      if buffer.count > 16_384 { return nil }
    }
    return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
  }

  private static func writeResponse(fd: Int32, response: CLIMessage.Response) {
    guard var data = try? YYJSONEncoder().encode(response) else { return }
    data.append(0x0A)
    // Loop over short writes (signal interruption) — a truncated JSON
    // line would fail to decode on the CLI side.
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
      guard let base = ptr.baseAddress else { return }
      var offset = 0
      while offset < ptr.count {
        let written = Darwin.write(fd, base.advanced(by: offset), ptr.count - offset)
        if written > 0 {
          offset += written
        } else if written < 0, errno == EINTR {
          continue
        } else {
          return
        }
      }
    }
  }

}

// MARK: - OwnedFileDescriptor

/// Sole owner of a POSIX file descriptor. Moving this value transfers close
/// responsibility; it cannot be copied into two owners that both close the
/// same descriptor. Scope exit also closes every early-return/error path.
private struct OwnedFileDescriptor: ~Copyable {
  deinit {
    Darwin.close(rawValue)
  }

  let rawValue: Int32
}

// MARK: - ResponseBox

private final class ResponseBox: @unchecked Sendable {

  // MARK: Internal

  enum Expiration {
    case claimed
    case expired
    case finished
  }

  var value: CLIMessage.Response? {
    lock.lock()
    defer { lock.unlock() }
    guard case .finished(let response) = state else { return nil }
    return response
  }

  func claim() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard case .pending = state else { return false }
    state = .claimed
    return true
  }

  func finish(_ response: CLIMessage.Response) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard case .claimed = state else { return false }
    state = .finished(response)
    return true
  }

  func respond(_ response: CLIMessage.Response) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .pending,
         .claimed:
      state = .finished(response)
      return true

    case .expired,
         .finished:
      return false
    }
  }

  func expirePending() -> Expiration {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .pending:
      state = .expired
      return .expired

    case .claimed:
      return .claimed

    case .finished:
      return .finished

    case .expired:
      return .expired
    }
  }

  func expireClaimed() -> Expiration {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .claimed:
      state = .expired
      return .expired

    case .finished:
      return .finished

    case .pending:
      return .claimed

    case .expired:
      return .expired
    }
  }

  // MARK: Private

  private enum State {
    case claimed
    case expired
    case finished(CLIMessage.Response)
    case pending
  }

  private let lock = NSLock()
  private var state = State.pending

}

// MARK: - SocketError

enum SocketError: Error, Sendable {
  case create(Int32)
  case bind(Int32)
  case listen(Int32)
  case pathTooLong
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "SocketServer")
