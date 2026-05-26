import ProjectDescription

let bundleIdPrefix = "dev.PangMo5"
let deploymentTarget: DeploymentTargets = .macOS("14.0")

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": "$(XCODE_DEVELOPMENT_TEAM)",
  "SWIFT_VERSION": "6.0",
  "SWIFT_STRICT_CONCURRENCY": "complete",
  "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
  "DEAD_CODE_STRIPPING": "YES",
  "ENABLE_HARDENED_RUNTIME": "YES",
]

let project = Project(
  name: "Tatami",
  organizationName: "PangMo5",
  options: .options(
    automaticSchemesOptions: .enabled(),
    defaultKnownRegions: ["en"],
    developmentRegion: "en"
  ),
  settings: .settings(base: baseSettings),
  targets: [
    .target(
      name: "Tatami",
      destinations: .macOS,
      product: .app,
      bundleId: "\(bundleIdPrefix).Tatami",
      deploymentTargets: deploymentTarget,
      infoPlist: .extendingDefault(with: [
        "LSUIElement": true,
        "LSApplicationCategoryType": "public.app-category.productivity",
        "CFBundleDisplayName": "Tatami",
        "NSHumanReadableCopyright":
          "© 2025 Wojciech Kulik. Tatami © 2026 PangMo5. Released under GPL-3.0.",
        "SUFeedURL": "https://raw.githubusercontent.com/PangMo5/Tatami/main/appcast.xml",
      ]),
      sources: ["Tatami/Sources/**"],
      resources: ["Tatami/Resources/**"],
      entitlements: .file(path: "Tatami/Tatami.entitlements"),
      dependencies: [
        .target(name: "TatamiKit"),
        .target(name: "TatamiCLIProtocol"),
        .external(name: "Sparkle"),
      ],
      settings: .settings(base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
      ])
    ),
    .target(
      name: "TatamiKit",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "\(bundleIdPrefix).Tatami.Kit",
      deploymentTargets: deploymentTarget,
      sources: ["TatamiKit/Sources/**"],
      dependencies: [
        .target(name: "TatamiCLIProtocol"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Sharing"),
        .external(name: "SQLiteData"),
        .external(name: "KarrotCodableKit"),
        .external(name: "KeyboardShortcuts"),
      ]
    ),
    .target(
      name: "TatamiCLIProtocol",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "\(bundleIdPrefix).Tatami.CLIProtocol",
      deploymentTargets: deploymentTarget,
      sources: ["TatamiCLIProtocol/Sources/**"],
      dependencies: [
        .external(name: "KarrotCodableKit"),
      ]
    ),
    .target(
      name: "TatamiCLI",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "\(bundleIdPrefix).tatami.cli",
      deploymentTargets: deploymentTarget,
      sources: ["TatamiCLI/Sources/**"],
      dependencies: [
        .target(name: "TatamiCLIProtocol"),
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(base: [
        "PRODUCT_NAME": "tatami",
      ])
    ),
    .target(
      name: "TatamiTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "\(bundleIdPrefix).Tatami.Tests",
      deploymentTargets: deploymentTarget,
      sources: ["TatamiTests/Sources/**"],
      dependencies: [
        .target(name: "TatamiKit"),
        .external(name: "ComposableArchitecture"),
      ]
    ),
  ]
)
