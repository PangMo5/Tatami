// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - NativeInteractionDriver

/// Drives the fixture apps through their native controls. No model-state injection.
@MainActor
public enum NativeInteractionDriver {

  // MARK: Public

  public static func frontmostBundleIdentifier() -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) ==
      .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }

  public static func click(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    let point = try center(of: target)
    // Enter the open submenu horizontally before moving down its rows.
    // A diagonal path through a sibling parent item can close this submenu.
    if
      attribute(target, kAXRoleAttribute) as? String == kAXMenuItemRole,
      let rawParent = attribute(target, kAXParentAttribute),
      CFGetTypeID(rawParent) == AXUIElementGetTypeID(),
      let cursor = CGEvent(source: nil)?.location
    {
      let menu = unsafeDowncast(rawParent, to: AXUIElement.self)
      let frame = try bounds(of: menu)
      if !frame.contains(cursor) {
        try move(to: CGPoint(x: point.x, y: min(max(cursor.y, frame.minY + 5), frame.maxY - 5)))
      }
    }
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
    guard
      let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
      let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    up.flags = []
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

  public static func clickWindowTitle(bundleIdentifier: String) throws {
    let frame = try windowFrame(bundleIdentifier: bundleIdentifier)
    try clickPoint(CGPoint(x: frame.midX, y: frame.minY + 14))
  }

  public static func controlFrame(bundleIdentifier: String, identifier: String) throws -> CGRect {
    try bounds(of: element(
      bundleIdentifier: bundleIdentifier,
      identifier: identifier,
    ))
  }

  public static func hover(bundleIdentifier: String, identifier: String, durationMilliseconds: Int = 216) throws {
    guard (1...5_000).contains(durationMilliseconds) else {
      throw InteractionError("pointer movement duration must be 1...5000 milliseconds")
    }
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    try move(to: center(of: target), durationMilliseconds: durationMilliseconds)
  }

  /// Read visibility without revealing or scrolling the control. An AX node
  /// existing offscreen is not evidence that search navigation reached it.
  public static func isControlFullyVisible(bundleIdentifier: String, identifier: String) throws -> Bool {
    var node = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    let frame = try bounds(of: node)
    guard frame.width > 0, frame.height > 0 else { return false }
    for _ in 0..<30 {
      let role = attribute(node, kAXRoleAttribute) as? String
      if role == kAXScrollAreaRole || role == kAXWindowRole {
        guard try bounds(of: node).contains(frame) else { return false }
      }
      guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
      node = unsafeDowncast(parent, to: AXUIElement.self)
    }
    return true
  }

  public static func windowFrame(bundleIdentifier: String) throws -> CGRect {
    try bounds(of: identifiedWindow(bundleIdentifier: bundleIdentifier))
  }

  public static func closeWindow(bundleIdentifier: String) throws {
    let window = try identifiedWindow(bundleIdentifier: bundleIdentifier)
    guard
      let raw = attribute(window, kAXCloseButtonAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { throw InteractionError("window has no native close button") }
    try clickPoint(center(of: unsafeDowncast(raw, to: AXUIElement.self)))
  }

  public static func focusedWindowFrame(bundleIdentifier: String) throws -> CGRect {
    guard
      frontmostBundleIdentifier() == bundleIdentifier,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
      let raw = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { throw InteractionError("app has no focused window: \(bundleIdentifier)") }
    return try bounds(of: unsafeDowncast(raw, to: AXUIElement.self))
  }

  public static func isWindowFocused(bundleIdentifier: String, identifier: String) -> Bool {
    guard
      frontmostBundleIdentifier() == bundleIdentifier,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
      let raw = attribute(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { return false }
    return attribute(unsafeDowncast(raw, to: AXUIElement.self), kAXIdentifierAttribute) as? String == identifier
  }

  public static func drag(from: CGPoint, to: CGPoint) throws {
    try move(to: from)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.12)
    for step in 1...40 {
      let t = Double(step) / 40
      let eased = t * t * (3 - 2 * t)
      let point = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
      guard let drag = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDragged,
        mouseCursorPosition: point,
        mouseButton: .left,
      ) else { throw DriverError.eventSourceUnavailable }
      drag.flags = []
      drag.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.018)
    }
    Thread.sleep(forTimeInterval: 0.35)
    guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    up.flags = []
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.5)
  }

  public static func snapshot(bundleIdentifier: String) throws -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else { throw InteractionError("app is not running") }
    var lines = [String]()
    func visit(_ node: AXUIElement, _ depth: Int) {
      guard depth < 24, lines.count < 650 else { return }
      let role = attribute(node, kAXRoleAttribute) as? String ?? "?"
      let attrs = [kAXIdentifierAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute, kAXDescriptionAttribute]
        .compactMap { key -> String? in guard let value = attribute(node, key) as? String,!value.isEmpty else { return nil }
          return "\(key)=\(value.prefix(180))"
        }
      lines.append(String(repeating: " ", count: depth) + role + " " + attrs.joined(separator: " | "))
      for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
    }
    visit(AXUIElementCreateApplication(app.processIdentifier), 0)
    return lines.joined(separator: "\n")
  }

  public static func type(_ text: String, intervalMilliseconds: Int) throws {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    for character in text {
      let units = Array(String(character).utf16)
      guard
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw DriverError.eventSourceUnavailable }
      units.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
      }
      down.flags = []
      up.flags = []
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000)
    }
  }

  public static func scroll(bundleIdentifier: String, identifier: String, pixels: Int) throws {
    try move(to: center(of: element(bundleIdentifier: bundleIdentifier, identifier: identifier)))
    for _ in 0..<12 {
      guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: Int32(pixels / 12),
        wheel2: 0,
        wheel3: 0,
      ) else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.025)
    }
  }

  public static func isEnabled(bundleIdentifier: String, identifier: String) throws -> Bool {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard let enabled = attribute(target, kAXEnabledAttribute) as? Bool else {
      throw InteractionError("native control enabled state is unavailable: \(identifier)")
    }
    return enabled
  }

  public static func value(bundleIdentifier: String, identifier: String) throws -> String {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard let value = attribute(target, kAXValueAttribute) as? String else {
      throw InteractionError("native control value is unavailable: \(identifier)")
    }
    return value
  }

  // MARK: Private

  private static func identifiedWindow(bundleIdentifier: String) throws -> AXUIElement {
    if bundleIdentifier == "dev.PangMo5.Tatami" || bundleIdentifier == "dev.PangMo5.Tatami.debug" {
      return try element(bundleIdentifier: bundleIdentifier, identifier: "main")
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else { throw InteractionError("app is not running") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard
      let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
      // Hidden or occluded SwiftUI content may have no AX descendants. The
      // fixture assigns identity to NSWindow itself at creation time.
      let window = windows
        .first(where: { (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix(bundleIdentifier + ".window.") == true })
    else { throw InteractionError("app has no identified demo window") }
    return window
  }

  private static func clickPoint(_ point: CGPoint) throws {
    try move(to: point)
    guard
      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.12)
  }

  /// AX exposes controls outside a scroll viewport too. Scroll them into view
  /// before posting a real mouse event; an offscreen coordinate is not a click.
  private static func reveal(_ target: AXUIElement) throws {
    var ancestors = [AXUIElement]()
    var node = target
    for _ in 0..<24 {
      guard let raw = attribute(node, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
      node = unsafeDowncast(raw, to: AXUIElement.self)
      // A popup menu floats above its owner's scroll view; scrolling that
      // view cannot reveal a submenu item and can instead close the menu.
      if attribute(node, kAXRoleAttribute) as? String == kAXMenuRole {
        return
      }
      if attribute(node, kAXRoleAttribute) as? String == kAXScrollAreaRole {
        ancestors.append(node)
      }
    }
    for ancestor in ancestors.reversed() {
      var visible = false
      for _ in 0..<10 {
        let frame = try bounds(of: target)
        let viewport = try bounds(of: ancestor).insetBy(dx: 6, dy: 12)
        if viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) {
          visible = true
          break
        }
        let delta: Double
        if frame.midY > viewport.maxY {
          delta = -min(400, max(100, frame.maxY - viewport.maxY + 24))
        } else if frame.midY < viewport.minY {
          delta = min(400, max(100, viewport.minY - frame.minY + 24))
        } else {
          throw InteractionError("control is outside the horizontal viewport")
        }
        try move(to: CGPoint(x: viewport.midX, y: viewport.midY))
        for _ in 0..<8 {
          guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(delta / 8),
            wheel2: 0,
            wheel3: 0,
          ) else { throw DriverError.eventSourceUnavailable }
          event.flags = []
          event.post(tap: .cghidEventTap)
          Thread.sleep(forTimeInterval: 0.025)
        }
        Thread.sleep(forTimeInterval: 0.18)
      }
      guard visible else { throw InteractionError("control did not scroll into view") }
    }
  }

  private static func element(bundleIdentifier: String, identifier: String) throws -> AXUIElement {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
      throw InteractionError("app is not running: \(bundleIdentifier)")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let windowScoped = identifier.hasPrefix("window:")
    let selector = windowScoped ? String(identifier.dropFirst(7)) : identifier
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    var foundWithoutBounds = false
    repeat {
      let roots = windowScoped ? (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []) : [root]
      if let found = roots.lazy.compactMap({ search($0, identifier: selector, depth: 0) }).first {
        // SwiftUI can publish a new AX node before its first layout pass.
        // Resolve it again until it has real geometry for native input.
        if (try? bounds(of: found)) != nil {
          return found
        }
        foundWithoutBounds = true
      }
      Thread.sleep(forTimeInterval: 0.08)
    } while
      ContinuousClock.now < deadline
    if foundWithoutBounds {
      throw InteractionError("native control has no rendered bounds: \(bundleIdentifier) / \(identifier)")
    }
    throw InteractionError("native control not found: \(bundleIdentifier) / \(identifier)")
  }

  private static func search(_ element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
    guard depth < 30 else { return nil }
    if identifier.hasPrefix("sheet:") {
      if attribute(element, kAXRoleAttribute) as? String == kAXSheetRole {
        return search(element, identifier: String(identifier.dropFirst(6)), depth: depth + 1)
      }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = search(child, identifier: identifier, depth: depth + 1) {
          return found
        }
      }
      return nil
    }
    let selectors = [
      "title:": kAXTitleAttribute,
      "help:": kAXHelpAttribute,
      "text:": kAXValueAttribute,
      "description:": kAXDescriptionAttribute,
    ]
    let roleSelectors = ["button:": kAXButtonRole, "heading:": "AXHeading"]
    if let selector = roleSelectors.first(where: { identifier.hasPrefix($0.key) }) {
      let label = String(identifier.dropFirst(selector.key.count))
      if
        attribute(element, kAXRoleAttribute) as? String == selector.value,
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
          .contains(where: { attribute(element, $0) as? String == label })
      {
        return element
      }
    } else if let selector = selectors.first(where: { identifier.hasPrefix($0.key) }) {
      if attribute(element, selector.value) as? String == String(identifier.dropFirst(selector.key.count)) {
        return element
      }
    } else if attribute(element, kAXIdentifierAttribute) as? String == identifier {
      return element
    }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
      if let found = search(child, identifier: identifier, depth: depth + 1) {
        return found
      }
    }
    return nil
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func center(of element: AXUIElement) throws -> CGPoint {
    let frame = try bounds(of: element)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  private static func bounds(of element: AXUIElement) throws -> CGRect {
    guard
      let rawPosition = attribute(element, kAXPositionAttribute),
      let rawSize = attribute(element, kAXSizeAttribute),
      CFGetTypeID(rawPosition) == AXValueGetTypeID(),
      CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { throw InteractionError("control has no accessible bounds") }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size),
      size.width > 0,
      size.height > 0
    else { throw InteractionError("control has invalid bounds") }
    return CGRect(origin: position, size: size)
  }

  private static func move(to point: CGPoint, durationMilliseconds: Int = 216) throws {
    guard let start = CGEvent(source: nil)?.location else { throw DriverError.eventSourceUnavailable }
    let steps = max(18, durationMilliseconds / 12)
    for step in 1...steps {
      let t = Double(step) / Double(steps)
      let eased = t * t * (3 - 2 * t)
      let next = CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased)
      guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left)
      else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: Double(durationMilliseconds) / Double(steps) / 1_000)
    }
  }

}

// MARK: - InteractionError

public struct InteractionError: Error, CustomStringConvertible {
  public init(_ description: String) {
    self.description = description
  }

  public let description: String
}
