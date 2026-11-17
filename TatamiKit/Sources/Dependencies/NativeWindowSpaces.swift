// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

// MARK: - NativeWindowSpaces

/// Window assignment and Desktop navigation are separate OS operations. The
/// bridged operation works without Dock injection on current macOS versions:
/// https://github.com/asmvik/yabai/issues/2788
/// https://github.com/ejbills/DockDoor/blob/baf6425a981b09acb79189ec568e7c189b70a0ce/DockDoor/Utilities/PrivateApis.swift
/// Only ManagedDesktopNavigator's serial IPC worker uses this driver.
final class NativeWindowSpaces: @unchecked Sendable {

  // MARK: Lifecycle

  init() {
    handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    connection = handle.flatMap { dlsym($0, "SLSMainConnectionID") }.map {
      unsafeBitCast($0, to: Connection.self)()
    } ?? 0
    copy = handle.flatMap { dlsym($0, "SLSCopySpacesForWindows") }.map {
      unsafeBitCast($0, to: Copy.self)
    }
  }

  // MARK: Internal

  /// Only a single ordinary Space belonging to this monitor is movable.
  /// Sticky windows and every other monitor's windows retain their placement.
  static func needsMove(_ spaces: [UInt64], on display: DesktopSpaces.Display, home: UInt64) -> Bool {
    display.userDesktops.contains(home) && spaces.count == 1 && spaces[0] != home && display.userDesktops.contains(spaces[0])
  }

  func spaces(for windowID: UInt32) throws -> [UInt64] {
    guard
      connection != 0,
      let copy,
      let raw = copy(connection, 7, [windowID] as CFArray)?.takeRetainedValue(),
      let spaces = raw as? [UInt64]
    else {
      throw SymbolicDesktopShortcut.Failure("The window's native Desktop could not be read")
    }
    return spaces
  }

  func beginMove(_ windows: [UInt32], to home: UInt64) throws -> NativeWindowMove {
    guard
      !windows.isEmpty,
      let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
    else {
      throw SymbolicDesktopShortcut.Failure("Native window assignment is unavailable on this macOS version")
    }
    let allocSelector = NSSelectorFromString("alloc")
    let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
    let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
    guard
      let alloc = class_getClassMethod(cls, allocSelector),
      let initializer = class_getInstanceMethod(cls, initSelector),
      let perform = class_getInstanceMethod(cls, performSelector)
    else {
      throw SymbolicDesktopShortcut.Failure("Native window assignment methods are unavailable")
    }
    typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
    typealias Perform = @convention(c) (AnyObject, Selector) -> Void
    let allocate = unsafeBitCast(method_getImplementation(alloc), to: Alloc.self)
    let initialize = unsafeBitCast(method_getImplementation(initializer), to: Initialize.self)
    guard
      let allocated = allocate(cls, allocSelector),
      let initialized = initialize(allocated.toOpaque(), initSelector, windows.map { NSNumber(value: $0) } as NSArray, home)
    else {
      throw SymbolicDesktopShortcut.Failure("The native window assignment could not be created")
    }
    // init consumes alloc's ownership. Retain that one owned object until the
    // asynchronous move is observed, including cancellation and error cleanup.
    let operation = initialized.takeRetainedValue()
    unsafeBitCast(method_getImplementation(perform), to: Perform.self)(operation, performSelector)
    return NativeWindowMove(operation)
  }

  // MARK: Private

  private typealias Connection = @convention(c) () -> Int32
  private typealias Copy = @convention(c) (Int32, UInt64, CFArray) -> Unmanaged<CFArray>?

  private let handle: UnsafeMutableRawPointer?
  private let connection: Int32
  private let copy: Copy?

}

// MARK: - NativeWindowMove

/// Created, used and released on the native preparation worker.
final class NativeWindowMove: @unchecked Sendable {

  // MARK: Lifecycle

  init(_ operation: AnyObject) {
    self.operation = operation
  }

  // MARK: Private

  private let operation: AnyObject

}
