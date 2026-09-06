// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import DemoAppKit
import SwiftUI

// MARK: - OverlayMode

/// How much of the narration the overlay is allowed to draw.
///
/// `democtl` can emit the captions as an ASS subtitle sidecar instead of burning
/// them into the frame, so a take can be restyled or translated without being
/// re-shot. When it does, it turns the live captions off here rather than asking
/// every scene to stop sending them: the scene file stays the one source of the
/// narration text whichever way it is rendered.
enum OverlayMode: String, CaseIterable {
  /// Chapter, caption and keycaps. What a take renders unless told otherwise.
  case all
  /// Keycaps only. The captions are coming from the sidecar instead.
  case keys
  /// Nothing at all, for a take that wants untouched pixels.
  case off

  // MARK: Internal

  var showsChapter: Bool { self == .all }

  var showsCaption: Bool { self == .all }

  var showsKeys: Bool { self != .off }
}

// MARK: - OverlayModel

/// What the overlay is currently saying. Every field is set explicitly by a
/// scene and never expires on its own: a caption that faded on a timer would
/// land on a different frame in every take.
///
/// `mode` hides text, it never discards it. A scene may change the mode part way
/// through a run, and going back to `.all` has to show whatever was last set
/// rather than a blank layer.
@MainActor
final class OverlayModel: ObservableObject {
  @Published var chapter = ""
  @Published var caption = ""
  @Published var detail = ""
  @Published var keys = ""
  @Published var mode = OverlayMode.all
}

// MARK: - OverlayApp

/// A click-through, always-on-top layer that narrates the demo.
///
/// A tiling demo is hard to follow without it. The viewer sees three windows
/// rearrange and has no idea whether a key was pressed, which one, or why that
/// key was the right thing to reach for. This draws the keystroke and one line
/// of reasoning over the top.
///
/// Three properties keep it out of the demo's way:
///
/// - It is an accessory app (`LSUIElement`) on the `.screenSaver` window level,
///   so it is never in the Dock, never in the app switcher, and always above the
///   tiles.
/// - It ignores mouse events entirely, so it cannot steal a click.
/// - Its bundle id goes in Tatami's `settings.visibility.overlayAwareApps`,
///   which is precisely the feature for an app that owns persistent elevated
///   controls: Tatami then excludes its window from focus, cycling, layout and
///   membership instead of trying to tile the narration.
@MainActor
final class OverlayApp: NSObject, NSApplicationDelegate {

  // MARK: Internal

  func applicationDidFinishLaunching(_: Notification) {
    rebuildPanels()
    // A display change (or a workspace switch onto another screen) must not
    // leave the narration stranded on a screen that is gone.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.rebuildPanels() }
    }
    startControl()
  }

  // MARK: Private

  private let model = OverlayModel()
  private var panels = [NSPanel]()
  private var control: DemoControlServer?

  /// One panel per screen: a scene can caption a two-display take without the
  /// text living on only one of them.
  private func rebuildPanels() {
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()

    for screen in NSScreen.screens {
      let panel = NSPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.isFloatingPanel = true
      panel.level = .screenSaver
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      // Narration must never take focus or eat a click meant for a window.
      panel.ignoresMouseEvents = true
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
      panel.hidesOnDeactivate = false
      let hosting = NSHostingView(rootView: OverlayView(model: model))
      hosting.sizingOptions = []
      panel.contentView = hosting
      panel.setFrame(screen.frame, display: true)
      panel.orderFrontRegardless()
      panels.append(panel)
    }
  }

  /// What the panels are doing, in one line: how many, how many are on screen,
  /// and whether the app itself is hidden. Every one of those has been the
  /// reason narration failed to appear in a take.
  private func panelReport() -> String {
    let visible = panels.filter(\.isVisible).count
    return "panels=\(visible)/\(panels.count) hidden=\(NSApp.isHidden)"
  }

  /// Puts the panels back on top, and does it on every beat rather than once at
  /// launch.
  ///
  /// Ordering front once was not enough. Panels reported themselves visible for
  /// a whole take while the first two keycasts were missing from the recording:
  /// the demo's own windows had all been created after the panels were ordered
  /// front, and until the panels were ordered again the capture composited them
  /// underneath. Narration is only ever asked to draw a couple of dozen times in
  /// a take, so re-asserting the one thing it must be true of costs nothing.
  private func present() {
    for panel in panels { panel.orderFrontRegardless() }
  }

  private func startControl() {
    let server = DemoControlServer(bundleIdentifier: DemoCatalog.overlayBundleIdentifier) { [weak self] request in
      guard let self else { return "err gone" }
      return handle(request)
    }
    server.start()
    control = server
  }

  private func handle(_ request: DemoControlRequest) -> String {
    switch request.verb {
    case "ping":
      return "ok Overlay \(panelReport()) mode=\(model.mode.rawValue)"

    case "chapter":
      model.chapter = request.argument
      present()
      return "ok chapter"

    case "caption":
      // `caption <headline> | <detail>`: the headline says what is happening,
      // the optional detail after the pipe says why it is worth doing.
      let parts = request.argument.components(separatedBy: " | ")
      model.caption = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
      model.detail = parts.count > 1
        ? parts.dropFirst().joined(separator: " | ").trimmingCharacters(in: .whitespaces)
        : ""
      present()
      return "ok caption"

    case "keys":
      model.keys = request.argument
      present()
      // Reported back rather than assumed: a keycast that is on screen for
      // 1.4 seconds is the one piece of narration a take cannot re-render
      // afterwards, so `democtl` gets told whether the panel was actually able
      // to draw it.
      return "ok keys \(panelReport())"

    case "mode":
      // Rejected rather than coerced. A misspelled mode that quietly fell back
      // to `all` would burn captions into a take that is also shipping them as a
      // sidecar, and nothing would say so until the doubled text was on screen.
      let raw = request.argument.trimmingCharacters(in: .whitespaces).lowercased()
      guard let mode = OverlayMode(rawValue: raw) else {
        let known = OverlayMode.allCases.map(\.rawValue).joined(separator: ", ")
        return "err mode must be one of \(known), got \"\(request.argument)\""
      }
      model.mode = mode
      present()
      return "ok mode=\(mode.rawValue)"

    case "clear":
      // Text only. The mode is a property of how this run is being rendered, not
      // of the current beat, so clearing a caption must not switch burned-in
      // captions back on behind `democtl`'s back.
      model.chapter = ""
      model.caption = ""
      model.detail = ""
      model.keys = ""
      return "ok clear"

    case "quit":
      DispatchQueue.main.async { NSApp.terminate(nil) }
      return "ok quitting"

    default:
      return "err unknown command \"\(request.verb)\""
    }
  }

}

// MARK: - OverlayView

/// Everything here is sized for video, not for a document: a 1920x1200 take is
/// often watched in a half-width embed, where anything set at reading sizes is
/// gone before it can be read. Type is large, cards are wide, and contrast is
/// carried by a solid dark fill plus a hairline edge so the narration survives
/// both a white editor and a black terminal in the same frame.
private struct OverlayView: View {

  // MARK: Internal

  @ObservedObject var model: OverlayModel

  var body: some View {
    VStack(spacing: 0) {
      if model.mode.showsChapter, !model.chapter.isEmpty {
        // Top left, not top centre. Tatami draws its own on-screen feedback at
        // the top centre of the active display, and that feedback is one of the
        // things being demonstrated, so the whole top centre belongs to Tatami.
        // A pill parked there covers the very thing the take is about.
        HStack(spacing: 0) {
          chapter
          Spacer(minLength: 0)
        }
        .padding(.leading, 44)
        .padding(.top, 46)
      }

      Spacer(minLength: 0)

      HStack(alignment: .bottom, spacing: 18) {
        Spacer(minLength: 0)
        if model.mode.showsCaption, !model.caption.isEmpty { caption }
        Spacer(minLength: 0)
      }
      // A symmetric gutter, so the card stays centred on the screen and still
      // cannot grow underneath the keycaps on a display narrower than the 1920
      // the sizes above are tuned for. Measuring the caps instead would make the
      // card width depend on the chord, and the card would jump between beats.
      .padding(.horizontal, 340)
      .overlay(alignment: .bottomTrailing) {
        if model.mode.showsKeys, !model.keys.isEmpty {
          KeycapRow(chord: model.keys)
            .padding(.trailing, 44)
            .padding(.bottom, burnedCaptionInset)
        }
      }
      .padding(.bottom, 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // The narration is drawn onto a fully transparent layer; nothing here may
    // tint the demo underneath it.
    .background(Color.clear)
  }

  // MARK: Private

  /// Room left at the bottom for a caption this overlay is *not* drawing.
  ///
  /// In `all` the caps sit beside the live card and the layout already keeps
  /// them apart. In `keys` the card is coming from the ASS sidecar and will be
  /// burned into these very pixels, so the space it will occupy has to be
  /// reserved here or the caps land on top of it. They did: a take showed
  /// `⌃` sitting on the right edge of the burned card.
  ///
  /// The number is the sidecar's own geometry, which is why it is spelled out
  /// rather than eyeballed: `Caption` is two lines at 54 and 38 with a
  /// `MarginV` of 84, all measured against a 1200pt-tall frame.
  private var burnedCaptionInset: CGFloat {
    model.mode.showsCaption ? 0 : 150
  }

  private var chapter: some View {
    Text(model.chapter)
      .font(.system(size: 19, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 22)
      .padding(.vertical, 11)
      .background(
        Capsule(style: .continuous)
          .fill(Color.black.opacity(0.82))
          .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.20), lineWidth: 1))
      )
  }

  private var caption: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(model.caption)
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.white)
      if !model.detail.isEmpty {
        // Dimmed enough to read as the secondary line, bright enough that it is
        // still legible where the card sits over a white editor window.
        Text(model.detail)
          .font(.system(size: 20, weight: .regular))
          .foregroundStyle(.white.opacity(0.88))
      }
    }
    .multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: 1000, alignment: .leading)
    .padding(.horizontal, 34)
    .padding(.vertical, 24)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.black.opacity(0.82))
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        )
    )
  }

}

// MARK: - KeycapRow

/// Renders a Tatami shortcut string as keycaps.
///
/// The spelling-to-glyph rules live in `KeyChordFormatter` because the burned
/// `.ass` sidecar has to print the very same caps: when the two disagreed, a
/// burned take showed a literal `ctrl + alt - l` sitting under this row's
/// `⌃ ⌥ L`.
private struct KeycapRow: View {

  let chord: String

  var body: some View {
    HStack(spacing: 10) {
      ForEach(Array(KeyChordFormatter.caps(from: chord).enumerated()), id: \.offset) { _, cap in
        Text(cap)
          .font(.system(size: 32, weight: .medium, design: cap.count > 2 ? .rounded : .default))
          .foregroundStyle(.white)
          .frame(minWidth: 58, minHeight: 58)
          .padding(.horizontal, cap.count > 2 ? 16 : 0)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(Color.black.opacity(0.82))
              .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .strokeBorder(Color.white.opacity(0.30), lineWidth: 1.5)
              )
          )
      }
    }
  }

}

// MARK: - Entry

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { OverlayApp() }
application.delegate = delegate
// Accessory, not regular: no Dock tile, no menu bar, nothing in the app
// switcher. The overlay is scenery, not an app the demo is about.
application.setActivationPolicy(.accessory)
application.run()
