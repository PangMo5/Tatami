import ProjectDescription

let bundleIdPrefix = "dev.PangMo5"
let deploymentTarget: DeploymentTargets = .macOS("14.0")

// Injected at `tuist generate` time. Set these locally in `.mise.local.toml`
// (TUIST_DEVELOPMENT_TEAM, …); in CI they come from repository secrets.
let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")
// Single source of truth for the marketing version. The release workflow
// verifies the pushed tag matches this before building.
let appVersion = "0.1.0"
// Build number is injected by CI (github.run_number); 1 for local builds.
let buildNumber = Environment.buildNumber.getString(default: "1")

let baseSettings: SettingsDictionary = [
  "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
  "SWIFT_VERSION": "6.0",
  "SWIFT_STRICT_CONCURRENCY": "complete",
  "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
  "DEAD_CODE_STRIPPING": "YES",
  // Sign with the developer's Apple Development cert locally so the binary
  // hash stays stable across rebuilds (otherwise macOS re-prompts for every
  // TCC permission). The release workflow overrides this with Developer ID.
  "CODE_SIGN_STYLE": "Automatic",
  "CODE_SIGN_IDENTITY": "Apple Development",
  // Hardened Runtime conflicts with development entitlements; off for local
  // debug builds. The release archive turns it back on for notarization.
  "ENABLE_HARDENED_RUNTIME": "NO",
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
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSUIElement": true,
        "LSApplicationCategoryType": "public.app-category.productivity",
        "CFBundleDisplayName": "Tatami",
        "NSHumanReadableCopyright":
          "© 2026 PangMo5. Released under GPL-3.0. Inspired by FlashSpace and yabai.",
        "SUFeedURL": "https://pangmo5.github.io/Tatami/appcast.xml",
        "SUEnableAutomaticChecks": true,
        "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
      ]),
      sources: ["Tatami/Sources/**"],
      resources: ["Tatami/Resources/**"],
      entitlements: .file(path: "Tatami/Tatami.entitlements"),
      dependencies: [
        .target(name: "TatamiKit"),
        .target(name: "TatamiCLIProtocol"),
        .external(name: "Sparkle"),
        .external(name: "SFSafeSymbols"),
      ],
      settings: .settings(base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
        "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
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
        .external(name: "KeyboardShortcuts"),
        .external(name: "TOML"),
      ]
    ),
    .target(
      name: "TatamiCLIProtocol",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "\(bundleIdPrefix).Tatami.CLIProtocol",
      deploymentTargets: deploymentTarget,
      sources: ["TatamiCLIProtocol/Sources/**"],
      dependencies: []
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
