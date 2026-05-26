// swift-tools-version: 6.0
import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(
    productTypes: [
      "ComposableArchitecture": .framework,
      "Sharing": .framework,
      "KarrotCodableKit": .framework,
      "Sparkle": .framework,
      "KeyboardShortcuts": .framework,
      "TOML": .framework,
    ]
  )
#endif

let package = Package(
  name: "Tatami",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.20.0"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.5.0"),
    .package(url: "https://github.com/daangn/KarrotCodableKit", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", branch: "main"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
  ]
)
