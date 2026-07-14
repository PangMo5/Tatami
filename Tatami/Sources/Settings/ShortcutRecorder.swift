import AppKit
import SwiftUI
import TatamiKit

// MARK: - ShortcutRecorder

/// A compact shortcut recorder field. Shows the combo with stable
/// English/QWERTY glyphs (e.g. `⌘S`) regardless of the active keyboard
/// layout, and records on a single click even when its window isn't key
/// (via `acceptsFirstMouse`) — which matters for this menu-bar
/// (LSUIElement) app. Replaces `KeyboardShortcuts.Recorder`, which tore
/// recording down whenever the Settings window wasn't key.
struct ShortcutRecorder: View {
  let hotKey: HotKey?
  /// Returns the name of another action already bound to a candidate combo,
  /// or nil if it's free (the recorder's own current key reads as free).
  var conflict: (HotKey) -> String? = { _ in nil }
  /// Fires `true` when the field starts capturing and `false` when it
  /// stops (committed or cancelled). The owner suspends the global hotkeys
  /// while it's `true` so the combo being typed doesn't fire its action.
  var onRecordingChanged: (Bool) -> Void = { _ in }
  let onChange: (HotKey?) -> Void

  var body: some View {
    HStack(spacing: 4) {
      field
        .frame(width: 150, height: 24)

      Button {
        onChange(nil)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear shortcut")
      .opacity(hotKey == nil ? 0 : 1)
      .disabled(hotKey == nil)
    }
  }

  // The capsule fill: Liquid Glass on macOS 26+, a material fallback below
  // (matching WorkspaceHUDClient's availability split).
  @ViewBuilder
  private var field: some View {
    let representable = RecorderRepresentable(
      hotKey: hotKey,
      conflict: conflict,
      onRecordingChanged: onRecordingChanged,
      onChange: onChange
    )
    if #available(macOS 26.0, *) {
      representable.glassEffect(.regular, in: Capsule())
    } else {
      representable.background(.ultraThinMaterial, in: Capsule())
    }
  }
}

// MARK: - ComboCapsule

/// A read-only display of a derived shortcut combo (e.g. `⌃⌥D`). Deliberately
/// *not* capsule/glass styled like `ShortcutRecorder` — it renders as plain
/// secondary text (like a menu's shortcut hint) so it reads as a fixed value
/// you can't edit here. The parts live elsewhere: the modifier in Workspace
/// Keys, the key in the workspace's own settings; the recorder beside it
/// overrides the whole thing.
struct ComboCapsule: View {
  let text: String
  var dimmed = false

  var body: some View {
    Text(text.isEmpty ? "—" : text)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .frame(width: 96, height: 24)
      .opacity(dimmed ? 0.5 : 1)
  }
}

// MARK: - KeyEquivalentRecorder

/// A recorder for a single-character key equivalent (the switch modifier is
/// global, so only the bare key is captured). Looks like `ShortcutRecorder`:
/// a capsule showing the effective combo (e.g. `⌃⌥D`), click to capture one
/// key, with conflict detection and a clear button.
struct KeyEquivalentRecorder: View {
  let key: String?
  /// The switch-modifier glyphs shown before the key (e.g. `⌃⌥`).
  let modifierSymbols: String
  /// Conflict title for a candidate key char, or nil if free.
  var conflict: (String) -> String? = { _ in nil }
  var onRecordingChanged: (Bool) -> Void = { _ in }
  let onChange: (String?) -> Void

  var body: some View {
    HStack(spacing: 4) {
      field
        .frame(width: 96, height: 24)

      Button {
        onChange(nil)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear key")
      .opacity(key == nil ? 0 : 1)
      .disabled(key == nil)
    }
  }

  @ViewBuilder
  private var field: some View {
    let representable = KeyCapRepresentable(
      key: key,
      modifierSymbols: modifierSymbols,
      conflict: conflict,
      onRecordingChanged: onRecordingChanged,
      onChange: onChange
    )
    if #available(macOS 26.0, *) {
      representable.glassEffect(.regular, in: Capsule())
    } else {
      representable.background(.ultraThinMaterial, in: Capsule())
    }
  }
}

private struct KeyCapRepresentable: NSViewRepresentable {
  let key: String?
  let modifierSymbols: String
  let conflict: (String) -> String?
  let onRecordingChanged: (Bool) -> Void
  let onChange: (String?) -> Void

  func makeNSView(context _: Context) -> KeyCapField {
    let field = KeyCapField()
    field.onChange = onChange
    field.conflict = conflict
    field.onRecordingChanged = onRecordingChanged
    field.modifierSymbols = modifierSymbols
    field.key = key
    return field
  }

  func updateNSView(_ field: KeyCapField, context _: Context) {
    field.onChange = onChange
    field.conflict = conflict
    field.onRecordingChanged = onRecordingChanged
    field.modifierSymbols = modifierSymbols
    if !field.isRecording {
      field.key = key
    }
  }
}

final class KeyCapField: NSView {
  var onChange: ((String?) -> Void)?
  var conflict: ((String) -> String?)?
  var onRecordingChanged: ((Bool) -> Void)?
  var modifierSymbols = "" { didSet { needsDisplay = true } }

  var key: String? { didSet { needsDisplay = true } }

  /// Local keyDown monitor active only while recording. A bare special key
  /// (Delete, arrows…) inside a SwiftUI Form/List is otherwise eaten by the
  /// responder chain before reaching `keyDown`; the monitor intercepts every
  /// keyDown app-wide and consumes the captured one.
  private var monitor: Any?

  private(set) var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      needsDisplay = true
      onRecordingChanged?(isRecording)
    }
  }

  override var acceptsFirstResponder: Bool { true }
  override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 24) }
  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
  override func becomeFirstResponder() -> Bool { true }

  override func resignFirstResponder() -> Bool {
    stopRecording()
    return true
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { stopRecording() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func mouseDown(with _: NSEvent) {
    window?.makeFirstResponder(self)
    startRecording()
  }

  private func startRecording() {
    guard monitor == nil else { return }
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, self.isRecording else { return event }
      return self.record(event) ? nil : event
    }
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    isRecording = false
  }

  /// Capture one bare key (modifiers ignored — the switch modifier is global).
  /// Returns true when the event was consumed.
  private func record(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape cancels.
      stopRecording()
      return true
    }
    guard let name = HotKey.keyName(for: Int(event.keyCode)) else {
      NSSound.beep()
      return true
    }
    if let owner = conflict?(name) {
      NSSound.beep()
      stopRecording()
      showConflict(owner)
      return true
    }
    key = name
    onChange?(name)
    stopRecording()
    return true
  }

  private var conflictResetTask: Task<Void, Never>?
  private var conflictText: String? { didSet { needsDisplay = true } }

  private func showConflict(_ owner: String) {
    conflictText = "In use: \(owner)"
    conflictResetTask?.cancel()
    conflictResetTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled, let self else { return }
      conflictText = nil
    }
  }

  override func draw(_: NSRect) {
    if isRecording {
      let ring = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1, dy: 1),
        xRadius: bounds.height / 2,
        yRadius: bounds.height / 2
      )
      ring.lineWidth = 2
      NSColor.controlAccentColor.setStroke()
      ring.stroke()
    }

    let text: String
    let color: NSColor
    let bold: Bool
    if let conflictText {
      text = conflictText
      color = .systemOrange
      bold = true
    } else if isRecording {
      text = "Press a key\u{2026}"
      color = .secondaryLabelColor
      bold = false
    } else if let key {
      text = modifierSymbols + HotKey.keySymbol(forName: key)
      color = .labelColor
      bold = true
    } else {
      text = "Set key"
      color = .secondaryLabelColor
      bold = false
    }

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
    let nsText = text as NSString
    let height = nsText.size(withAttributes: attributes).height
    nsText.draw(
      in: NSRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width - 12, height: height),
      withAttributes: attributes
    )
  }
}

// MARK: - RecorderRepresentable

private struct RecorderRepresentable: NSViewRepresentable {
  let hotKey: HotKey?
  let conflict: (HotKey) -> String?
  let onRecordingChanged: (Bool) -> Void
  let onChange: (HotKey?) -> Void

  func makeNSView(context _: Context) -> RecorderField {
    let field = RecorderField()
    field.onChange = onChange
    field.conflict = conflict
    field.onRecordingChanged = onRecordingChanged
    field.hotKey = hotKey
    return field
  }

  func updateNSView(_ field: RecorderField, context _: Context) {
    field.onChange = onChange
    field.conflict = conflict
    field.onRecordingChanged = onRecordingChanged
    // Don't clobber an in-progress recording with the bound value.
    if !field.isRecording {
      field.hotKey = hotKey
    }
  }
}

// MARK: - RecorderField

final class RecorderField: NSView {

  // MARK: Internal

  var onChange: ((HotKey?) -> Void)?
  var conflict: ((HotKey) -> String?)?
  var onRecordingChanged: ((Bool) -> Void)?

  var hotKey: HotKey? {
    didSet { needsDisplay = true }
  }

  /// Local keyDown monitor active only while recording. Capturing through a
  /// monitor (rather than keyDown/performKeyEquivalent) means special keys
  /// (Backspace, arrows, Return…) the SwiftUI responder chain would otherwise
  /// swallow still reach the recorder.
  private var monitor: Any?

  private(set) var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      needsDisplay = true
      onRecordingChanged?(isRecording)
    }
  }

  override var acceptsFirstResponder: Bool { true }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 150, height: 24)
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

  override func becomeFirstResponder() -> Bool {
    // Recording starts only on an explicit click (see mouseDown), not when
    // the window assigns us as its initial first responder on open.
    true
  }

  override func resignFirstResponder() -> Bool {
    stopRecording()
    return true
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { stopRecording() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func mouseDown(with _: NSEvent) {
    window?.makeFirstResponder(self)
    guard monitor == nil else { return }
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, self.isRecording else { return event }
      return self.record(event) ? nil : event
    }
  }

  private func stopRecording() {
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    isRecording = false
  }

  override func draw(_: NSRect) {
    // The capsule behind us provides the fill; we draw the focus ring, the
    // combo text, and the clear button on top of it.
    if isRecording {
      let ring = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1, dy: 1),
        xRadius: bounds.height / 2,
        yRadius: bounds.height / 2
      )
      ring.lineWidth = 2
      NSColor.controlAccentColor.setStroke()
      ring.stroke()
    }

    let text: String
    let color: NSColor
    let bold: Bool
    if let conflictText {
      text = conflictText
      color = .systemOrange
      bold = true
    } else if isRecording {
      text = "Press shortcut\u{2026}"
      color = .secondaryLabelColor
      bold = false
    } else if let hotKey {
      text = hotKey.symbols
      color = .labelColor
      bold = true
    } else {
      text = "Set shortcut"
      color = .secondaryLabelColor
      bold = false
    }

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
    let nsText = text as NSString
    let height = nsText.size(withAttributes: attributes).height
    nsText.draw(
      in: NSRect(x: 8, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height),
      withAttributes: attributes
    )
  }

  // MARK: Private

  private var conflictResetTask: Task<Void, Never>?

  private var conflictText: String? {
    didSet { needsDisplay = true }
  }

  /// Carbon modifier masks (cmd 256, shift 512, option 2048, control 4096).
  private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    var carbon = 0
    if flags.contains(.command) { carbon |= 256 }
    if flags.contains(.shift) { carbon |= 512 }
    if flags.contains(.option) { carbon |= 2048 }
    if flags.contains(.control) { carbon |= 4096 }
    return carbon
  }

  /// Records the combo from `event`, or beeps and keeps recording if it
  /// isn't a usable global shortcut. Returns whether the event was consumed.
  private func record(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape cancels.
      stopRecording()
      return true
    }
    let carbon = carbonModifiers(event.modifierFlags)
    // Function / navigation keys are fine bare; everything else needs a modifier.
    let standaloneOK = (96...122).contains(event.keyCode)
    guard carbon != 0 || standaloneOK else {
      NSSound.beep()
      return true
    }
    let candidate = HotKey(carbonKeyCode: Int(event.keyCode), carbonModifiers: carbon)
    // Already bound to another action — reject and say so. (The recorder's
    // own current key is excluded by the conflict closure, so it reads free.)
    if let owner = conflict?(candidate) {
      NSSound.beep()
      stopRecording()
      showConflict(owner)
      return true
    }
    hotKey = candidate
    onChange?(candidate)
    stopRecording()
    return true
  }

  private func showConflict(_ owner: String) {
    conflictText = "In use: \(owner)"
    conflictResetTask?.cancel()
    conflictResetTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled, let self else { return }
      conflictText = nil
    }
  }
}
