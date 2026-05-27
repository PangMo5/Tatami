import Foundation
import Testing
@testable import TatamiKit

@Suite("HotKey skhd encoding")
struct HotKeyTests {
  @Test
  func encodesAsSkhdString() throws {
    // keyCode 4 = h, modifiers 6144 = control(4096) + option(2048)
    let key = HotKey(carbonKeyCode: 4, carbonModifiers: 6144)
    #expect(key.displayString == "ctrl + alt - h")

    let data = try JSONEncoder().encode(key)
    #expect(String(data: data, encoding: .utf8) == "\"ctrl + alt - h\"")
  }

  @Test
  func roundTripsThroughString() throws {
    let key = HotKey(carbonKeyCode: 45, carbonModifiers: 256 + 512) // cmd+shift - n
    let data = try JSONEncoder().encode(key)
    let decoded = try JSONDecoder().decode(HotKey.self, from: data)
    #expect(decoded == key)
    #expect(key.displayString == "shift + cmd - n")
  }

  @Test
  func parsesLooseForm() {
    #expect(HotKey(parsing: "ctrl+alt+h") == HotKey(carbonKeyCode: 4, carbonModifiers: 6144))
    #expect(HotKey(parsing: "cmd - return") == HotKey(carbonKeyCode: 36, carbonModifiers: 256))
    #expect(HotKey(parsing: "left") == HotKey(carbonKeyCode: 123, carbonModifiers: 0))
  }

  @Test
  func decodesLegacyCarbonTable() throws {
    let json = #"{"carbonKeyCode":4,"carbonModifiers":6144}"#
    let decoded = try JSONDecoder().decode(HotKey.self, from: Data(json.utf8))
    #expect(decoded == HotKey(carbonKeyCode: 4, carbonModifiers: 6144))
  }

  @Test
  func rejectsUnknownKey() {
    #expect(HotKey(parsing: "cmd - boguskey") == nil)
  }
}
