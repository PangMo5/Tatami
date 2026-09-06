// swift-tools-version: 6.0

// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

// Tatami Demo Lab.
//
// Deliberately a *standalone* SwiftPM package with zero external dependencies:
// `swift build` works offline with only the Command Line Tools, and nothing
// here can reach the product's Tuist graph. Tuist resolves its root as the
// closest directory containing `Tuist/` or `.git/`, so a nested Tuist manifest
// would have shared the app's dependency resolution — this does not.
let package = Package(
  name: "TatamiDemoLab",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "democtl", targets: ["democtl"]),
    .executable(name: "demokey", targets: ["demokey"]),
    .executable(name: "DemoRecorder", targets: ["DemoRecorder"]),
    .executable(name: "demoicon", targets: ["demoicon"]),
    .executable(name: "Canvas", targets: ["Canvas"]),
    .executable(name: "demohook", targets: ["demohook"]),
    .executable(name: "Editor", targets: ["Editor"]),
    .executable(name: "Terminal", targets: ["Terminal"]),
    .executable(name: "Review", targets: ["Review"]),
    .executable(name: "Docs", targets: ["Docs"]),
    .executable(name: "Chat", targets: ["Chat"]),
    .executable(name: "Notes", targets: ["Notes"]),
    .executable(name: "Monitor", targets: ["Monitor"]),
    .executable(name: "DemoOverlay", targets: ["DemoOverlay"]),
  ],
  targets: [
    // Shared window shell, catalog, and deterministic fixtures for the demo apps.
    .target(name: "DemoAppKit", path: "Sources/DemoAppKit"),

    .executableTarget(name: "Canvas", dependencies: ["DemoAppKit"], path: "Sources/Apps/Canvas"),
    .executableTarget(name: "demohook", dependencies: ["DemoAppKit"], path: "Sources/demohook"),
    .executableTarget(name: "Editor", dependencies: ["DemoAppKit"], path: "Sources/Apps/Editor"),
    .executableTarget(name: "Terminal", dependencies: ["DemoAppKit"], path: "Sources/Apps/Terminal"),
    .executableTarget(name: "Review", dependencies: ["DemoAppKit"], path: "Sources/Apps/Review"),
    .executableTarget(name: "Docs", dependencies: ["DemoAppKit"], path: "Sources/Apps/Docs"),
    .executableTarget(name: "Chat", dependencies: ["DemoAppKit"], path: "Sources/Apps/Chat"),
    .executableTarget(name: "Notes", dependencies: ["DemoAppKit"], path: "Sources/Apps/Notes"),
    .executableTarget(name: "Monitor", dependencies: ["DemoAppKit"], path: "Sources/Apps/Monitor"),

    // The caption and keystroke overlay. Never assigned to a workspace and never
    // tiled: it rides above the demo on its own window level, and Tatami is told
    // about it through `settings.visibility.overlayAwareApps`.
    .executableTarget(name: "DemoOverlay", dependencies: ["DemoAppKit"], path: "Sources/DemoOverlay"),

    // Synthesizes real key events for Tatami's *published* shortcuts. It never
    // touches Tatami state directly.
    .target(name: "DemoDriverKit", path: "Sources/DemoDriverKit"),
    .executableTarget(name: "demokey", dependencies: ["DemoDriverKit"], path: "Sources/demokey"),

    // ScreenCaptureKit -> AVAssetWriter screen recorder.
    .target(name: "DemoRecorderKit", path: "Sources/DemoRecorderKit"),
    .executableTarget(
      name: "DemoRecorder",
      dependencies: ["DemoRecorderKit"],
      path: "Sources/DemoRecorder"
    ),

    // Renders app icons from SF Symbols at build time so the demo apps are
    // distinguishable in the Dock, the app switcher, and Tatami's own HUD.
    .executableTarget(name: "demoicon", dependencies: ["DemoAppKit"], path: "Sources/demoicon"),

    // Orchestration: config rendering, deterministic reset, app lifecycle,
    // scene playback, recorder control.
    .target(name: "DemoCtlKit", dependencies: ["DemoAppKit", "DemoDriverKit"], path: "Sources/DemoCtlKit"),
    .executableTarget(name: "democtl", dependencies: ["DemoCtlKit"], path: "Sources/democtl"),

    .testTarget(
      name: "DemoLabTests",
      dependencies: ["DemoCtlKit", "DemoAppKit", "DemoDriverKit"],
      path: "Tests/DemoLabTests"
    ),
  ]
)
