import ProjectDescription

let bundleIdPrefix = "dev.PangMo5"
let deploymentTarget: DeploymentTargets = .macOS("14.0")

// Injected at `tuist generate` time. Set these locally in `.mise.local.toml`
// (TUIST_DEVELOPMENT_TEAM, …); in CI they come from repository secrets.
let developmentTeam = Environment.developmentTeam.getString(default: "")
let sparklePublicEDKey = Environment.sparklePublicEdKey.getString(default: "")
// Single source of truth for the marketing version. The release workflow
// verifies the pushed tag matches this before building.
let appVersion = "1.3.0"
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
        "SUFeedURL": "https://pangmo5.dev/Tatami/appcast.xml",
        "SUEnableAutomaticChecks": true,
        "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
      ]),
      sources: ["Tatami/Sources/**"],
      // CHANGELOG.md ships in the bundle so About can show release notes.
      resources: ["Tatami/Resources/**", "CHANGELOG.md"],
      entitlements: .file(path: "Tatami/Tatami.entitlements"),
      scripts: [
        // Embed the `tatami` CLI (built by the TatamiCLI dependency) into the
        // app bundle's Resources, so Settings → Command Line can symlink it
        // onto PATH. The binary is already signed by its own target build, so
        // copying preserves its signature; the app's final code-sign seals it.
        .post(
          script: """
          set -euo pipefail
          SRC="${BUILT_PRODUCTS_DIR}/tatami"
          DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
          mkdir -p "${DEST}"
          cp -f "${SRC}" "${DEST}/tatami"
          """,
          name: "Embed Tatami CLI",
          inputPaths: ["$(BUILT_PRODUCTS_DIR)/tatami"],
          outputPaths: ["$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/tatami"]
        ),
      ],
      dependencies: [
        .target(name: "TatamiKit"),
        .target(name: "TatamiCLIProtocol"),
        // Build the CLI alongside the app so the embed script can copy it.
        .target(name: "TatamiCLI"),
        .external(name: "Sparkle"),
        .external(name: "SFSafeSymbols"),
      ],
      settings: .settings(base: [
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
        "SPARKLE_PUBLIC_ED_KEY": SettingValue(stringLiteral: sparklePublicEDKey),
        // Tuist defaults macOS app targets to ad-hoc ("-") signing, which
        // makes macOS re-prompt for every TCC permission on each rebuild
        // because the binary hash changes. Pin the target back to the
        // developer's Apple Development cert. The release workflow
        // overrides these with the Developer ID identity.
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": "Apple Development",
        "DEVELOPMENT_TEAM": SettingValue(stringLiteral: developmentTeam),
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
        .external(name: "Sparkle"),
        .external(name: "YYJSON"),
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
        .external(name: "YYJSON"),
      ],
      settings: .settings(base: [
        "PRODUCT_NAME": "tatami",
        // Embed an Info.plist section in the CLI binary so it can report its
        // version at runtime from the same `appVersion` source as the app —
        // no hardcoded string to drift (see TatamiCLI `--version`).
        "GENERATE_INFOPLIST_FILE": "YES",
        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
        "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
        "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: buildNumber),
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
