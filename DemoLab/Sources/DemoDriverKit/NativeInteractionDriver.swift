// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Drives the fixture apps through their native controls. No model-state injection.
@MainActor
public enum NativeInteractionDriver {
  public static func frontmostBundleIdentifier() -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }

  public static func click(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    let point = try center(of: target)
    try clickPoint(point)
  }

  public static func isMenuItem(bundleIdentifier: String, identifier: String) throws -> Bool {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    return attribute(target, kAXRoleAttribute) as? String == kAXMenuItemRole
  }

  public static func rightClick(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    let point = try center(of: target)
    try move(to: point)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
          let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []; up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
  }

  public static func prepareSettingsWindow(bundleIdentifier: String) throws {
    let window = try element(bundleIdentifier: bundleIdentifier, identifier: "main")
    var frame = try bounds(of: window)
    try drag(from: CGPoint(x: frame.minX + 110, y: frame.minY + 15), to: CGPoint(x: 260, y: 125))
    frame = try bounds(of: window)
    try drag(from: CGPoint(x: frame.maxX - 2, y: frame.maxY - 2), to: CGPoint(x: 1770, y: 1050))
  }

  public static func clickSettingsWindowTitle(bundleIdentifier: String) throws {
    let window = try element(bundleIdentifier: bundleIdentifier, identifier: "main")
    // Auto-opened fixture apps can cover Tatami during launch. Raise the
    // actual window first so the title click cannot hit an app behind it.
    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
      throw InteractionError("could not raise the Tatami window")
    }
    Thread.sleep(forTimeInterval: 0.12)
    let sheet = (attribute(window, kAXChildrenAttribute) as? [AXUIElement])?
      .first { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
    let frame = try bounds(of: sheet ?? window)
    try clickPoint(CGPoint(x: sheet == nil ? frame.minX + 110 : frame.midX, y: frame.minY + 15))
  }

  public static func clickWindowTitle(bundleIdentifier:String) throws {
    let frame=try windowFrame(bundleIdentifier:bundleIdentifier)
    try clickPoint(CGPoint(x:frame.midX,y:frame.minY+14))
  }

  private static func clickPoint(_ point:CGPoint) throws {
    try move(to: point)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []; up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.12)
  }

  public static func controlFrame(bundleIdentifier:String,identifier:String) throws -> CGRect {try bounds(of:element(bundleIdentifier:bundleIdentifier,identifier:identifier))}
  public static func hover(bundleIdentifier:String,identifier:String) throws {
    let target=try element(bundleIdentifier:bundleIdentifier,identifier:identifier)
    try reveal(target)
    try move(to:center(of:target))
  }
  public static func windowFrame(bundleIdentifier:String) throws -> CGRect {
    guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundleIdentifier).first else {throw InteractionError("app is not running")}
    let root=AXUIElementCreateApplication(app.processIdentifier)
    guard let windows=attribute(root,kAXWindowsAttribute) as? [AXUIElement],
          let window=windows.first(where: { search($0, identifier: "demolab.window.content", depth: 0) != nil })
    else {throw InteractionError("app has no identified demo window") }
    return try bounds(of:window)
  }
  public static func drag(from:CGPoint,to:CGPoint) throws {
    try move(to:from)
    guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:from,mouseButton:.left) else {throw DriverError.eventSourceUnavailable}
    down.flags=[];down.post(tap:.cghidEventTap)
    Thread.sleep(forTimeInterval:0.12)
    for step in 1...40 {
      let t=Double(step)/40;let eased=t*t*(3-2*t)
      let point=CGPoint(x:from.x+(to.x-from.x)*eased,y:from.y+(to.y-from.y)*eased)
      guard let drag=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDragged,mouseCursorPosition:point,mouseButton:.left) else {throw DriverError.eventSourceUnavailable}
      drag.flags=[];drag.post(tap:.cghidEventTap);Thread.sleep(forTimeInterval:0.018)
    }
    Thread.sleep(forTimeInterval:0.35)
    guard let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:to,mouseButton:.left) else {throw DriverError.eventSourceUnavailable}
    up.flags=[];up.post(tap:.cghidEventTap)
    Thread.sleep(forTimeInterval:0.5)
  }
  public static func snapshot(bundleIdentifier:String) throws -> String {
    guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundleIdentifier).first else {throw InteractionError("app is not running")}
    var lines:[String]=[]
    func visit(_ node:AXUIElement,_ depth:Int) {
      guard depth<24,lines.count<650 else {return}
      let role=attribute(node,kAXRoleAttribute) as? String ?? "?"
      let attrs=[kAXIdentifierAttribute,kAXTitleAttribute,kAXValueAttribute,kAXHelpAttribute,kAXDescriptionAttribute]
        .compactMap { key -> String? in guard let value=attribute(node,key) as? String,!value.isEmpty else {return nil};return "\(key)=\(value.prefix(180))" }
      lines.append(String(repeating:" ",count:depth)+role+" "+attrs.joined(separator:" | "))
      for child in attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? [] {visit(child,depth+1)}
    }
    visit(AXUIElementCreateApplication(app.processIdentifier),0)
    return lines.joined(separator:"\n")
  }

  public static func type(_ text: String, intervalMilliseconds: Int) throws {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    for character in text {
      let units = Array(String(character).utf16)
      guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw DriverError.eventSourceUnavailable }
      units.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
      }
      down.flags = []; up.flags = []
      down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000)
    }
  }

  public static func scroll(bundleIdentifier: String, identifier: String, pixels: Int) throws {
    try move(to: center(of: element(bundleIdentifier: bundleIdentifier, identifier: identifier)))
    for _ in 0..<12 {
      guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(pixels / 12), wheel2: 0, wheel3: 0)
      else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.025)
    }
  }

  public static func value(bundleIdentifier: String, identifier: String) throws -> String {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard let value = attribute(target, kAXValueAttribute) as? String else {
      throw InteractionError("native control value is unavailable: \(identifier)")
    }
    return value
  }

  /// AX exposes controls outside a scroll viewport too. Scroll them into view
  /// before posting a real mouse event; an offscreen coordinate is not a click.
  private static func reveal(_ target:AXUIElement) throws {
    var ancestors:[AXUIElement]=[]
    var node=target
    for _ in 0..<24 {
      guard let raw=attribute(node,kAXParentAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {break}
      node=unsafeDowncast(raw,to:AXUIElement.self)
      // A popup menu floats above its owner's scroll view; scrolling that
      // view cannot reveal a submenu item and can instead close the menu.
      if attribute(node,kAXRoleAttribute) as? String == kAXMenuRole { return }
      if attribute(node,kAXRoleAttribute) as? String == kAXScrollAreaRole {ancestors.append(node)}
    }
    for ancestor in ancestors.reversed() {
      var visible=false
      for _ in 0..<10 {
        let frame=try bounds(of:target)
        let viewport=try bounds(of:ancestor).insetBy(dx:6,dy:12)
        if viewport.contains(CGPoint(x:frame.midX,y:frame.midY)) {visible=true;break}
        let delta:Double
        if frame.midY>viewport.maxY {delta = -min(400,max(100,frame.maxY-viewport.maxY+24))}
        else if frame.midY<viewport.minY {delta = min(400,max(100,viewport.minY-frame.minY+24))}
        else {throw InteractionError("control is outside the horizontal viewport")}
        try move(to:CGPoint(x:viewport.midX,y:viewport.midY))
        for _ in 0..<8 {
          guard let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:Int32(delta/8),wheel2:0,wheel3:0) else {throw DriverError.eventSourceUnavailable}
          event.flags=[];event.post(tap:.cghidEventTap)
          Thread.sleep(forTimeInterval:0.025)
        }
        Thread.sleep(forTimeInterval:0.18)
      }
      guard visible else {throw InteractionError("control did not scroll into view")}
    }
  }

  private static func element(bundleIdentifier: String, identifier: String) throws -> AXUIElement {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
      throw InteractionError("app is not running: \(bundleIdentifier)")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    repeat {
      if let found = search(root, identifier: identifier, depth: 0) { return found }
      Thread.sleep(forTimeInterval: 0.08)
    } while ContinuousClock.now < deadline
    throw InteractionError("native control not found: \(bundleIdentifier) / \(identifier)")
  }
  private static func search(_ element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
    guard depth < 30 else { return nil }
    let selectors=["title:":kAXTitleAttribute,"help:":kAXHelpAttribute,"text:":kAXValueAttribute,"description:":kAXDescriptionAttribute]
    let roleSelectors = ["button:": kAXButtonRole, "heading:": "AXHeading"]
    if let selector = roleSelectors.first(where: { identifier.hasPrefix($0.key) }) {
      let label = String(identifier.dropFirst(selector.key.count))
      if attribute(element, kAXRoleAttribute) as? String == selector.value,
         [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { attribute(element, $0) as? String == label }) {
        return element
      }
    } else if let selector=selectors.first(where:{identifier.hasPrefix($0.key)}) {
      if attribute(element,selector.value) as? String == String(identifier.dropFirst(selector.key.count)) {return element}
    } else if attribute(element,kAXIdentifierAttribute) as? String == identifier {return element}
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
      if let found = search(child, identifier: identifier, depth: depth + 1) { return found }
    }
    return nil
  }
  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }
  private static func center(of element:AXUIElement) throws -> CGPoint {
    let frame=try bounds(of:element);return CGPoint(x:frame.midX,y:frame.midY)
  }
  private static func bounds(of element: AXUIElement) throws -> CGRect {
    guard let rawPosition = attribute(element, kAXPositionAttribute),
          let rawSize = attribute(element, kAXSizeAttribute),
          CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { throw InteractionError("control has no accessible bounds") }
    var position = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0
    else { throw InteractionError("control has invalid bounds") }
    return CGRect(origin:position,size:size)
  }
  private static func move(to point: CGPoint) throws {
    guard let start = CGEvent(source: nil)?.location else { throw DriverError.eventSourceUnavailable }
    for step in 1...18 {
      let t = Double(step) / 18
      let eased = t * t * (3 - 2 * t)
      let next = CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased)
      guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left)
      else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.012)
    }
  }
}
public struct InteractionError: Error, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}
