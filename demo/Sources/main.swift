// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

/// One staged mock app for recording Tatami promo footage. The build ships
/// these as *separate* apps
/// (distinct bundle ids, same binary), so Tatami can assign each to its own
/// workspace, float it, etc., reproducing the full website demo flow.
///
/// - Launch opens this app's window (its panel tiles itself).
/// - **⌘N** opens another window of the same app (same-app multi-window tile).
/// - **⌘W** closes the focused window (show the survivors re-tiling).
///
/// Open the Code apps in sequence to recreate the dwindle reveal.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

  // MARK: Internal

  func applicationDidFinishLaunching(_: Notification) {
    buildMenu()
    openWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc
  func openWindow(_: Any?) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: kind.size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false,
    )
    window.title = kind.title
    window.contentView = NSHostingView(rootView: kind.view)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    // Cascade so the windows look free-floating until Tatami tiles them.
    let offset = CGFloat(windows.count) * 28
    window.cascadeTopLeft(from: NSPoint(x: 140 + offset, y: 760 - offset))
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
  }

  // MARK: Private

  private let kind = DemoApp.current
  private var windows = [NSWindow]()

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: "Quit Tatami Demo",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q",
    )

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    let newItem = NSMenuItem(
      title: "New Window",
      action: #selector(openWindow(_:)),
      keyEquivalent: "n",
    )
    newItem.target = self
    windowMenu.addItem(newItem)
    windowMenu.addItem(
      withTitle: "Close",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w",
    )

    NSApp.mainMenu = mainMenu
  }

}

// Program entry runs on the main thread, so adopting the main actor here is
// sound — and `run()` never returns, so the delegate stays retained.
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
}
