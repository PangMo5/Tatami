import ComposableArchitecture
import SwiftUI
import TatamiKit

struct MenuBarContentView: View {
  let store: StoreOf<AppFeature>
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open Tatami") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }

    Divider()

    Button("Quit") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
