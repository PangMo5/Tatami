import Darwin
import Foundation
import TatamiCLIProtocol

/// Minimal blocking client for the Tatami app's Unix domain socket.
/// One connection per request — the server replies once and closes.
enum SocketClient {
  static func send(_ request: CLIMessage.Request) throws -> CLIMessage.Response {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Error.socket(errno) }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(CLIMessage.socketPath.utf8)
    withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
      pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
        for (i, byte) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: byte) }
        dst[pathBytes.count] = 0
      }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
        Darwin.connect(fd, sockAddr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      throw Error.connect(errno)
    }

    var data = try JSONEncoder().encode(request)
    data.append(0x0A)
    _ = data.withUnsafeBytes { ptr in
      Darwin.write(fd, ptr.baseAddress, ptr.count)
    }

    var responseBytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
      let n = Darwin.read(fd, &byte, 1)
      if n <= 0 { break }
      if byte == 0x0A { break }
      responseBytes.append(byte)
      if responseBytes.count > 65_536 { break }
    }

    guard !responseBytes.isEmpty else { throw Error.emptyResponse }
    return try JSONDecoder().decode(CLIMessage.Response.self, from: Data(responseBytes))
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case socket(Int32)
    case connect(Int32)
    case emptyResponse

    var description: String {
      switch self {
      case .socket(let code): "socket() failed (errno=\(code))"
      case .connect(let code):
        "Could not connect to Tatami at \(CLIMessage.socketPath) (errno=\(code)). Is the app running?"
      case .emptyResponse: "Empty response from Tatami app."
      }
    }
  }
}
