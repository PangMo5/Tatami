// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ArgumentParser
import Foundation

// MARK: - ToolCLI

public struct ToolCLI: AsyncParsableCommand {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public static let configuration = CommandConfiguration(
    commandName: "tatami-tools",
    abstract: "Build Tatami documentation, demos and recording environments.",
    subcommands: [
      BuildDocs.self,
      BuildSite.self,
      PreviewSite.self,
      LocalizeScenes.self,
      CompileLocalization.self,
      VideoTheme.self,
      Export.self,
      ComposeDisplays.self,
      ComposeHotplug.self,
      Capture.self,
      RecordLocales.self,
      SelectTakes.self,
      RenderSite.self,
      InstallAssets.self,
      MergeReviewBundle.self,
      BundleApps.self,
      BuildVirtualDisplay.self,
      DemoControl.self,
      FocusSession.self,
      SetSpacing.self,
      BuildOverview.self,
      VMBootstrap.self,
      VMSync.self,
      VMFetchRecordings.self,
      VMProvision.self,
      DesktopDefaults.self,
      VMImport.self,
      VMExport.self,
      VMSetup.self,
      JSONField.self,
      EmbedReleaseNotes.self,
      BuildToolNotices.self,
    ],
  )

}

// MARK: - WorkspaceOptions

struct WorkspaceOptions: ParsableArguments {
  @Option(help: "Tatami checkout; defaults to the enclosing checkout.")
  var root: String?

  var workspace: Workspace {
    get throws { try .discover(root) }
  }
}

// MARK: - Locale

enum Locale: String, CaseIterable, ExpressibleByArgument, Sendable {
  case en
  case ko
  case ja
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"
}

// MARK: - BuildDocs

struct BuildDocs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Generate all reviewed documentation translations.")

  @OptionGroup var common: WorkspaceOptions
  @Option(parsing: .upToNextOption)
  var documents = [String]()
  @Flag(help: "Verify generated files without writing.")
  var check = false

  mutating func run() throws {
    try DocumentBuilder(workspace: common.workspace).build(selected: documents, check: check)
  }
}

// MARK: - BuildSite

struct BuildSite: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Build validated localized pages and media into a directory.")

  @OptionGroup var common: WorkspaceOptions
  @Option var output: String
  @Option var version: String?
  @Option(parsing: .upToNextOption)
  var locales: [Locale] = Locale.allCases

  mutating func run() throws {
    try SiteBuilder(workspace: common.workspace).build(
      output: URL(fileURLWithPath: output),
      version: version,
      selectedLocales: locales.map(\.rawValue),
    )
  }
}

// MARK: - PreviewSite

struct PreviewSite: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Serve a site on loopback with native video streaming.")

  @OptionGroup var common: WorkspaceOptions
  @Option var directory: String?
  @Option var port: UInt16 = 8769
  @Flag var background = false
  @Flag(help: .hidden)
  var detached = false

  mutating func validate() throws {
    if port == 0 { throw ValidationError("Port must be 1...65535") }
  }

  mutating func run() async throws {
    let workspace = try common.workspace
    let directory = directory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ?? workspace.root.at("web")
    try await PreviewServer(directory: directory, workspace: workspace, port: port).start(
      background: background,
      detached: detached,
    )
  }
}

// MARK: - LocalizeScenes

struct LocalizeScenes: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Compile localized narration, input and AX assertions.")

  @OptionGroup var common: WorkspaceOptions
  @Flag var check = false

  mutating func run() throws {
    try SceneLocalizer(workspace: common.workspace).build(check: check)
  }
}

// MARK: - CompileLocalization

struct CompileLocalization: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Compile reviewed string units into .strings resources.")

  @OptionGroup var common: WorkspaceOptions
  @Option var output: String?

  mutating func run() throws {
    let workspace = try common.workspace
    try SceneLocalizer(workspace: workspace)
      .compileStrings(output: output.map { URL(fileURLWithPath: $0) } ?? workspace.lab.at(".build/DemoLab/Localization"))
  }
}

// MARK: - VideoTheme

struct VideoTheme: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Generate the recorder palette from website colors.")

  @OptionGroup var common: WorkspaceOptions

  mutating func run() throws {
    let workspace = try common.workspace
    let theme = try FilmPresentation(workspace: workspace)
    try theme.writeSwift(workspace: workspace)
    print(try theme.json.rendered())
  }
}

// MARK: - Export

struct Export: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Export accepted takes to a new local review bundle.")

  @OptionGroup var common: WorkspaceOptions
  @Option var takes: String
  @Option var output: String
  @Option var locale = Locale.en
  @Option(parsing: .upToNextOption)
  var scenes = [String]()

  mutating func run() async throws {
    try await VideoExporter(workspace: common.workspace).exportBatch(
      takes: URL(fileURLWithPath: takes),
      output: URL(fileURLWithPath: output),
      locale: locale.rawValue,
      scenes: scenes,
    )
  }
}

// MARK: - ComposeDisplays

struct ComposeDisplays: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Align two recordings by their capture clocks.")

  @OptionGroup var common: WorkspaceOptions
  @Argument var directory: String
  @Argument var scene: String

  mutating func run() async throws {
    try await VideoExporter(workspace: common.workspace).compose(
      directory: URL(fileURLWithPath: directory),
      scene: scene,
      hotplug: false,
    )
  }
}

// MARK: - ComposeHotplug

struct ComposeHotplug: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show the real secondary capture only while connected.")

  @OptionGroup var common: WorkspaceOptions
  @Argument var directory: String
  @Argument var scene: String

  mutating func run() async throws {
    try await VideoExporter(workspace: common.workspace).compose(
      directory: URL(fileURLWithPath: directory),
      scene: scene,
      hotplug: true,
    )
  }
}

// MARK: - Capture

struct Capture: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Capture independent publication scenes in the recording VM.")

  @OptionGroup var common: WorkspaceOptions
  @Option var output: String
  @Option(parsing: .upToNextOption)
  var scenes = [String]()
  @Option var fps = 30
  @Option var locale = Locale.en
  @Flag var continueOnError = false

  mutating func run() async throws {
    try await TakeLibrary(workspace: common.workspace).capture(
      output: URL(fileURLWithPath: output),
      scenes: scenes,
      fps: fps,
      locale: locale.rawValue,
      continueOnError: continueOnError,
    )
  }
}

// MARK: - RecordLocales

struct RecordLocales: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Record the missing current scenes in each locale.")

  @OptionGroup var common: WorkspaceOptions
  @Option var round = 1
  @Option(parsing: .upToNextOption)
  var locales: [Locale] = Locale.allCases

  mutating func run() async throws {
    try await TakeLibrary(workspace: common.workspace).recordMissing(
      round: round,
      selectedLocales: locales.map(\.rawValue),
    )
  }
}

// MARK: - SelectTakes

struct SelectTakes: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Select the lowest-loss accepted takes without changing originals.")

  @OptionGroup var common: WorkspaceOptions
  @Option var output: String
  @Option(parsing: .upToNextOption)
  var batches: [String]
  @Option(parsing: .upToNextOption)
  var locales: [Locale] = Locale.allCases

  mutating func run() throws {
    try TakeLibrary(workspace: common.workspace).select(
      output: URL(fileURLWithPath: output),
      batches: batches.map { URL(fileURLWithPath: $0) },
      selectedLocales: locales.map(\.rawValue),
    )
  }
}

// MARK: - RenderSite

struct RenderSite: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Refresh source-page video collections from the accepted manifest.")

  @OptionGroup var common: WorkspaceOptions

  mutating func run() throws {
    try Publication(workspace: common.workspace).renderSource()
  }
}

// MARK: - InstallAssets

struct InstallAssets: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Install reviewed bundles in this checkout; does not publish.")

  @OptionGroup var common: WorkspaceOptions
  @Argument var bundle: String
  @Flag var allLocales = false

  mutating func run() throws {
    try Publication(workspace: common.workspace).install(
      bundle: URL(fileURLWithPath: bundle),
      allLocales: allLocales,
    )
  }
}

// MARK: - MergeReviewBundle

struct MergeReviewBundle: AsyncParsableCommand {
  static let configuration =
    CommandConfiguration(abstract: "Replace reviewed films while archiving their prior media and evidence.")

  @OptionGroup var common: WorkspaceOptions
  @Argument var bundle: String
  @Argument var patch: String
  @Option var archive: String

  mutating func run() throws {
    try Publication(workspace: common.workspace).merge(
      bundle: URL(fileURLWithPath: bundle),
      patch: URL(fileURLWithPath: patch),
      archive: URL(fileURLWithPath: archive),
    )
  }
}

// MARK: - BundleApps

struct BundleApps: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Build, localize, sign and register the native Demo Lab bundles.")

  @OptionGroup var common: WorkspaceOptions
  @Option var output: String?

  mutating func run() async throws {
    try await BundleBuilder(workspace: common.workspace).build(output: output.map { URL(fileURLWithPath: $0) })
  }
}

// MARK: - BuildVirtualDisplay

struct BuildVirtualDisplay: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Compile the lab-only virtual display helper.")

  @OptionGroup var common: WorkspaceOptions

  mutating func run() async throws {
    try await BundleBuilder(workspace: common.workspace).buildVirtualDisplay()
  }
}

// MARK: - DemoControl

struct DemoControl: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "democtl",
    abstract: "Build if needed and invoke the native Demo Lab controller.",
  )

  @OptionGroup var common: WorkspaceOptions
  @Argument(parsing: .captureForPassthrough)
  var arguments = [String]()

  mutating func run() async throws {
    try await BundleBuilder(workspace: common.workspace).control(arguments)
  }
}

// MARK: - FocusSession

struct FocusSession: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Run the Terminal fixture's real workspace setup commands.")

  mutating func run() async throws {
    try await FixtureAutomation.focusSession()
  }
}

// MARK: - SetSpacing

struct SetSpacing: AsyncParsableCommand {
  static let configuration =
    CommandConfiguration(abstract: "Edit the fixture's live TOML spacing without changing other settings.")

  @Argument var gap: Int

  mutating func run() throws {
    try FixtureAutomation.setSpacing(gap)
  }
}

// MARK: - BuildOverview

struct BuildOverview: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Rebuild the marketing screenshot cascade with ImageMagick.")

  @OptionGroup var common: WorkspaceOptions

  mutating func run() async throws {
    try await MarketingBuilder(workspace: common.workspace).overview()
  }
}

// MARK: - VMBootstrap

struct VMBootstrap: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm-bootstrap",
    abstract: "Clone or start the dedicated Tart recording VM.",
  )

  @OptionGroup var common: WorkspaceOptions

  mutating func run() async throws {
    try await VMWorkflow(workspace: common.workspace).bootstrap()
  }
}

// MARK: - VMSync

struct VMSync: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm-sync",
    abstract: "Send a fresh source archive and native tools to the guest.",
  )

  @OptionGroup var common: WorkspaceOptions
  @Flag var noBuild = false

  mutating func run() async throws {
    try await VMWorkflow(workspace: common.workspace)
      .sync(build: !noBuild && ProcessInfo.processInfo.environment["BUILD"] != "0")
  }
}

// MARK: - VMFetchRecordings

struct VMFetchRecordings: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm-fetch-recordings",
    abstract: "Fetch a recording batch through a fresh, hash-verified archive.",
  )

  @OptionGroup var common: WorkspaceOptions
  @Argument var destination: String

  mutating func run() async throws {
    try await VMWorkflow(workspace: common.workspace).fetch(destination: URL(fileURLWithPath: destination))
  }
}

// MARK: - VMProvision

struct VMProvision: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm-provision",
    abstract: "Sync the guest, install a supplied Tatami build and configure its desktop.",
  )

  @OptionGroup var common: WorkspaceOptions

  mutating func run() async throws {
    try await VMWorkflow(workspace: common.workspace).provision()
  }
}

// MARK: - DesktopDefaults

struct DesktopDefaults: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Apply deterministic desktop settings inside a macOS VM.")

  mutating func run() async throws {
    try await VMGuest.desktopDefaults()
  }
}

// MARK: - VMImport

struct VMImport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "vm-import", shouldDisplay: false)

  @Option var archive: String
  @Option var destination: String
  @Option(name: .customLong("sha256"))
  var digest: String
  @Flag var build = false

  mutating func run() async throws {
    try await VMGuest.importArchive(
      archive: URL(fileURLWithPath: archive),
      destination: URL(fileURLWithPath: destination),
      digest: digest,
      build: build,
    )
  }
}

// MARK: - VMExport

struct VMExport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "vm-export", shouldDisplay: false)

  @Option var batch: String
  @Option var archive: String
  @Option var marker: String
  @Option var nonce: String

  mutating func run() async throws {
    try await VMGuest.exportArchive(
      batch: URL(fileURLWithPath: batch),
      archive: URL(fileURLWithPath: archive),
      marker: URL(fileURLWithPath: marker),
      nonce: nonce,
    )
  }
}

// MARK: - VMSetup

struct VMSetup: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "vm-setup", shouldDisplay: false)

  @OptionGroup var common: WorkspaceOptions

  mutating func run() async throws {
    try await VMGuest.setup(workspace: common.workspace)
  }
}

// MARK: - JSONField

struct JSONField: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "json-field",
    abstract: "Read one required string field from JSON on stdin.",
  )

  @Argument var field: String

  mutating func run() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let value = try JSON.parse(String(decoding: input, as: UTF8.self))
    guard let field = value[field].string else { throw ToolError("Missing string field: \(field)") }
    print(field)
  }
}

// MARK: - EmbedReleaseNotes

struct EmbedReleaseNotes: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Embed this minor series' changelog sections in a generated appcast.")

  @OptionGroup var common: WorkspaceOptions
  @Option var appcast: String
  @Option var version: String

  mutating func run() throws {
    try ReleaseMetadata(workspace: common.workspace).embedNotes(
      file: URL(fileURLWithPath: appcast),
      version: version,
    )
  }
}

// MARK: - BuildToolNotices

struct BuildToolNotices: AsyncParsableCommand {
  static let configuration =
    CommandConfiguration(abstract: "Generate notices from the pinned development-tool dependency revisions.")

  @OptionGroup var common: WorkspaceOptions
  @Flag var check = false

  mutating func run() async throws {
    try await DependencyNotices(workspace: common.workspace).build(check: check)
  }
}
