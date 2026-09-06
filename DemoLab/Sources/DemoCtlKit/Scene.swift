// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - Scene

/// A recorded take, described as an ordered list of steps.
///
/// Scenes are data rather than code so a take can be re-timed or re-ordered
/// without rebuilding anything, and so the exact sequence that produced a video
/// is reviewable in a diff.
public struct Scene: Sendable, Decodable {

  // MARK: Public

  public var name: String
  public var title: String
  public var summary: String?
  /// Printed before the run so the operator knows what has to be true first.
  public var requires: SceneRequirements?
  /// Runs before the recorder starts; app launches and layout preparation never enter the movie.
  public var setup: [SceneStep]?
  public var openingApps: [String]?
  public var steps: [SceneStep]

}

// MARK: - SceneRequirements

public struct SceneRequirements: Sendable, Decodable {
  public var displays: Int?
  public var profile: String?
  public var apps: [String]?
  public var note: String?
}

// MARK: - SceneStep

public enum SceneStep: Sendable {
  /// Narration only. Printed with its cue time so the voiceover script and the
  /// recording stay in sync.
  case clipboard(text:String)
  case closeSettings
  case saveControlFrame(app:String,identifier:String,name:String)
  case expectControlMoved(app:String,identifier:String,name:String)
  case saveWindow(app:String)
  case assertWindow(app:String)
  case expectPointer(app:String)
  case hover(app:String,identifier:String)
  case dragWindow(app:String,target:String,x:Double,y:Double)
  case resizeWindow(app:String,dx:Double,dy:Double)
  case expectFront(app:String)
  case expectLayoutChanged(name:String)
  case configure(key:String,value:String)
  case virtualDisplay(connected:Bool)
  case expectCommand(command:String,code:Int)
  case expectHook(field:String,value:String)
  case click(app: String, identifier: String)
  case typeText(app: String, text: String, intervalMilliseconds: Int)
  case expectStory(field: String, value: String)
  case expectValue(app: String, identifier: String, value: String)
  case scroll(app: String, identifier: String, pixels: Int)
  case note(text: String)
  case beat(milliseconds: Int, note: String?)
  case launch(apps: [String], windows: [String: Int])
  case quitApps(apps: [String]?)
  case pointer(display: Int, x: Double, y: Double)
  case activateWorkspace(workspace: String, profile: String?)
  case activateProfile(profile: String)
  case cli(arguments: [String], expect: String)
  case key(chord: String, repeats: Int, holdMilliseconds: Int)
  case hold(modifiers: String, keys: [String], gapMilliseconds: Int, releaseAfterMilliseconds: Int)
  case waitWorkspace(workspace: String, timeoutMilliseconds: Int)
  case waitProfile(profile: String, timeoutMilliseconds: Int)
  case borrow(workspace: String, expectApps: [String], timeoutMilliseconds: Int)
  case dismissBorrow(settleMilliseconds: Int)
  case appWindows(app: String, count: Int)
  /// Narration. The overlay holds whatever it was last told, so a caption stays
  /// until a later step replaces or clears it.
  case chapter(text: String)
  case caption(text: String)
  /// Keycaps for an action that was **not** a keystroke. A `key` or `hold` step
  /// shows its own chord, so a scene file never repeats one next to a keystroke.
  case keys(chord: String)
  case clearOverlay
  case activateApp(app: String)
  case waitWindows(apps: [String], timeoutMilliseconds: Int)
  case saveLayout(name: String)
  case assertLayout(name: String)

  // MARK: Public

  public var label: String {
    switch self {
    case .clipboard: "prepare example clipboard content"
    case .closeSettings: "close Tatami window"
    case .saveControlFrame(_,_,let name): "save control frame \(name)"
    case .expectControlMoved(_,_,let name): "verify control moved \(name)"
    case .saveWindow(let app): "save window \(app)"
    case .assertWindow(let app): "verify window frame \(app)"
    case .expectPointer(let app): "verify pointer in \(app)"
    case .hover(let app,let id): "hover \(app) / \(id)"
    case .dragWindow(let app,let target,_,_): "drag \(app) to \(target)"
    case .resizeWindow(let app,_,_): "resize \(app)"
    case .expectFront(let app): "verify focused app \(app)"
    case .expectLayoutChanged(let name): "verify changed layout \(name)"
    case .configure(let key,let value): "configure \(key) = \(value)"
    case .virtualDisplay(let connected): connected ? "connect secondary display" : "disconnect secondary display"
    case .expectCommand(let command,_): "verify command \(command)"
    case .expectHook(let field,let value): "verify hook \(field) = \(value)"
    case .waitWindows: "waitWindows"
    case .saveLayout: "saveLayout"
    case .assertLayout: "assertLayout"
    case .click(let app, let id): "click \(app) / \(id)"
    case .typeText(let app, let text, _): "type in \(app): \(text)"
    case .expectStory(let field, let value): "verify \(field) = \(value)"
    case .expectValue(let app, let id, _): "verify native input \(app) / \(id)"
    case .scroll(let app, _, _): "scroll \(app)"
    case .note: "note"
    case .beat: "beat"
    case .launch(let apps, _): "launch \(apps.joined(separator: "+"))"
    case .quitApps: "quit-apps"
    case .pointer(let display, _, _): "pointer display \(display)"
    case .activateWorkspace(let workspace, _): "activate-workspace \(workspace)"
    case .activateProfile(let profile): "activate-profile \(profile)"
    case .cli(let arguments, _): "cli \(arguments.joined(separator: " "))"
    case .key(let chord, _, _): "key \(chord)"
    case .hold(let modifiers, let keys, _, _): "hold \(modifiers) + \(keys.joined(separator: ","))"
    case .waitWorkspace(let workspace, _): "wait-workspace \(workspace)"
    case .waitProfile(let profile, _): "wait-profile \(profile)"
    case .borrow(let workspace, _, _): "borrow \(workspace)"
    case .dismissBorrow: "dismiss-borrow"
    case .appWindows(let app, let count): "app-windows \(app) \(count)"
    case .chapter(let text): text.isEmpty ? "chapter (clear)" : "chapter \(text)"
    case .caption(let text): text.isEmpty ? "caption (clear)" : "caption \(text)"
    case .keys(let chord): chord.isEmpty ? "keys (clear)" : "keys \(chord)"
    case .clearOverlay: "clear-overlay"
    case .activateApp(let app): "activate-app \(app)"
    }
  }
}

// MARK: Decodable

extension SceneStep: Decodable {

  // MARK: Lifecycle

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)

    switch kind {
    case "waitWindows":
      self = .waitWindows(apps: try container.decode([String].self, forKey: .apps),
        timeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 12000)
    case "saveLayout":
      self = .saveLayout(name: try container.decode(String.self, forKey: .text))
    case "assertLayout":
      self = .assertLayout(name: try container.decode(String.self, forKey: .text))
    case "clipboard": self = .clipboard(text:try container.decode(String.self,forKey:.text))
    case "closeSettings": self = .closeSettings
    case "saveControlFrame": self = .saveControlFrame(app:try container.decode(String.self,forKey:.app),identifier:try container.decode(String.self,forKey:.identifier),name:try container.decode(String.self,forKey:.text))
    case "expectControlMoved": self = .expectControlMoved(app:try container.decode(String.self,forKey:.app),identifier:try container.decode(String.self,forKey:.identifier),name:try container.decode(String.self,forKey:.text))
    case "saveWindow": self = .saveWindow(app:try container.decode(String.self,forKey:.app))
    case "assertWindow": self = .assertWindow(app:try container.decode(String.self,forKey:.app))
    case "expectPointer": self = .expectPointer(app:try container.decode(String.self,forKey:.app))
    case "hover": self = .hover(app:try container.decode(String.self,forKey:.app),identifier:try container.decode(String.self,forKey:.identifier))
    case "dragWindow": self = .dragWindow(app:try container.decode(String.self,forKey:.app),target:try container.decode(String.self,forKey:.target),x:try container.decodeIfPresent(Double.self,forKey:.x) ?? 0.5,y:try container.decodeIfPresent(Double.self,forKey:.y) ?? 0.5)
    case "resizeWindow": self = .resizeWindow(app:try container.decode(String.self,forKey:.app),dx:try container.decode(Double.self,forKey:.x),dy:try container.decodeIfPresent(Double.self,forKey:.y) ?? 0)
    case "expectFront": self = .expectFront(app:try container.decode(String.self,forKey:.app))
    case "expectLayoutChanged": self = .expectLayoutChanged(name:try container.decode(String.self,forKey:.text))
    case "configure": self = .configure(key:try container.decode(String.self,forKey:.field),value:try container.decode(String.self,forKey:.value))
    case "virtualDisplay": self = .virtualDisplay(connected:try container.decode(Bool.self,forKey:.connected))
    case "expectCommand": self = .expectCommand(command:try container.decode(String.self,forKey:.text),code:try container.decodeIfPresent(Int.self,forKey:.code) ?? 0)
    case "expectHook": self = .expectHook(field:try container.decode(String.self,forKey:.field),value:try container.decode(String.self,forKey:.value))
    case "click":
      self = .click(app: try container.decode(String.self, forKey: .app), identifier: try container.decode(String.self, forKey: .identifier))
    case "typeText":
      self = .typeText(app: try container.decode(String.self, forKey: .app), text: try container.decode(String.self, forKey: .text), intervalMilliseconds: try container.decodeIfPresent(Int.self, forKey: .ms) ?? 55)
    case "expectStory":
      self = .expectStory(field: try container.decode(String.self, forKey: .field), value: try container.decode(String.self, forKey: .value))
    case "expectValue":
      self = .expectValue(app: try container.decode(String.self, forKey: .app), identifier: try container.decode(String.self, forKey: .identifier), value: try container.decode(String.self, forKey: .value))
    case "scroll":
      self = .scroll(app: try container.decode(String.self, forKey: .app), identifier: try container.decode(String.self, forKey: .identifier), pixels: try container.decode(Int.self, forKey: .pixels))
    case "note":
      self = .note(text: try container.decode(String.self, forKey: .text))

    case "beat":
      self = .beat(
        milliseconds: try container.decode(Int.self, forKey: .ms),
        note: try container.decodeIfPresent(String.self, forKey: .note)
      )

    case "launch":
      self = .launch(
        apps: try container.decode([String].self, forKey: .apps),
        windows: try container.decodeIfPresent([String: Int].self, forKey: .windows) ?? [:]
      )

    case "quitApps":
      self = .quitApps(apps: try container.decodeIfPresent([String].self, forKey: .apps))

    case "pointer":
      self = .pointer(
        display: try container.decodeIfPresent(Int.self, forKey: .display) ?? 0,
        x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5,
        y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
      )

    case "activateWorkspace":
      self = .activateWorkspace(
        workspace: try container.decode(String.self, forKey: .workspace),
        profile: try container.decodeIfPresent(String.self, forKey: .profile)
      )

    case "activateProfile":
      self = .activateProfile(profile: try container.decode(String.self, forKey: .profile))

    case "cli":
      self = .cli(
        arguments: try container.decode([String].self, forKey: .args),
        expect: try container.decodeIfPresent(String.self, forKey: .expect) ?? "accepted"
      )

    case "key":
      self = .key(
        chord: try container.decode(String.self, forKey: .chord),
        repeats: try container.decodeIfPresent(Int.self, forKey: .repeats) ?? 1,
        holdMilliseconds: try container.decodeIfPresent(Int.self, forKey: .holdMs) ?? 24
      )

    case "hold":
      self = .hold(
        modifiers: try container.decode(String.self, forKey: .modifiers),
        keys: try container.decode([String].self, forKey: .keys),
        gapMilliseconds: try container.decodeIfPresent(Int.self, forKey: .gapMs) ?? 320,
        releaseAfterMilliseconds: try container.decodeIfPresent(Int.self, forKey: .releaseAfterMs) ?? 700
      )

    case "waitWorkspace":
      self = .waitWorkspace(
        workspace: try container.decode(String.self, forKey: .workspace),
        timeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 10_000
      )

    case "waitProfile":
      self = .waitProfile(
        profile: try container.decode(String.self, forKey: .profile),
        timeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 10_000
      )

    case "borrow":
      self = .borrow(
        workspace: try container.decode(String.self, forKey: .workspace),
        expectApps: try container.decodeIfPresent([String].self, forKey: .expectApps) ?? [],
        timeoutMilliseconds: try container.decodeIfPresent(Int.self, forKey: .timeoutMs) ?? 10_000
      )

    case "dismissBorrow":
      self = .dismissBorrow(
        settleMilliseconds: try container.decodeIfPresent(Int.self, forKey: .settleMs) ?? 900
      )

    case "appWindows":
      self = .appWindows(
        app: try container.decode(String.self, forKey: .app),
        count: try container.decode(Int.self, forKey: .count)
      )

    case "chapter":
      self = .chapter(text: try container.decode(String.self, forKey: .text))

    case "caption":
      // Required even when it is empty: an omitted text would read as "leave the
      // caption alone", and a step that changes nothing is never what a scene
      // meant to write.
      self = .caption(text: try container.decode(String.self, forKey: .text))

    case "keys":
      self = .keys(chord: try container.decode(String.self, forKey: .chord))

    case "clearOverlay":
      self = .clearOverlay

    case "activateApp":
      self = .activateApp(app: try container.decode(String.self, forKey: .app))

    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "unknown scene step kind \"\(kind)\""
      )
    }
  }

  // MARK: Private

  private enum CodingKeys: String, CodingKey {
    case kind, text, ms, note, apps, windows, display, x, y, app, state, count
    case identifier, field, value, pixels, target, connected, code
    case workspace, profile, args, expect, chord, repeats, holdMs
    case modifiers, keys, gapMs, releaseAfterMs, timeoutMs, expectApps, settleMs
  }

}

// MARK: - SceneLoader

public enum SceneLoader {

  // MARK: Public

  public static func available(in paths: LabPaths) -> [String] {
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: paths.scenesRoot,
      includingPropertiesForKeys: nil
    )) ?? []
    return contents
      .filter { $0.pathExtension == "json" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()
  }

  public static func load(_ name: String, paths: LabPaths) throws -> Scene {
    let url = paths.sceneFile(name)
    guard let data = try? Data(contentsOf: url) else {
      throw DemoCtlError.sceneNotFound(name, available: available(in: paths))
    }
    return try JSONDecoder().decode(Scene.self, from: data)
  }

}
