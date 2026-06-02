import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import OSLog
import TatamiCLIProtocol
import YYJSON

/// Accepts CLI connections on a Unix domain socket and exposes incoming
/// `Request`s as an `AsyncStream`. Each request carries a continuation
/// the caller fulfills with a `Response`; the connection is closed after
/// the response is written.
///
/// The implementation uses POSIX sockets directly (Darwin) rather than
/// Network.framework: Unix domain sockets via NWListener are awkward and
/// this is a low-traffic, blocking-accept loop on a background queue.
@DependencyClient
public struct SocketServerClient: Sendable {
  /// Start the listener at `path`. Idempotent — calling twice does nothing.
  public var start: @Sendable (_ path: String) async throws -> Void
  public var stop: @Sendable () async -> Void
  public var requests: @Sendable () -> AsyncStream<Incoming> = { AsyncStream { _ in } }

  /// A pending CLI request along with a one-shot reply continuation.
  public struct Incoming: Sendable {
    public let request: CLIMessage.Request
    /// Send a response. May only be invoked once.
    public let reply: @Sendable (CLIMessage.Response) -> Void

    public init(
      request: CLIMessage.Request,
      reply: @escaping @Sendable (CLIMessage.Response) -> Void
    ) {
      self.request = request
      self.reply = reply
    }
  }
}

extension SocketServerClient: DependencyKey {
  public static let liveValue: SocketServerClient = {
    let server = SocketServer()
    return SocketServerClient(
      start: { path in try await server.start(path: path) },
      stop: { await server.stop() },
      requests: { server.stream }
    )
  }()

  public static let testValue = SocketServerClient(
    start: { _ in },
    stop: {},
    requests: { AsyncStream { _ in } }
  )

  public static let previewValue = testValue
}

extension DependencyValues {
  public var socketServer: SocketServerClient {
    get { self[SocketServerClient.self] }
    set { self[SocketServerClient.self] = newValue }
  }
}

private actor SocketServer {
  let stream: AsyncStream<SocketServerClient.Incoming>
  private let continuation: AsyncStream<SocketServerClient.Incoming>.Continuation
  private var listenFD: Int32 = -1
  private var isRunning = false

  init() {
    var continuation: AsyncStream<SocketServerClient.Incoming>.Continuation!
    self.stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
    self.continuation = continuation
  }

  func start(path: String) throws {
    guard !isRunning else { return }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.create(errno) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
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
        Darwin.bind(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let saved = errno
      Darwin.close(fd)
      throw SocketError.bind(saved)
    }

    guard Darwin.listen(fd, 5) == 0 else {
      let saved = errno
      Darwin.close(fd)
      throw SocketError.listen(saved)
    }

    listenFD = fd
    isRunning = true
    logger.info("SocketServer listening at \(path)")

    let listenFD = fd
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
      attributes: .concurrent
    )
    let acceptThread = Thread {
      Self.acceptLoop(
        listenFD: listenFD,
        continuation: continuation,
        connections: connections
      )
    }
    acceptThread.name = "dev.PangMo5.Tatami.socket-accept"
    acceptThread.qualityOfService = .utility
    acceptThread.start()
  }

  func stop() {
    guard isRunning else { return }
    Darwin.close(listenFD)
    listenFD = -1
    isRunning = false
    continuation.finish()
    logger.info("SocketServer stopped")
  }

  private static func acceptLoop(
    listenFD: Int32,
    continuation: AsyncStream<SocketServerClient.Incoming>.Continuation,
    connections: DispatchQueue
  ) {
    while true {
      let clientFD = Darwin.accept(listenFD, nil, nil)
      if clientFD < 0 {
        if errno == EINTR { continue }
        logger.info("accept failed: \(errno) — exiting accept loop")
        return
      }
      connections.async {
        handleConnection(clientFD: clientFD, continuation: continuation)
      }
    }
  }

  private static func handleConnection(
    clientFD: Int32,
    continuation: AsyncStream<SocketServerClient.Incoming>.Continuation
  ) {
    defer { Darwin.close(clientFD) }
    guard let line = readLine(fd: clientFD), !line.isEmpty else { return }
    guard let data = line.data(using: .utf8),
          let request = try? YYJSONDecoder().decode(CLIMessage.Request.self, from: data)
    else {
      writeResponse(fd: clientFD, response: .failure("Invalid request format"))
      return
    }

    // Hand the request to the reducer and park *this* connection thread
    // until the reply closure fires. The semaphore is signalled from the
    // reply, so the thread sleeps (no CPU-burning poll) until woken or the
    // 5s deadline elapses.
    let responseBox = ResponseBox()
    let replied = DispatchSemaphore(value: 0)
    let incoming = SocketServerClient.Incoming(request: request) { response in
      responseBox.set(response)
      replied.signal()
    }
    continuation.yield(incoming)

    if replied.wait(timeout: .now() + 5) == .timedOut {
      writeResponse(fd: clientFD, response: .failure("Timeout"))
      return
    }
    writeResponse(fd: clientFD, response: responseBox.value ?? .failure("Timeout"))
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
    _ = data.withUnsafeBytes { ptr in
      Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
  }
}

private final class ResponseBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: CLIMessage.Response?

  var value: CLIMessage.Response? {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }

  func set(_ response: CLIMessage.Response) {
    lock.lock()
    defer { lock.unlock() }
    _value = response
  }
}

public enum SocketError: Error, Sendable {
  case create(Int32)
  case bind(Int32)
  case listen(Int32)
  case pathTooLong
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "SocketServer")
