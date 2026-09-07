// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// MARK: - DemoLaunchOptions

/// Launch-time overrides. Everything here has a fixed default in
/// ``DemoAppSpec`` so an app that Tatami auto-opens (no argv) still produces
/// exactly the same windows as one `democtl` launched.
public struct DemoLaunchOptions: Sendable, Equatable {

  // MARK: Lifecycle

  public init(windowCount: Int? = nil, frame: CGRect? = nil, variant: Int = 0) {
    self.windowCount = windowCount
    self.frame = frame
    self.variant = variant
  }

  // MARK: Public

  /// Parses `--windows N`, `--frame x,y,w,h`, and `--variant N`. Unknown
  /// arguments are rejected loudly: a typo in a scene file must not silently
  /// produce a different window count on camera.
  public static func parse(_ arguments: [String]) throws -> DemoLaunchOptions {
    var options = DemoLaunchOptions()
    var index = arguments.startIndex

    while index < arguments.endIndex {
      let argument = arguments[index]
      func value() throws -> String {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else {
          throw DemoLaunchError.missingValue(argument)
        }
        index = next
        return arguments[next]
      }

      switch argument {
      case "--windows":
        guard let count = Int(try value()), count >= 0, count <= 8 else {
          throw DemoLaunchError.invalidValue(argument)
        }
        options.windowCount = count

      case "--frame":
        let parts = try value().split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
          throw DemoLaunchError.invalidValue(argument)
        }
        options.frame = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])

      case "--variant":
        guard let variant = Int(try value()), variant >= 0 else {
          throw DemoLaunchError.invalidValue(argument)
        }
        options.variant = variant

      // LaunchServices hands `-psn_…` to apps opened through `open`.
      case let other where other.hasPrefix("-psn_"):
        break

      case let other:
        throw DemoLaunchError.unknownArgument(other)
      }

      index = arguments.index(after: index)
    }

    return options
  }

  public var windowCount: Int?
  public var frame: CGRect?
  /// Selects between fixed content variants (never random, never time-based).
  /// It shifts a window's title with its content, because both read one index.
  public var variant: Int

}

// MARK: - DemoLaunchError

public enum DemoLaunchError: Error, CustomStringConvertible {
  case unknownArgument(String)
  case missingValue(String)
  case invalidValue(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .unknownArgument(let name): "unknown argument: \(name)"
    case .missingValue(let name): "missing value for \(name)"
    case .invalidValue(let name): "invalid value for \(name)"
    }
  }
}

// MARK: - DemoAppHost

/// The AppKit shell every demo app runs on.
///
/// AppKit rather than a SwiftUI `App` on purpose: SwiftUI's scene restoration
/// reuses and repositions windows between launches, which is exactly the
/// non-determinism a repeatable recording cannot have. Here the window count,
/// titles, and frames are computed from fixed inputs only.
@MainActor
public enum DemoAppHost {

  /// Boots the app. Never returns.
  ///
  /// `content` receives stable window identity; the app owns its editable state.
  public static func run(
    _ id: DemoAppID,
    @ViewBuilder content: @escaping (DemoRenderContext) -> some View
  ) -> Never {
    let spec = DemoCatalog.spec(id)
    let arguments = Array(CommandLine.arguments.dropFirst())

    let options: DemoLaunchOptions
    do {
      options = try DemoLaunchOptions.parse(arguments)
    } catch {
      FileHandle.standardError.write(Data("\(spec.name): \(error)\n".utf8))
      exit(2)
    }

    let application = NSApplication.shared
    let delegate = DemoAppDelegate(spec: spec, options: options) { context in
      AnyView(content(context))
    }
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
    // `run()` does not return; this keeps the delegate alive for the compiler.
    withExtendedLifetime(delegate) {}
    exit(0)
  }

}

// MARK: - DemoAppDelegate

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

  // MARK: Lifecycle

  init(
    spec: DemoAppSpec,
    options: DemoLaunchOptions,
    content: @escaping (DemoRenderContext) -> AnyView
  ) {
    self.spec = spec
    self.options = options
    self.content = content
  }

  // MARK: Internal

  func applicationDidFinishLaunching(_: Notification) {
    buildMenu()
    let count = options.windowCount ?? spec.defaultWindowCount
    for _ in 0..<count { openWindow(nil) }
    NSApp.activate(ignoringOtherApps: true)
    startControlServer()
  }

  func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }

  /// Clicking the Dock icon of an app whose windows Tatami hid must not spawn
  /// an extra window — that would change the window count mid-take.
  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows, windows.isEmpty { openWindow(nil) }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    windows.removeAll { $0 === window }
    // Ordinals are never reused, so a window opened after a close keeps a
    // distinct title instead of colliding with the one that just went away.
  }

  /// Opens or closes windows until exactly `wanted` are on screen. Closing takes
  /// the most recently opened first, so the windows that remain keep the
  /// ordinals, titles and fixtures they already had.
  func setWindowCount(_ wanted: Int) {
    while windows.count > wanted, let last = windows.last {
      last.close()
      windows.removeAll { $0 === last }
    }
    while windows.count < wanted { openWindow(nil) }
  }

  @objc
  func openWindow(_: Any?) {
    let ordinal = nextOrdinal
    nextOrdinal += 1
    // Title and content read one index, so `--variant` shifts both. Split, a
    // window is titled after one fixture and renders another, and Tatami's
    // switcher and HUD show that title on camera.
    let contentIndex = options.variant + ordinal

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: spec.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = spec.windowTitle(at: contentIndex)
    // The tiler dictates every frame these windows ever have, so the SwiftUI
    // content gets no vote in their size. `sizingOptions` defaults to
    // `.standardBounds`, which pushes the content's minimum onto the window's
    // `contentMinSize`; AppKit then clamps the tiler's resize to it while the
    // accessibility write still reports success, so a refused tile reaches the
    // recording as a wrong frame with no error on either side.
    let hosting = NSHostingView(
      rootView: content(DemoRenderContext(ordinal: contentIndex))
    )
    hosting.sizingOptions = []
    window.contentView = hosting
    window.isReleasedWhenClosed = false
    // Native tabs make a tiling window manager see one AX window where the user
    // sees several; Tatami has a documented regression class around them.
    window.tabbingMode = .disallowed
    window.delegate = self
    requireAnyFrameIsAccepted(window, ordinal: ordinal)
    window.setFrame(frame(for: ordinal, of: window), display: true)
    // Stable AX identity so a driver can address "Editor window 2" without
    // depending on the localized title.
    window.setAccessibilityIdentifier("\(spec.bundleIdentifier).window.\(ordinal)")
    window.makeKeyAndOrderFront(nil)
    windows.append(window)
  }

  // MARK: Private

  let spec: DemoAppSpec
  var control: DemoControlServer?

  /// Windows currently on screen. A scene can grow or shrink this to film a
  /// window being opened or closed, which is what the tiler reacts to.
  var windowCount: Int { windows.count }

  private let options: DemoLaunchOptions
  private let content: (DemoRenderContext) -> AnyView

  /// The smallest content size a take can ask a window for. A four-way split
  /// of the 1920x1200 recording display is 286pt wide and `resize shrink` steps
  /// go under that, so anything a window refuses below this lands on camera.
  private static let smallestTile = CGSize(width: 200, height: 120)

  private var windows = [NSWindow]()
  /// Monotonic, so titles and AX identifiers stay unique for the whole session.
  private var nextOrdinal = 0

  /// Proves, before the window is ever on screen, that AppKit hands out any
  /// size the tiler asks for.
  ///
  /// A clamped resize is silent on both sides: AppKit stops at the window's
  /// `contentMinSize`, `AXUIElementSetAttributeValue` still returns success, and
  /// the only trace is a tile overlapping its neighbour in the recording.
  /// Quitting is the loudest signal a demo app has, and it beats shipping a take
  /// whose frames differ from the last one for no visible reason.
  private func requireAnyFrameIsAccepted(_ window: NSWindow, ordinal: Int) {
    // A minimum pushed by SwiftUI content only exists after a layout pass.
    window.layoutIfNeeded()
    window.setContentSize(Self.smallestTile)
    let granted = window.contentRect(forFrameRect: window.frame).size
    let honored = abs(granted.width - Self.smallestTile.width) < 0.5
      && abs(granted.height - Self.smallestTile.height) < 0.5
    guard !honored else { return }

    func describe(_ value: CGSize) -> String { String(format: "%.0fx%.0f", value.width, value.height) }
    let message = "\(spec.name): window \(ordinal) refused a \(describe(Self.smallestTile)) content size and "
      + "took \(describe(granted)) instead (contentMinSize \(describe(window.contentMinSize))). "
      + "A window that clamps the tiler records a wrong frame with no error anywhere."
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(3)
  }

  /// Deterministic placement: anchored to the *primary* screen's visible frame
  /// with a fixed step, never to a running window count (which drifts as windows
  /// open and close during a take). Tatami retiles managed windows immediately;
  /// this is what a **Leave As Is** window keeps.
  ///
  /// Deliberately not `NSScreen.main`: that is the screen holding the key
  /// window, so it follows whichever display the app that was active *before*
  /// the launch happened to be on, and two takes on one machine can then put the
  /// same untouched window on different displays.
  private func frame(for ordinal: Int, of window: NSWindow) -> CGRect {
    if let explicit = options.frame { return explicit }
    // `screens[0]` is the menu-bar screen; testing the origin pins the choice to
    // the display at (0, 0) whatever order the array comes back in.
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    let visible = primary?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 945)
    let step = CGFloat(ordinal % 4) * 36
    // `spec.windowSize` is a content size, which is how the window is created
    // above, and `setFrame` takes a frame rect. Without adding the title bar
    // back, every window's content is a title bar shorter than the catalog says.
    let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: spec.windowSize)).size
    let utility = spec.id == .monitor || spec.id == .notes
    let x = utility ? visible.maxX - size.width - 32 : visible.minX + 80 + step
    let y = utility ? visible.minY + 40 : visible.maxY - size.height - 60 - step
    return CGRect(x: x, y: max(visible.minY, y), width: size.width, height: size.height)
  }

  private func buildMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: String(localized: "Quit \(spec.name)"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: String(localized: "Edit"))
    editItem.submenu = editMenu
    let editActions: [(LocalizedStringResource, String, String)] = [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
      ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]
    for (title, selector, key) in editActions {
      editMenu.addItem(withTitle: String(localized: title), action: Selector(selector), keyEquivalent: key)
    }

    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: String(localized: "Window"))
    windowItem.submenu = windowMenu

    let newItem = NSMenuItem(
      title: String(localized: "New Window"),
      action: #selector(openWindow(_:)),
      keyEquivalent: "n"
    )
    newItem.target = self
    windowMenu.addItem(newItem)
    windowMenu.addItem(
      withTitle: String(localized: "Close"),
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    windowMenu.addItem(
      withTitle: String(localized: "Minimize"),
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: String(localized: "Zoom"),
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    // Exercises the native-fullscreen path Tatami has to detect and step out of.
    let fullscreenItem = NSMenuItem(title: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullscreenItem.keyEquivalentModifierMask = [.control, .command]
    windowMenu.addItem(fullscreenItem)
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

}

// MARK: - DemoRenderContext

/// Stable window identity. Editable content is owned by each app's views and
/// shared saved work lives in StoryRepository.
public struct DemoRenderContext: Equatable, Sendable {
  public init(ordinal: Int) { self.ordinal = ordinal }
  public let ordinal: Int
}

// MARK: - Control channel

extension DemoAppDelegate {

  /// Commands a scene can send. Every one is absolute, and every one is
  /// acknowledged, so the scene runner waits on a real answer rather than a
  /// sleep. See ``DemoControl``.
  func startControlServer() {
    let server = DemoControlServer(bundleIdentifier: spec.bundleIdentifier) { [weak self] request in
      guard let self else { return "err gone" }
      return handle(request)
    }
    server.start()
    control = server
  }

  private func handle(_ request: DemoControlRequest) -> String {
    switch request.verb {
    case "ping":
      return "ok \(spec.name) windows=\(windowCount)"

    case "windows":
      guard let wanted = request.integerArgument, wanted >= 0, wanted <= 8 else {
        return "err windows must be 0...8"
      }
      setWindowCount(wanted)
      return "ok windows=\(windowCount)"

    case "quit":
      // Reply first: the caller is waiting on this socket, and terminating
      // inside the handler would drop the acknowledgement.
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return "ok quitting"

    default:
      return "err unknown command \"\(request.verb)\""
    }
  }

}
