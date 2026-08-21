// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  // All defaults (static): each dependency links into the target that uses
  // it, so nothing ships as an embedded dynamic framework — fast launch, and
  // the `tatami` CLI can resolve its deps. Sparkle stays a dynamic embed
  // (it's a binary xcframework). Mirrors the sibling SwiftyCrow project.
  let packageSettings = PackageSettings(
    productTypes: [:]
  )
#endif

let package = Package(
  name: "Tatami",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.20.0"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    .package(url: "https://github.com/Clipy/Magnet", from: "3.5.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.5.1"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "5.3.0"),
    .package(url: "https://github.com/mattt/swift-yyjson", from: "0.6.0"),
  ]
)
