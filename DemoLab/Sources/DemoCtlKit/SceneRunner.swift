// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import DemoAppKit
import DemoDriverKit
import Foundation

// MARK: - OverlayMode

/// How much of the live narration layer is drawn while a scene plays.
///
/// A *recorded* take draws none of it. Narration is an ASS sidecar, and a line
/// drawn into the frame as well as written to the sidecar would appear twice the
/// moment anyone burned the sidecar in, with neither copy restylable.
///
/// The keycast used to stay live, on the reasoning that its timing was the thing
/// it was showing. It cost three takes to establish that the timing is not at
/// risk and the pixels are: ``SceneTimeline`` stamps the caps from the same
/// clock that drives the overlay, so a burned copy is exact to the centisecond,
/// while the live panel raced the capture stream. Takes came back with the first
/// one to three keycasts simply missing from the frames, at a recovery point
/// that moved between runs, while `screencapture` showed them on screen the
/// whole time. Ordering the panel front, rebuilding it into the live stream and
/// priming it with a first draw were all tried, and all of them only moved the
/// recovery point. A track that is written to a file cannot be lost by a capture
/// at all, which is why `off` is what a take uses.
///
/// The live modes remain for `democtl scene`, which narrates a rehearsal that
/// nothing is recording.
public enum OverlayMode: String, Sendable, CaseIterable {
  case full
  case keys
  case off

  // MARK: Public

  /// The overlay's own spelling of the same three states. `full` is `all`
  /// there: the overlay names what it draws, this names what a take wants.
  public var command: String {
    switch self {
    case .full: "mode all"
    case .keys: "mode keys"
    case .off: "mode off"
    }
  }

  /// The tracks this mode paints into the frame while the take is running.
  ///
  /// The burnable sidecar carries the complement of this, so burning it can
  /// never draw a second copy of something already in the pixels. A take shot
  /// with `keys` once produced exactly that: styled caps bottom-right from the
  /// overlay, and the raw `ctrl + alt - l` from the sidecar just above them.
  public var liveTracks: Set<SceneTimeline.Track> {
    switch self {
    case .full: Set(SceneTimeline.Track.allCases)
    case .keys: [.keys]
    case .off: []
    }
  }
}

// MARK: - SceneRunner

/// Plays a scene against the real Tatami.
///
/// Two rules run through every step:
///
/// 1. **Never treat `accepted` as confirmation.** Tatami's dispatcher answers
///    the moment a command is enqueued. Where a real barrier exists — an
///    activation reply, a hook event, a window appearing — the runner waits for
///    it. Where none exists, it waits a fixed, declared amount of time and the
///    scene file says so.
/// 2. **Fail loudly.** A step that cannot be confirmed aborts the take. A demo
///    that silently records nothing happening is worse than one that stops.
@MainActor
public final class SceneRunner {

  // MARK: Lifecycle

  public init(
    paths: LabPaths,
    client: TatamiClient,
    apps: DemoAppsController,
    log: @escaping (String) -> Void,
    timeline: SceneTimeline? = nil,
    overlayMode: OverlayMode = .full,
    keycastHoldMilliseconds: Int = SceneRunner.defaultKeycastHoldMilliseconds
  ) {
    self.paths = paths
    self.client = client
    self.apps = apps
    self.log = log
    self.timeline = timeline
    self.overlayMode = overlayMode
    self.keycastHoldMilliseconds = keycastHoldMilliseconds
    overlay = OverlayController(paths: paths)
  }

  // MARK: Public

  /// How long the keycaps stay up after the keystroke has been posted.
  ///
  /// They used to be cleared the instant the driver returned, which is a few
  /// tens of milliseconds: on camera the caps flashed past and a viewer could
  /// not read which shortcut was pressed. The scene files shortened their beats
  /// after each key step to pay for this hold, so a take does not get longer.
  public static let defaultKeycastHoldMilliseconds = 1200

  public let paths: LabPaths
  public let client: TatamiClient
  public let apps: DemoAppsController
  public let log: (String) -> Void
  /// Records what the narration said and when, for the sidecars written next to
  /// the movie. Nil when nothing is being recorded, which is why every use of it
  /// is optional rather than the runner carrying a timeline nobody reads.
  public let timeline: SceneTimeline?
  public let overlayMode: OverlayMode
  public let keycastHoldMilliseconds: Int

  // MARK: Private

  private let overlay: OverlayController
  private var clipboardBackup: [[NSPasteboard.PasteboardType:Data]]?
  private var windowFrames: [String:CGRect] = [:]
  private var layouts: [String: [String: CGRect]] = [:]
  private var markBeforePreviousStep: UInt64 = 0
  private var markBeforeCurrentStep: UInt64 = 0

  public func prepare(_ scene: Scene, dryRun: Bool = false) throws {
    if !dryRun, let count = scene.requires?.displays, DisplayInfo.all().count < count {
      throw DemoCtlError.usage("scene requires \(count) displays")
    }
    var preparation = scene
    preparation.steps = scene.setup ?? []
    try run(preparation, dryRun: dryRun)
    if !dryRun {
      try CaptureGate.waitForApps(scene.openingApps ?? [], timeout: .seconds(15))
      if let names = scene.openingApps { try CaptureGate.requireOpening(names) }
      try CaptureGate.requireCleanDesktop()
    }
  }

  public func run(_ scene: Scene, dryRun: Bool = false) throws {
    let events = EventLog(url: paths.eventLog)

    log("scene \(scene.name): \(scene.title)")
    if let summary = scene.summary { log("  \(summary)") }
    if let requires = scene.requires { logRequirements(requires) }
    log("")

    // Key steps need Accessibility. Check once, up front, rather than failing
    // in the middle of a take: a driver that silently posts nothing would
    // record a video of a demo that never happens.
    if !dryRun, scene.steps.contains(where: \.needsKeyboard), !KeyDriver.isTrusted {
      throw DemoCtlError.usage(
        """
        this scene types real shortcuts, but this process is not trusted for Accessibility.
        Grant it in System Settings > Privacy & Security > Accessibility, then run the scene again.
        (`democtl doctor` shows the current state.)
        """
      )
    }

    if !dryRun { try applyOverlayMode() }

    for (index, step) in scene.steps.enumerated() {
      let ordinal = String(format: "%2d", index + 1)
      log("[\(ordinal)] \(step.label)")
      guard !dryRun else { continue }
      // A `wait` step must be able to see the events produced by the step
      // *before* it. Sampling the log offset only when the wait runs would race:
      // a fast activation can land before the wait ever looks.
      markBeforePreviousStep = markBeforeCurrentStep
      markBeforeCurrentStep = events.mark
      do {
        try CaptureGate.requireCleanDesktop()
        try perform(step, events: events)
        try CaptureGate.requireCleanDesktop()
      } catch let error as DemoCtlError {
        throw DemoCtlError.sceneStepFailed(index: index + 1, step: step.label, message: error.description)
      } catch {
        throw DemoCtlError.sceneStepFailed(index: index + 1, step: step.label, message: "\(error)")
      }
    }

    log("")
    log("scene \(scene.name) complete")
  }

  private func logRequirements(_ requires: SceneRequirements) {
    var lines = [String]()
    if let displays = requires.displays { lines.append("displays: \(displays)") }
    if let profile = requires.profile { lines.append("starting profile: \(profile)") }
    if let apps = requires.apps { lines.append("apps: \(apps.joined(separator: ", "))") }
    if let note = requires.note { lines.append(note) }
    for line in lines { log("  requires \(line)") }
  }

  private func specs(_ names: [String]) throws -> [DemoAppSpec] {
    try names.map { try spec($0) }
  }

  private func perform(_ step: SceneStep, events: EventLog) throws {
    switch step {
    case .clipboard(let text):
      if clipboardBackup == nil {
        clipboardBackup=(NSPasteboard.general.pasteboardItems ?? []).map {item in
          Dictionary(uniqueKeysWithValues:item.types.compactMap {type in item.data(forType:type).map {(type,$0)}})
        }
      }
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(text,forType:.string) else {throw DemoCtlError.usage("could not prepare clipboard")}
    case .closeSettings:
      guard TatamiProcess.closeOwnWindows()>0 else {throw DemoCtlError.usage("Tatami window could not be closed")}
    case .saveControlFrame(let app,let id,let name): windowFrames[name]=try NativeInteractionDriver.controlFrame(bundleIdentifier:bundle(app),identifier:id)
    case .expectControlMoved(let app,let id,let name):
      guard let expected=windowFrames[name] else {throw DemoCtlError.usage("missing control checkpoint")}
      guard try Shell.wait(timeout:.seconds(4),until:{!CaptureGate.matches([name:try NativeInteractionDriver.controlFrame(bundleIdentifier:bundle(app),identifier:id)],[name:expected])}) else {throw DemoCtlError.usage("control geometry did not change: \(name)")}
    case .saveWindow(let app): windowFrames[app]=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(app))
    case .assertWindow(let app):
      guard let expected=windowFrames[app] else {throw DemoCtlError.usage("missing window checkpoint")}
      let actual=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(app))
      guard CaptureGate.matches([app:actual],[app:expected]) else {throw DemoCtlError.usage("window frame changed: \(app)")}
    case .expectPointer(let app):
      let frame=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(app))
      guard let point=CGEvent(source:nil)?.location,frame.contains(point) else {throw DemoCtlError.usage("pointer did not follow focus to \(app)")}
    case .hover(let app,let id): try NativeInteractionDriver.hover(bundleIdentifier:bundle(app),identifier:id)
    case .dragWindow(let app,let target,let x,let y):
      try activate(app:app)
      let source=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(app))
      let destination=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(target))
      try NativeInteractionDriver.drag(from:CGPoint(x:source.midX,y:source.minY+14),to:CGPoint(x:destination.minX+destination.width*x,y:destination.minY+destination.height*y))
    case .resizeWindow(let app,let dx,let dy):
      try activate(app:app)
      let frame=try NativeInteractionDriver.windowFrame(bundleIdentifier:bundle(app))
      let point=CGPoint(x:frame.maxX-1,y:frame.midY)
      try NativeInteractionDriver.drag(from:point,to:CGPoint(x:point.x+dx,y:point.y+dy))
    case .expectFront(let app):
      let id=try bundle(app)
      guard Shell.wait(timeout:.seconds(4),until:{NativeInteractionDriver.frontmostBundleIdentifier()==id}) else {throw DemoCtlError.usage("focus did not reach \(app)")}
    case .expectLayoutChanged(let name):
      guard let expected=layouts[name] else {throw DemoCtlError.usage("missing layout checkpoint")}
      guard try Shell.wait(timeout:.seconds(4),until:{!CaptureGate.matches(try CaptureGate.demoFrames(),expected)}) else {throw DemoCtlError.usage("layout \(name) did not change")}
    case .configure(let key,let value):
      try LiveConfigEditor.update(file:paths.configFile,key:key,value:value)
      Shell.sleep(.milliseconds(800))
    case .virtualDisplay(let connected):
      if connected {try VirtualDisplayController.connect(paths)} else {try VirtualDisplayController.disconnect(paths)}
    case .expectCommand(let command,let code):
      let file=paths.controlDirectory.appendingPathComponent("terminal-result.json")
      guard Shell.wait(timeout:.seconds(15),until:{
        guard let data=try? Data(contentsOf:file),let result=try? JSONDecoder().decode(TerminalResult.self,from:data) else {return false}
        return result.command==command && result.exitCode==Int32(code)
      }) else {throw DemoCtlError.usage("command did not complete successfully: \(command)")}
    case .expectHook(let field,let value):
      let file=paths.controlDirectory.appendingPathComponent(field == "title" ? "hud-hook.json" : "workspace-hook.json")
      guard Shell.wait(timeout:.seconds(5),until:{
        guard let data=try? Data(contentsOf:file),let hook=try? JSONDecoder().decode(HookActivity.self,from:data) else {return false}
        switch field {case "workspace":return hook.workspace==value;case "profile":return hook.profile==value;case "title":return hook.title.contains(value);default:return hook.event==value}
      }) else {throw DemoCtlError.usage("hook did not report \(field) = \(value)")}
    case .click(let name, let identifier):
      try activate(app: name)
      try NativeInteractionDriver.click(bundleIdentifier: bundle(name), identifier: identifier)
    case .typeText(let name, let text, let interval):
      let identifier = try bundle(name)
      guard NativeInteractionDriver.frontmostBundleIdentifier() == identifier else {
        throw DemoCtlError.usage("refusing to type into an unexpected frontmost app; expected \(name)")
      }
      try NativeInteractionDriver.type(text, intervalMilliseconds: interval)
    case .expectValue(let name, let identifier, let value):
      let actual = try NativeInteractionDriver.value(bundleIdentifier: bundle(name), identifier: identifier)
      guard actual == value else { throw DemoCtlError.usage("native value mismatch for \(identifier): \(actual)") }
    case .expectStory(let field, let value):
      let repository = StoryRepository(file: paths.controlDirectory.appendingPathComponent("launch-story.json"))
      let passed = try Shell.wait(timeout: .seconds(4)) {
        let story = try repository.load()
        switch field {
        case "exported": return String(story.exported) == value
        case "theme": return story.designTheme == value
        case "headline": return story.headline == value
        case "approved": return String(story.approved) == value
        case "reviewComment": return story.reviewComment == value
        case "lastTask": return story.tasks.last?.text == value
        case "lastMessage": return story.messages.last?.text == value
        case "checksPassed": return String(story.checks.filter(\.passed).count) == value
        case "completedTasks": return String(story.tasks.filter(\.done).count) == value
        default: throw DemoCtlError.usage("unknown story assertion: \(field)")
        }
      }
      guard passed else { throw DemoCtlError.usage("saved work did not match: \(field) = \(value)") }
    case .scroll(let name, let identifier, let pixels):
      try NativeInteractionDriver.scroll(bundleIdentifier: bundle(name), identifier: identifier, pixels: pixels)
    case .waitWindows(let names, let milliseconds):
      try CaptureGate.waitForApps(names, timeout: .milliseconds(milliseconds))
    case .saveLayout(let name):
      layouts[name] = try CaptureGate.demoFrames()
    case .assertLayout(let name):
      guard let expected = layouts[name], !expected.isEmpty else {
        throw DemoCtlError.usage("no layout checkpoint named \(name)")
      }
      let restored = try Shell.wait(timeout: .seconds(5)) {
        CaptureGate.matches(try CaptureGate.demoFrames(), expected)
      }
      guard restored else { throw DemoCtlError.usage("layout \(name) was not restored") }
      log("      verified layout restoration: \(name)")
    case .note(let text):
      log("      \(text)")

    case .beat(let milliseconds, let note):
      if let note { log("      \(note)") }
      Shell.sleep(.milliseconds(milliseconds))

    case .launch(let names, let windows):
      var counts = [DemoAppID: Int]()
      for (name, count) in windows {
        guard let spec = DemoCatalog.spec(named: name) else {
          throw DemoCtlError.usage("unknown demo app \"\(name)\" in windows map")
        }
        counts[spec.id] = count
      }
      try apps.launch(try specs(names), windowCounts: counts)

    case .quitApps(let names):
      if let names {
        apps.quit(try specs(names))
      } else {
        apps.quitAll()
      }

    case .pointer(let display, let x, let y):
      // Placement of a dynamic workspace follows the pointer, so parking the
      // cursor is what makes multi-display placement reproducible.
      try Pointer.warp(toDisplayIndex: display, unitX: x, unitY: y)

    case .activateWorkspace(let workspace, let profile):
      try client.activateWorkspace(workspace, profile: profile)

    case .activateProfile(let profile):
      try client.activateProfile(profile)

    case .cli(let arguments, let expect):
      switch expect {
      case "any": _ = try client.json(arguments)
      case "completed", "accepted": try expectStatus(expect, arguments)
      default: throw DemoCtlError.usage("cli step expect must be accepted, completed or any")
      }

    case .key(let chord, let repeats, let holdMilliseconds):
      var notes: [String] = []
      let parsed = try ChordParser.parse(chord, notes: &notes)
      // A layout note means the demo is pressing a different physical key than
      // the shortcut text reads as. It belongs in the take's log, not nowhere.
      for note in notes { log("      \(note)") }
      // The keycaps belong to the step, not to a separate scene line: the runner
      // already knows the chord it is about to press, and a scene file that had
      // to repeat it could show one shortcut while pressing another.
      try showKeycaps(chord)
      do {
        for _ in 0..<max(1, repeats) {
          try KeyDriver.press(parsed, holdMilliseconds: holdMilliseconds)
          Shell.sleep(.milliseconds(90))
        }
      } catch {
        // The take is already failing; clearing must not replace the real error.
        try? showKeycaps("")
        throw error
      }
      holdKeycaps()
      try showKeycaps("")

    case .hold(let modifiers, let keys, let gapMilliseconds, let releaseAfterMilliseconds):
      let flags = try Self.flags(from: modifiers)
      // Same resolution as a `key` step, deliberately: Magnet registers the
      // *active layout's* key code, so a QWERTY lookup here would press a key
      // Tatami never registered and record a scene where nothing happens.
      var notes: [String] = []
      var codes: [CGKeyCode] = []
      for name in keys {
        let chord: Chord
        do {
          chord = try ChordParser.parse(name, notes: &notes)
        } catch {
          throw DemoCtlError.usage("bad key \"\(name)\" in hold step: \(error)")
        }
        // The switcher holds one modifier set for the whole session, so a tap
        // cannot introduce its own — the rule `demokey hold` enforces too.
        guard flags.contains(chord.flags) else {
          throw DemoCtlError.usage(
            "key \"\(name)\" in hold step carries modifiers that are not held — "
              + "put every modifier in the step's \"modifiers\""
          )
        }
        codes.append(chord.keyCode)
      }
      for note in notes { log("      \(note)") }
      try showKeycaps(Self.holdLabel(modifiers: modifiers, keys: keys))
      do {
        try KeyDriver.hold(
          modifiers: flags,
          tapping: codes,
          gapMilliseconds: gapMilliseconds,
          holdAfterMilliseconds: releaseAfterMilliseconds
        )
      } catch {
        try? showKeycaps("")
        throw error
      }
      holdKeycaps()
      try showKeycaps("")

    case .waitWorkspace(let workspace, let timeoutMilliseconds):
      let found = try events.wait(
        since: markBeforePreviousStep,
        timeout: .milliseconds(timeoutMilliseconds),
        describing: "workspaceActivated for \(workspace)"
      ) { $0.event == "workspaceActivated" && $0.workspace == workspace }
      log("      \(found.summary)")

    case .waitProfile(let profile, let timeoutMilliseconds):
      let found = try events.wait(
        since: markBeforePreviousStep,
        timeout: .milliseconds(timeoutMilliseconds),
        describing: "profileChanged to \(profile)"
      ) { $0.event == "profileChanged" && $0.profile == profile }
      log("      \(found.summary)")

    case .borrow(let workspace, let expectApps, let timeoutMilliseconds):
      try client.dispatch(["workspace", "borrow", "from", workspace])
      // Borrow publishes no workspaceActivated event, so the barrier is the
      // observable consequence instead: a summoned scratchpad forces autoOpen
      // on its apps, so their windows appearing means the borrow landed.
      guard !expectApps.isEmpty else {
        Shell.sleep(.milliseconds(900))
        return
      }
      let wanted = try specs(expectApps)
      let appeared = Shell.wait(timeout: .milliseconds(timeoutMilliseconds)) {
        wanted.allSatisfy { DemoAppsController.onScreenWindowCount(for: $0) > 0 }
      }
      guard appeared else {
        throw DemoCtlError.waitTimedOut(
          what: "borrowed \(workspace) to show \(expectApps.joined(separator: ", "))",
          seconds: Double(timeoutMilliseconds) / 1000
        )
      }

    case .dismissBorrow(let settleMilliseconds):
      try client.dispatch(["workspace", "dismiss-borrow"])
      // Returning a borrow re-activates the host, but does not publish an event
      // the lab can key on, so this settle is a declared wait rather than a
      // barrier. It is in the scene file so it is visible and tunable.
      Shell.sleep(.milliseconds(settleMilliseconds))

    case .appWindows(let name, let count):
      let target = try spec(name)
      let reply = try apps.setWindowCount(count, of: target)
      log("      \(reply)")
      // Windows are Tatami's input: give the AX observers the same moment to
      // retile that a launch step gives them.
      Shell.sleep(.milliseconds(350))

    // Narration a scene asked for by name is load bearing: a take that recorded
    // the actions without the words explaining them is the wrong video, so these
    // steps fail when the overlay is not there. The keycaps a `key` step adds by
    // itself are the opposite case, and stay quiet.
    //
    // The timeline is stamped *before* the overlay is told, so a sidecar records
    // the narration a take asked for even when the overlay is the thing that
    // failed. In `--overlay keys` the overlay draws none of this, and the
    // sidecar is then the only copy of the words.
    case .chapter(let text):
      timeline?.record(.chapter, text: text)
      if overlayMode == .full { try overlay.chapter(text) }

    case .caption(let text):
      timeline?.record(.caption, text: text)
      if overlayMode == .full { try overlay.caption(text) }

    case .keys(let chord):
      timeline?.record(.keys, text: chord)
      if overlayMode != .off { try overlay.keys(chord) }

    case .clearOverlay:
      for track in SceneTimeline.Track.allCases { timeline?.record(track, text: "") }
      if OverlayController.isListening { try overlay.clear() }

    case .activateApp(let name):
      try activate(app: name)
    }
  }

  public func restoreClipboard() {
    guard let backup=clipboardBackup else {return}
    let items=backup.map {values in let item=NSPasteboardItem();for (type,data) in values {item.setData(data,forType:type)};return item}
    NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects(items)
    clipboardBackup=nil
  }

  private func bundle(_ name:String) throws -> String {
    if name == "Tatami" {return client.install.bundleIdentifier}
    return try spec(name).bundleIdentifier
  }

  private func spec(_ name: String) throws -> DemoAppSpec {
    guard let spec = DemoCatalog.spec(named: name) else {
      throw DemoCtlError.usage(
        "unknown demo app \"\(name)\" (\(DemoCatalog.all.map(\.name).joined(separator: ", ")))"
      )
    }
    return spec
  }

  /// Shows or clears the keycaps a `key` or `hold` step is about to press.
  ///
  /// Silent when the overlay is not running: those keycaps are something the
  /// runner adds on its own, and a scene that never asked for narration must
  /// still play on a machine with no overlay. A *running* overlay that refuses
  /// the command is a real failure and is reported as one, exactly like the
  /// explicit `caption` and `chapter` steps.
  ///
  /// The timeline is stamped either way. A take shot without the overlay still
  /// deserves a sidecar that says which shortcut was pressed and when.
  private func showKeycaps(_ chord: String) throws {
    timeline?.record(.keys, text: chord)
    guard overlayMode != .off else { return }
    guard OverlayController.isListening else {
      // Silent until now, and the silence was the bug: a scene that lost the
      // overlay mid-take went on stamping keycasts into the sidecar that were
      // never on screen.
      log("warning: no overlay is listening, so \(chord) is in the sidecar but not in the frames")
      return
    }
    let reply = try overlay.keys(chord)
    // A live rehearsal should report a hidden panel. Recorded takes use sidecars.
    if reply.contains("hidden=true") || reply.contains("panels=0/") {
      log("warning: the overlay could not draw \(chord) (\(reply)); this keycast is missing from the frames")
    }
  }

  /// Leaves the keycaps up long enough to read.
  ///
  /// The sidecar gets the same duration for free: the ASS entry runs from the
  /// moment the caps went up to the moment ``showKeycaps`` clears them, and both
  /// ends are stamped off the same clock the live overlay was driven by. There
  /// is no second number that could drift out of agreement with this one.
  private func holdKeycaps() {
    guard keycastHoldMilliseconds > 0 else { return }
    Shell.sleep(.milliseconds(keycastHoldMilliseconds))
  }

  /// Tells a running overlay how much of the narration layer to draw.
  ///
  /// Silent when the overlay is not running, for the same reason ``showKeycaps``
  /// is. A *running* overlay that refuses is a real failure and stops the take:
  /// an overlay too old to know `mode` would otherwise burn captions into a take
  /// that also ships them as a sidecar, and nothing would say so until the
  /// duplicates showed up in a burned copy.
  private func applyOverlayMode() throws {
    guard OverlayController.isListening else { return }
    _ = try overlay.send(overlayMode.command)
    log("overlay: \(overlayMode.rawValue)")
    log("")
  }

  /// The keycap label for a `hold` step: the modifiers that stay down, then the
  /// key or keys tapped under them. Consecutive repeats collapse, so holding
  /// ctrl+alt and tapping `2` three times reads as one keycap rather than three.
  private static func holdLabel(modifiers: String, keys: [String]) -> String {
    var tapped = [String]()
    for key in keys where tapped.last != key { tapped.append(key) }
    return "\(modifiers) - \(tapped.joined(separator: " "))"
  }

  /// Brings an app to the front. `"Tatami"` means the Tatami this lab drives,
  /// resolved through the located install so a Debug build is addressed by its
  /// own bundle identifier.
  private func activate(app name: String) throws {
    let identifier: String
    var demoApp: DemoAppSpec?
    if name.caseInsensitiveCompare("Tatami") == .orderedSame {
      identifier = client.install.bundleIdentifier
    } else {
      let spec = try spec(name)
      demoApp = spec
      identifier = spec.bundleIdentifier
    }
    guard let application = NSRunningApplication
      .runningApplications(withBundleIdentifier: identifier).first
    else {
      throw DemoCtlError.usage("activateApp: \(name) (\(identifier)) is not running")
    }
    if demoApp != nil {
      if NativeInteractionDriver.frontmostBundleIdentifier() == identifier {return}
      // A real title-bar click has a user activation context. Background
      // activate() requests can be declined even when the control socket replies.
      try NativeInteractionDriver.clickWindowTitle(bundleIdentifier:identifier)
    } else {
      _ = application.activate()
    }
    // Only an app with a Dock tile can become frontmost. Tatami is an accessory
    // app, so waiting for it there would time out on a step that worked.
    guard application.activationPolicy == .regular else {
      Shell.sleep(.milliseconds(200))
      return
    }
    let front = Shell.wait(timeout: .seconds(4)) {
      NativeInteractionDriver.frontmostBundleIdentifier() == identifier
    }
    guard front else {
      throw DemoCtlError.waitTimedOut(what: "\(name) to become frontmost", seconds: 4)
    }
  }

  private func expectStatus(_ status: String, _ arguments: [String]) throws {
    if status == "completed" {
      let value = try client.json(arguments)
      guard let object = value as? [String: Any], object["status"] as? String == "completed" else {
        throw DemoCtlError.tatamiCommandFailed(
          command: arguments.joined(separator: " "),
          message: "expected status completed"
        )
      }
    } else {
      try client.dispatch(arguments)
    }
  }

  /// The modifier half of a `hold` step, read with the same grammar as the
  /// modifier half of a chord, so the two front ends cannot drift apart.
  private static func flags(from text: String) throws -> CGEventFlags {
    let flags: CGEventFlags
    do {
      flags = try ChordParser.parseModifiers(text)
    } catch {
      throw DemoCtlError.usage("bad modifiers \"\(text)\" in hold step: \(error)")
    }
    guard !flags.isEmpty else { throw DemoCtlError.usage("hold step needs at least one modifier") }
    return flags
  }

}

extension SceneStep {
  fileprivate var needsKeyboard: Bool {
    switch self {
    case .key, .hold, .click, .typeText, .scroll, .hover, .dragWindow, .resizeWindow: true
    default: false
    }
  }
}
