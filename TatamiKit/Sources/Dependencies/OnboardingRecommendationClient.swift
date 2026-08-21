// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Dependencies
import DependenciesMacros
import Foundation
import FoundationModels

// MARK: - OnboardingRecommendationAvailability

public enum OnboardingRecommendationAvailability: Equatable, Sendable {
  case available
  case unavailable(String)
}

// MARK: - OnboardingRecommendation

public struct OnboardingRecommendation: Equatable, Sendable {

  // MARK: Lifecycle

  public init(workspaces: [SuggestedWorkspace], assignments: [Assignment]) {
    self.workspaces = workspaces
    self.assignments = assignments
  }

  // MARK: Public

  public struct SuggestedWorkspace: Equatable, Sendable {
    public init(name: String, kind: WorkspaceKind) {
      self.name = name
      self.kind = kind
    }

    public var name: String
    public var kind: WorkspaceKind
  }

  public struct Assignment: Equatable, Sendable {
    public init(bundleIdentifier: String, workspaceName: String?) {
      self.bundleIdentifier = bundleIdentifier
      self.workspaceName = workspaceName
    }

    public var bundleIdentifier: String
    public var workspaceName: String?
  }

  public var workspaces: [SuggestedWorkspace]
  public var assignments: [Assignment]

}

// MARK: - OnboardingRecommendationContext

public struct OnboardingRecommendationContext: Equatable, Sendable {
  public init(
    role: String,
    recurringWork: String,
    contextStyle: OnboardingContextStyle,
    prefersScratchpads: Bool,
    displays: [OnboardingRecommendationDisplay],
  ) {
    self.role = role
    self.recurringWork = recurringWork
    self.contextStyle = contextStyle
    self.prefersScratchpads = prefersScratchpads
    self.displays = displays
  }

  public var role: String
  public var recurringWork: String
  public var contextStyle: OnboardingContextStyle
  public var prefersScratchpads: Bool
  public var displays: [OnboardingRecommendationDisplay]
}

// MARK: - OnboardingRecommendationDisplay

public struct OnboardingRecommendationDisplay: Equatable, Sendable {
  public init(
    name: String,
    usableWidth: Int?,
    usableHeight: Int?,
    isPrimary: Bool,
  ) {
    self.name = name
    self.usableWidth = usableWidth
    self.usableHeight = usableHeight
    self.isPrimary = isPrimary
  }

  public var name: String
  public var usableWidth: Int?
  public var usableHeight: Int?
  public var isPrimary: Bool
}

// MARK: - OnboardingRecommendationClient

@DependencyClient
struct OnboardingRecommendationClient: Sendable {
  var availability: @Sendable () -> OnboardingRecommendationAvailability = {
    .unavailable("Apple Intelligence is unavailable.")
  }

  var makeExternalPrompt: @Sendable (
    _ apps: [MacApp],
    _ context: OnboardingRecommendationContext,
  ) -> String = { _, _ in "" }

  var parseExternalResponse: @Sendable (
    _ response: String,
    _ apps: [MacApp],
  ) throws -> OnboardingRecommendation = { _, _ in
    throw OnboardingRecommendationError.invalidResponse
  }

  var recommend: @Sendable (
    _ apps: [MacApp],
    _ context: OnboardingRecommendationContext,
  ) async throws -> OnboardingRecommendation
}

// MARK: DependencyKey

extension OnboardingRecommendationClient: DependencyKey {
  static let liveValue = OnboardingRecommendationClient(
    availability: {
      guard #available(macOS 26.0, *) else {
        return .unavailable("Requires macOS 26 or later.")
      }
      switch SystemLanguageModel.default.availability {
      case .available:
        return .available
      case .unavailable(.deviceNotEligible):
        return .unavailable("This Mac does not support Apple Intelligence.")
      case .unavailable(.appleIntelligenceNotEnabled):
        return .unavailable("Turn on Apple Intelligence in System Settings.")
      case .unavailable(.modelNotReady):
        return .unavailable("The on-device model is still preparing.")
      @unknown default:
        return .unavailable("Apple Intelligence is unavailable right now.")
      }
    },
    makeExternalPrompt: { apps, context in
      externalRecommendationPrompt(apps: apps, context: context)
    },
    parseExternalResponse: { response, apps in
      guard let data = extractedJSONObject(from: response).data(using: .utf8) else {
        throw OnboardingRecommendationError.invalidResponse
      }
      let decoded = try JSONDecoder().decode(ExternalWorkspaceRecommendations.self, from: data)
      return try validatedRecommendation(
        decoded.workspaces.map {
          ProposedWorkspace(
            name: $0.name,
            isScratchpad: $0.kind == .scratchpad,
            bundleIdentifiers: $0.bundleIdentifiers,
          )
        },
        apps: apps,
      )
    },
    recommend: { apps, context in
      guard #available(macOS 26.0, *) else {
        throw OnboardingRecommendationError.unavailable
      }
      guard SystemLanguageModel.default.isAvailable else {
        throw OnboardingRecommendationError.unavailable
      }

      let session = LanguageModelSession(
        model: .default,
        instructions: recommendationInstructions,
      )
      let response = try await session.respond(
        to: recommendationRequest(appList: recommendationAppList(apps), context: context),
        generating: GeneratedWorkspaceRecommendations.self,
      )
      return try validatedRecommendation(
        response.content.workspaces.map {
          ProposedWorkspace(
            name: $0.name,
            isScratchpad: $0.isScratchpad,
            bundleIdentifiers: $0.bundleIdentifiers,
          )
        },
        apps: apps,
      )
    },
  )

  static let testValue = OnboardingRecommendationClient(
    availability: { .unavailable("Apple Intelligence is unavailable in tests.") },
    makeExternalPrompt: { _, _ in "" },
    parseExternalResponse: { _, _ in throw OnboardingRecommendationError.invalidResponse },
    recommend: { _, _ in throw OnboardingRecommendationError.unavailable },
  )
}

extension DependencyValues {
  var onboardingRecommendations: OnboardingRecommendationClient {
    get { self[OnboardingRecommendationClient.self] }
    set { self[OnboardingRecommendationClient.self] = newValue }
  }
}

// MARK: - Recommendation Contract

private let recommendationInstructions = """
  You organize macOS apps into a small set of durable task contexts.
  Infer workspace structure from the person's role and description of a typical week, then classify their apps.
  The person's wording is evidence, not a requested list of workspace names.
  Never copy each phrase into one workspace. Merge overlapping work, reframe it around stable app contexts, and omit activities that do not need a persistent app set.
  Add a role-typical context only when the supplied apps support it.
  Use only bundle identifiers supplied by the prompt.
  For each proposed normal workspace, include at most four companion app bundle identifiers that are strong, primary fits.
  Include clear dedicated matches: for example, a development IDE for development, a design editor for design, or a messaging client for communication.
  Omit every app that should remain unmanaged. Leaving many apps unmanaged is healthy, but do not return zero placements when clear dedicated matches exist.
  Never invent apps.
  A workspace represents an activity the person intentionally enters, not a generic app category.
  Group apps only when they should consistently arrive together for that activity.
  Infer each app's likely interaction shape from its name, bundle identifier, available system category, and the person's work: sustained canvas or quick glance, dense reading or compact control, foreground task or background utility, and whether it is useful beside another app.
  Treat the connected display count and usable logical dimensions as real composition constraints. Judge whether the proposed apps remain usable simultaneously instead of assuming every side tool fits beside the main work.
  A scratchpad is a single-tool side context, not a synonym for an app used briefly. Use one only when the tool remains genuinely useful in a temporary partial-screen composition on the supplied displays.
  On a constrained display, prefer a normal workspace or leave an app unmanaged when its useful content needs sustained width, height, reading, inspection, or interaction.
  Give every scratchpad exactly one strong app match; if no single app clearly fits, do not create that scratchpad.
  A workspace named for a specific app or tool family should contain only that app or close companions.
  Do not assign an app merely because it could theoretically help with an activity.
  If an app's interaction characteristics are ambiguous, be conservative and leave it unmanaged instead of inventing behavior.
  Terminals, file managers, system monitors, app stores, security tools, password managers, VPNs, media apps, and generic utilities stay unmanaged unless the person's recurring activities explicitly require that exact tool.
  A communication workspace may contain only apps primarily dedicated to messaging, meetings, or collaboration. Never use it as a catch-all.
  """

private func recommendationRequest(
  appList: String,
  context: OnboardingRecommendationContext,
) -> String {
  """
  Person's role or kind of work:
  \(context.role)

  Plain-language description of a typical week:
  \(context.recurringWork)

  Preferred context density: \(context.contextStyle.promptDescription)
  Open to one-app borrow-only scratchpads when ergonomically appropriate: \(context.prefersScratchpads ? "yes" : "no")

  Connected display environment (usable logical work area, excluding the menu bar and Dock):
  \(displayEnvironmentDescription(context.displays))

  Apps, formatted as bundle identifier | name | optional system category:
  \(appList)

  First infer which parts of this work genuinely need different app sets. Propose between two and six durable workspaces appropriate to this person; at least two must be normal workspaces so task switching remains useful. Do not mirror the wording above or create one workspace per phrase. Use scratchpads only for side tools that should stay out of normal cycling and remain usable in the available partial-screen space; scratchpad preference permits them but does not require one. Put exactly one exact bundle identifier in each scratchpad and zero to four in each normal workspace. Omitted apps remain unmanaged.
  """
}

private func externalRecommendationPrompt(
  apps: [MacApp],
  context: OnboardingRecommendationContext,
) -> String {
  """
    Help me configure Tatami, a macOS task-context manager.

    \(recommendationInstructions)

    \(recommendationRequest(appList: recommendationAppList(apps), context: context))

    Return only JSON matching this shape, with no Markdown or explanation:
    {
      "workspaces": [
        {
          "name": "concise activity-oriented name",
          "kind": "workspace or scratchpad",
          "bundleIdentifiers": ["exact.bundle.identifier"]
        }
      ]
    }
  """
}

private func recommendationAppList(_ apps: [MacApp]) -> String {
  apps.map { app in
    var fields = [app.bundleIdentifier, app.name]
    if let category = applicationCategory(for: app) {
      fields.append("system category: \(category)")
    }
    return fields.joined(separator: " | ")
  }
  .joined(separator: "\n")
}

private func applicationCategory(for app: MacApp) -> String? {
  guard
    let path = app.iconPath,
    let bundle = Bundle(path: path),
    let rawCategory = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
    !rawCategory.isEmpty
  else { return nil }
  return rawCategory.replacingOccurrences(of: "public.app-category.", with: "")
}

private func displayEnvironmentDescription(
  _ displays: [OnboardingRecommendationDisplay]
) -> String {
  guard !displays.isEmpty else {
    return "Display geometry unavailable. Avoid making assumptions about simultaneous window space."
  }
  let countDescription = displays.count == 1 ? "1 display" : "\(displays.count) displays"
  let details = displays.map { display in
    let role = display.isPrimary ? "primary" : "secondary"
    let size =
      if let width = display.usableWidth, let height = display.usableHeight {
        "usable work area \(width) × \(height) points"
      } else {
        "usable work area unavailable"
      }
    return "- \(display.name) | \(role) | \(size)"
  }
  .joined(separator: "\n")
  return "\(countDescription)\n\(details)"
}

private func extractedJSONObject(from response: String) -> String {
  guard
    let start = response.firstIndex(of: "{"),
    let end = response.lastIndex(of: "}"),
    start <= end
  else { return response }
  return String(response[start...end])
}

// MARK: - ProposedWorkspace

private struct ProposedWorkspace {
  var name: String
  var isScratchpad: Bool
  var bundleIdentifiers: [String]
}

private func validatedRecommendation(
  _ proposedWorkspaces: [ProposedWorkspace],
  apps: [MacApp],
) throws -> OnboardingRecommendation {
  guard (2...6).contains(proposedWorkspaces.count) else {
    throw OnboardingRecommendationError.invalidResponse
  }

  var seenWorkspaceNames = Set<String>()
  let suggestedWorkspaces = try proposedWorkspaces.map { workspace in
    let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = name.normalizedWorkspaceName
    guard
      !name.isEmpty,
      name.count <= 48,
      seenWorkspaceNames.insert(normalizedName).inserted
    else { throw OnboardingRecommendationError.invalidResponse }
    return OnboardingRecommendation.SuggestedWorkspace(
      name: name,
      kind: workspace.isScratchpad ? .scratchpad : .normal,
    )
  }
  guard suggestedWorkspaces.count(where: { $0.kind == .normal }) >= 2 else {
    throw OnboardingRecommendationError.invalidResponse
  }

  let validBundleIDs = Set(apps.map(\.bundleIdentifier))
  let eligibleBundleIDs = zip(proposedWorkspaces, suggestedWorkspaces).flatMap { proposed, suggested in
    Array(proposed.bundleIdentifiers.prefix(suggested.kind == .scratchpad ? 1 : 4))
  }
  let bundleIDOccurrences = eligibleBundleIDs
    .reduce(into: [String: Int]()) { counts, bundleID in
      counts[bundleID, default: 0] += 1
    }
  var seenBundleIDs = Set<String>()
  let assignments: [OnboardingRecommendation.Assignment] = zip(
    proposedWorkspaces,
    suggestedWorkspaces,
  ).flatMap { proposed, suggested -> [OnboardingRecommendation.Assignment] in
    let assignmentLimit = suggested.kind == .scratchpad ? 1 : 4
    return proposed.bundleIdentifiers.prefix(assignmentLimit).compactMap { bundleID
      -> OnboardingRecommendation.Assignment? in
      guard
        validBundleIDs.contains(bundleID),
        bundleIDOccurrences[bundleID] == 1,
        seenBundleIDs.insert(bundleID).inserted
      else { return nil }
      return OnboardingRecommendation.Assignment(
        bundleIdentifier: bundleID,
        workspaceName: suggested.name,
      )
    }
  }
  return OnboardingRecommendation(workspaces: suggestedWorkspaces, assignments: assignments)
}

// MARK: - ExternalWorkspaceRecommendations

private struct ExternalWorkspaceRecommendations: Decodable {
  var workspaces: [ExternalWorkspace]
}

// MARK: - ExternalWorkspace

private struct ExternalWorkspace: Decodable {
  enum Kind: String, Decodable {
    case workspace
    case scratchpad
  }

  var name: String
  var kind: Kind
  var bundleIdentifiers: [String]
}

// MARK: - GeneratedWorkspaceRecommendations

@available(macOS 26.0, *)
@Generable
private struct GeneratedWorkspaceRecommendations {
  @Guide(description: "Two to six role-appropriate workspaces")
  var workspaces: [GeneratedWorkspace]
}

// MARK: - GeneratedWorkspace

@available(macOS 26.0, *)
@Generable
private struct GeneratedWorkspace {
  @Guide(description: "A concise activity-oriented workspace name")
  var name: String

  @Guide(description: "True only for a brief borrow-only side context")
  var isScratchpad: Bool

  @Guide(description: "Exactly one bundle identifier for a scratchpad; zero to four for a normal workspace")
  var bundleIdentifiers: [String]
}

extension String {
  fileprivate var normalizedWorkspaceName: String {
    trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

// MARK: - OnboardingRecommendationError

private enum OnboardingRecommendationError: Error {
  case invalidResponse
  case unavailable
}
