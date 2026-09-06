// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import DemoAppKit
import Foundation

// MARK: - IconSlot

/// One rung of the `.icns` ladder: the file stem `iconutil` expects and the
/// real pixel edge it must be rendered at.
struct IconSlot {
  let name: String
  let pixels: Int
}

// MARK: - IconError

enum IconError: Error, CustomStringConvertible {

  /// A missing symbol is fatal on purpose. A generic fallback glyph would ship
  /// a wrong-looking app into a recording, and nobody would notice until the
  /// take is already cut.
  case missingSymbol(app: String, symbol: String)
  case renderFailed(app: String, detail: String)
  case writeFailed(path: String, detail: String)

  // MARK: Internal

  var description: String {
    switch self {
    case let .missingSymbol(app, symbol):
      "\(app): SF Symbol '\(symbol)' is unavailable on this macOS version"
    case let .renderFailed(app, detail):
      "\(app): \(detail)"
    case let .writeFailed(path, detail):
      "cannot write \(path): \(detail)"
    }
  }

}

// MARK: - Geometry

/// macOS icon proportions: the art sits inside a transparent margin, and its
/// corner radius is a fixed fraction of the art itself.
let artFraction: CGFloat = 0.80
let cornerFraction: CGFloat = 0.225
/// The glyph is measured against the full canvas, not the art, so it keeps the
/// same optical weight as the system icons it sits next to.
let symbolFraction: CGFloat = 0.54

let iconSlots: [IconSlot] = [
  IconSlot(name: "icon_16x16", pixels: 16),
  IconSlot(name: "icon_16x16@2x", pixels: 32),
  IconSlot(name: "icon_32x32", pixels: 32),
  IconSlot(name: "icon_32x32@2x", pixels: 64),
  IconSlot(name: "icon_128x128", pixels: 128),
  IconSlot(name: "icon_128x128@2x", pixels: 256),
  IconSlot(name: "icon_256x256", pixels: 256),
  IconSlot(name: "icon_256x256@2x", pixels: 512),
  IconSlot(name: "icon_512x512", pixels: 512),
  IconSlot(name: "icon_512x512@2x", pixels: 1024),
]

// MARK: - Rendering

/// A bitmap whose point size equals its pixel size, so every rect below is in
/// real pixels and the screen's backing scale never enters the render.
@MainActor
func makeCanvas(pixels: Int) -> NSBitmapImageRep? {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ) else { return nil }
  rep.size = NSSize(width: pixels, height: pixels)
  return rep
}

@MainActor
func draw(into rep: NSBitmapImageRep, _ body: () -> Void) -> Bool {
  guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = context
  body()
  context.flushGraphics()
  return true
}

/// The glyph on its own transparent layer. Tinting happens here, where the
/// layer is empty, so `.sourceAtop` repaints exactly the glyph and nothing of
/// the background it will later sit on.
@MainActor
func symbolLayer(spec: DemoAppSpec, pixels: Int) throws -> NSImage {
  guard let symbol = NSImage(systemSymbolName: spec.symbolName, accessibilityDescription: spec.name) else {
    throw IconError.missingSymbol(app: spec.name, symbol: spec.symbolName)
  }
  let side = CGFloat(pixels)
  let box = side * symbolFraction
  let configuration = NSImage.SymbolConfiguration(pointSize: box, weight: .semibold, scale: .medium)
  let sized = symbol.withSymbolConfiguration(configuration) ?? symbol
  let natural = sized.size
  guard natural.width > 0, natural.height > 0 else {
    throw IconError.renderFailed(app: spec.name, detail: "symbol '\(spec.symbolName)' has an empty size")
  }
  guard let layer = makeCanvas(pixels: pixels) else {
    throw IconError.renderFailed(app: spec.name, detail: "cannot allocate a \(pixels)px symbol layer")
  }

  // Fit the glyph's own aspect ratio inside the box rather than stretching it.
  let scale = min(box / natural.width, box / natural.height)
  let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
  let rect = NSRect(
    x: (side - drawn.width) / 2,
    y: (side - drawn.height) / 2,
    width: drawn.width,
    height: drawn.height
  )
  let rendered = draw(into: layer) {
    sized.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
  }
  guard rendered else {
    throw IconError.renderFailed(app: spec.name, detail: "no graphics context for the \(pixels)px symbol layer")
  }
  let image = NSImage(size: NSSize(width: side, height: side))
  image.addRepresentation(layer)
  return image
}

@MainActor
func renderPNG(spec: DemoAppSpec, pixels: Int) throws -> Data {
  let layer = try symbolLayer(spec: spec, pixels: pixels)
  guard let canvas = makeCanvas(pixels: pixels) else {
    throw IconError.renderFailed(app: spec.name, detail: "cannot allocate a \(pixels)px canvas")
  }
  let side = CGFloat(pixels)
  let art = side * artFraction
  let artRect = NSRect(x: (side - art) / 2, y: (side - art) / 2, width: art, height: art)
  let radius = art * cornerFraction
  let accent = NSColor(
    srgbRed: CGFloat(spec.accent.red),
    green: CGFloat(spec.accent.green),
    blue: CGFloat(spec.accent.blue),
    alpha: 1
  )
  let rendered = draw(into: canvas) {
    accent.setFill()
    NSBezierPath(roundedRect: artRect, xRadius: radius, yRadius: radius).fill()
    // Explicitly `.sourceOver`: an image rep drawn bare composites with copy
    // semantics and its transparent margin would erase the accent behind it.
    layer.draw(
      in: NSRect(x: 0, y: 0, width: side, height: side),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
  }
  guard rendered else {
    throw IconError.renderFailed(app: spec.name, detail: "no graphics context for the \(pixels)px canvas")
  }
  guard let data = canvas.representation(using: .png, properties: [:]) else {
    throw IconError.renderFailed(app: spec.name, detail: "PNG encoding failed at \(pixels)px")
  }
  return data
}

// MARK: - Iconset

/// Rebuilds the directory from scratch so a renamed or dropped slot cannot
/// survive as a stale PNG that `iconutil` would happily bundle.
func prepareIconset(at url: URL) throws {
  let manager = FileManager.default
  if url.pathExtension == "iconset", manager.fileExists(atPath: url.path) {
    try manager.removeItem(at: url)
  }
  try manager.createDirectory(at: url, withIntermediateDirectories: true)
}

@MainActor
func writeIconset(spec: DemoAppSpec, to url: URL) throws {
  do {
    try prepareIconset(at: url)
  } catch let error as IconError {
    throw error
  } catch {
    throw IconError.writeFailed(path: url.path, detail: error.localizedDescription)
  }
  for slot in iconSlots {
    let data = try renderPNG(spec: spec, pixels: slot.pixels)
    let file = url.appendingPathComponent("\(slot.name).png")
    do {
      try data.write(to: file, options: .atomic)
    } catch {
      throw IconError.writeFailed(path: file.path, detail: error.localizedDescription)
    }
  }
  print("\(spec.name): \(iconSlots.count) PNGs -> \(url.path)")
}

// MARK: - Command line

let usage = """
usage: demoicon --app <Name> --out <dir.iconset>
       demoicon --all --out <dir>

Renders the SF Symbol from DemoCatalog onto the app's accent color at every
size an .icns needs. --all writes one <Name>.iconset per catalog app.

exit codes: 0 ok, 2 usage, 4 render failure
"""

func fail(_ message: String, code: Int32) -> Never {
  FileHandle.standardError.write(Data("demoicon: \(message)\n".utf8))
  exit(code)
}

// AppKit needs its shared application before symbol images resolve.
_ = NSApplication.shared

var requestedApp: String?
var outPath: String?
var renderAll = false
var arguments = Array(CommandLine.arguments.dropFirst())

while let argument = arguments.first {
  arguments.removeFirst()
  switch argument {
  case "--help", "-h":
    print(usage)
    exit(0)
  case "--all":
    renderAll = true
  case "--app":
    guard let value = arguments.first else { fail("--app needs a value\n\n\(usage)", code: 2) }
    arguments.removeFirst()
    requestedApp = value
  case "--out":
    guard let value = arguments.first else { fail("--out needs a value\n\n\(usage)", code: 2) }
    arguments.removeFirst()
    outPath = value
  default:
    fail("unknown argument '\(argument)'\n\n\(usage)", code: 2)
  }
}

guard let outPath else { fail("--out is required\n\n\(usage)", code: 2) }
if renderAll, requestedApp != nil { fail("--all and --app are mutually exclusive\n\n\(usage)", code: 2) }
if !renderAll, requestedApp == nil { fail("one of --all or --app is required\n\n\(usage)", code: 2) }

let outURL = URL(fileURLWithPath: outPath).standardizedFileURL

do {
  if renderAll {
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    for spec in DemoCatalog.all {
      try writeIconset(spec: spec, to: outURL.appendingPathComponent("\(spec.name).iconset"))
    }
  } else if let requestedApp {
    guard let spec = DemoCatalog.spec(named: requestedApp) else {
      let known = DemoCatalog.all.map(\.name).joined(separator: ", ")
      fail("unknown app '\(requestedApp)' (known: \(known))", code: 2)
    }
    try writeIconset(spec: spec, to: outURL)
  }
} catch let error as IconError {
  fail(error.description, code: 4)
} catch {
  fail(error.localizedDescription, code: 4)
}
