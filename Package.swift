// swift-tools-version: 6.4

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import PackageDescription

let minimumMacOSVersion = "14.0"

/// Only final product links use the packager's SDK stamp. Compiler plugins and
/// other dependencies retain their own host deployment settings.
func productLinkerSettings() -> [LinkerSetting] {
  guard let sdk = ProcessInfo.processInfo.environment["TATAMI_LINK_SDK_VERSION"] else { return [] }
  return [.unsafeFlags(["-platform_version", "macos", minimumMacOSVersion, sdk].flatMap { ["-Xlinker", $0] })]
}

func cliInfoPlistSettings() -> [LinkerSetting] {
  guard let file = ProcessInfo.processInfo.environment["TATAMI_CLI_INFO_PLIST"] else { return [] }
  return [.unsafeFlags(["-sectcreate", "__TEXT", "__info_plist", file].flatMap { ["-Xlinker", $0] })]
}

/// Extraction is opt-in because the compiler requires existing output directories.
/// The packager and `make extract-localizations` prepare one directory per module.
func localizationSettings(_ module: String) -> [SwiftSetting] {
  guard let output = ProcessInfo.processInfo.environment["TATAMI_LOCALIZATION_OUTPUT"] else { return [] }
  let directory = URL(fileURLWithPath: output).appendingPathComponent(module).path
  return [.unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", directory])]
}

let package = Package(
  name: "Tatami",
  platforms: [.macOS(minimumMacOSVersion)],
  products: [
    .library(name: "TatamiKit", targets: ["TatamiKit"]),
    .library(name: "TatamiCLIProtocol", targets: ["TatamiCLIProtocol"]),
    // Keep product names distinct on case-insensitive macOS volumes.
    .executable(name: "TatamiApp", targets: ["Tatami"]),
    .executable(name: "tatami", targets: ["TatamiCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.10.1"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.17.2"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-perception", from: "2.0.12"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.7.3"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    .package(url: "https://github.com/Clipy/Magnet", from: "3.5.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.7.5"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
    .package(url: "https://github.com/SFSafeSymbols/SFSafeSymbols", from: "7.0.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
    .package(url: "https://github.com/mattt/swift-yyjson", from: "0.6.0"),
  ],
  targets: [
    .executableTarget(
      name: "Tatami",
      dependencies: [
        "TatamiKit",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "SFSafeSymbols", package: "SFSafeSymbols"),
      ],
      path: "Tatami/Sources",
      swiftSettings: localizationSettings("Tatami"),
      linkerSettings: productLinkerSettings()
        + [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])],
    ),
    .target(
      name: "TatamiKit",
      dependencies: [
        "TatamiCLIProtocol",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
        .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
        .product(name: "Perception", package: "swift-perception"),
        .product(name: "Magnet", package: "Magnet"),
        .product(name: "TOML", package: "swift-toml"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "YYJSON", package: "swift-yyjson"),
        .product(name: "OrderedCollections", package: "swift-collections"),
        .product(name: "DequeModule", package: "swift-collections"),
      ],
      path: "TatamiKit/Sources",
      swiftSettings: localizationSettings("TatamiKit"),
    ),
    .target(name: "TatamiCLIProtocol", path: "TatamiCLIProtocol/Sources"),
    .executableTarget(
      name: "TatamiCLI",
      dependencies: [
        "TatamiCLIProtocol",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "YYJSON", package: "swift-yyjson"),
      ],
      path: "TatamiCLI/Sources",
      linkerSettings: productLinkerSettings() + cliInfoPlistSettings(),
    ),
    .testTarget(
      name: "TatamiTests",
      dependencies: [
        "TatamiKit",
        "TatamiCLIProtocol",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
        .product(name: "Sharing", package: "swift-sharing"),
        .product(name: "TOML", package: "swift-toml"),
      ],
      path: "TatamiTests/Sources",
    ),
  ],
  swiftLanguageModes: [.v6],
)
