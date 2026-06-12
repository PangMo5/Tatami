// swift-tools-version: 6.0
import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(
    productTypes: [
      "ComposableArchitecture": .framework,
      "Sharing": .framework,
      "Dependencies": .framework,
      "DependenciesMacros": .framework,
      "IssueReporting": .framework,
      "PerceptionCore": .framework,
      "Perception": .framework,
      "ConcurrencyExtras": .framework,
      "CombineSchedulers": .framework,
      "CustomDump": .framework,
      "IdentifiedCollections": .framework,
      "OrderedCollections": .framework,
      "CasePaths": .framework,
      "CasePathsCore": .framework,
      "Clocks": .framework,
      "Sparkle": .framework,
      "KeyboardShortcuts": .framework,
      "TOML": .framework,
      "SFSafeSymbols": .framework,
      // Static (the Tuist default): the `tatami` command-line tool links
      // YYJSON, and a command-line tool can't embed/resolve a dynamic
      // framework at runtime (dyld can't find YYJSON.framework). Static
      // linking also works for the app, which links it via TatamiKit.
    ],
    targetSettings: [
      // KeyboardShortcuts (pinned to `main`) crashes the Swift optimizer in
      // Release builds — SIL EarlyPerfInliner on the NSMenuItem WeakReference
      // deinit (NSMenuItem++.swift). Disable optimization for just this
      // package to dodge the compiler bug; it's tiny, so there's no
      // meaningful perf cost.
      "KeyboardShortcuts": ["SWIFT_OPTIMIZATION_LEVEL": "-Onone"],
    ]
  )
#endif

let package = Package(
  name: "Tatami",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.20.0"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.5.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", branch: "main"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.5.1"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "5.3.0"),
    .package(url: "https://github.com/mattt/swift-yyjson", from: "0.6.0"),
  ]
)
