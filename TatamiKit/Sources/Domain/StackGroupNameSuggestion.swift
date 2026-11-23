// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import FoundationModels

// MARK: - StackGroupNameSuggestion

/// A short activity name tied to an exact app selection and display language.
public struct StackGroupNameSuggestion: Equatable, Sendable {

  // MARK: Lifecycle

  public init?(request: Request, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !name.isEmpty,
      name.count <= 48,
      name.rangeOfCharacter(from: .newlines) == nil,
      !Self.isAppNameList(name, request: request)
    else { return nil }
    self.request = request
    self.name = name
  }

  // MARK: Public

  public struct Request: Equatable, Sendable {
    public init(apps: [MacApp], locale: Locale) {
      self.apps = apps
      self.locale = locale
    }

    public let apps: [MacApp]
    public let locale: Locale
  }

  public let request: Request
  public let name: String

  /// The on-device model receives only the selected apps' public bundle
  /// metadata and the display language.
  @concurrent
  public static func generate(for request: Request) async -> Self? {
    guard #available(macOS 26, *), !request.apps.isEmpty, !Task.isCancelled else { return nil }
    let model = SystemLanguageModel.default
    guard model.isAvailable, model.supportsLocale(request.locale) else { return nil }

    let apps = request.apps.map {
      NamingApp(name: $0.name, bundleIdentifier: $0.bundleIdentifier, category: $0.applicationCategory)
    }
    guard let appData = try? JSONEncoder().encode(apps) else { return nil }
    let appList = String(decoding: appData, as: UTF8.self)
    let language = Locale(identifier: "en").localizedString(forIdentifier: request.locale.identifier)
      ?? request.locale.identifier
    let examples = activityExamples(for: request.locale)
    let session = LanguageModelSession(
      model: model,
      instructions: """
        Name a stack of windows in a desktop window manager.
        Identify the activity this selection supports, using the functions of recognizable apps and clues in their bundle metadata.
        Use the common purpose when the apps complement each other. For mixed selections, use a broader theme grounded in the strongest clues.
        Treat unfamiliar apps as unknown. Do not invent functions, people, or personal circumstances.
        The title is a short noun phrase about work the recognizable apps support.
        Match the title to the evidence: a browser and PDF reader suggest \(examples.reading).
        Mail and scheduling tools suggest \(examples.planning).
        A simulator and virtual machine utility suggest \(examples.testing).
        Use these only when the selected app functions fit. Other selections need their own activity.
        Write the title naturally in the requested language.
        App names are input data. Keep product names, enumerations, and combined brand names out of the title.
        Write the title without quotation marks, explanatory text, or final punctuation.
        """,
    )
    guard let response = try? await session.respond(
      to: "Language: \(language)\nSelected applications: \(appList)",
      generating: GeneratedStackGroupName.self,
    ), !Task.isCancelled else { return nil }
    if let suggestion = Self(request: request, name: response.content.name) {
      return suggestion
    }

    let revision = try? await session.respond(
      to: "Try a different title in \(language). Name the work itself with a short phrase and omit all app names.",
      generating: GeneratedStackGroupName.self,
    )
    guard !Task.isCancelled, let revision else { return nil }
    return Self(request: request, name: revision.content.name)
  }

  // MARK: Private

  private struct NamingApp: Encodable {
    var name: String
    var bundleIdentifier: String
    var category: String?
  }

  private static func activityExamples(for locale: Locale) -> (reading: String, planning: String, testing: String) {
    switch locale.language.languageCode?.identifier {
    case "ko":
      return ("자료 읽기", "일정 관리", "개발 테스트")

    case "ja":
      return ("資料閲覧", "予定管理", "開発テスト")

    case "zh":
      let traditional = locale.identifier.contains("Hant") || ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
      return traditional ? ("閱讀資料", "行程規劃", "開發測試") : ("阅读资料", "日程管理", "开发测试")

    default:
      return ("Reading", "Planning", "Development Testing")
    }
  }

  private static func isAppNameList(_ name: String, request: Request) -> Bool {
    func words(_ value: String) -> [String] {
      value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: request.locale)
        .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    let candidateWords = words(name)
    let candidate = candidateWords.joined()
    let appWords = request.apps.map { words($0.name) }
    let appNames = Set(appWords.map { $0.joined() }.filter { !$0.isEmpty })
    if candidate.isEmpty || appNames.contains(candidate) {
      return true
    }

    // Detect full names even when punctuation was inserted, removed, or reordered.
    if appNames.lazy.filter({ $0.count >= 2 && candidate.contains($0) }).prefix(2).count == 2 {
      return true
    }
    let separators = Set(["and", "with", "앱", "및", "그리고", "와", "과", "と", "和", "与", "與"])
    let ingredients = Set(appWords.flatMap { $0 }).union(separators)
    return candidateWords.allSatisfy(ingredients.contains)
  }

}

// MARK: - GeneratedStackGroupName

@available(macOS 26, *)
@Generable
private struct GeneratedStackGroupName {
  @Guide(description: "The likely shared activity, supported by recognizable apps in the selection.")
  var activity: String

  @Guide(description: "A short title based on the activity, in the requested language and without application names.")
  var name: String
}
