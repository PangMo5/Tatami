// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum DemoLocale: String, CaseIterable, Sendable, Codable {
  case en, ko, ja
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"

  public static var selected: Self {
    if let value = ProcessInfo.processInfo.environment["DEMOLAB_LOCALE"] {
      guard let locale = Self(rawValue: value) else { preconditionFailure("Unsupported demo locale: \(value)") }
      return locale
    }
    // Let Foundation negotiate regional and secondary language preferences
    // against the actual localizations present in the app bundle.
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    return Self(rawValue: language) ?? .en
  }

  public var workspaceTerm: String {
    switch self {
    case .en: "workspace"
    case .ko: "작업 공간"
    case .ja: "ワークスペース"
    case .simplifiedChinese: "工作区"
    case .traditionalChinese: "工作空間"
    }
  }
}

public enum DemoTheme {
  public static func name(_ value: String) -> LocalizedStringResource {
    switch value {
    case "cobalt": "Cobalt"
    case "sand": "Sand"
    case "forest": "Forest"
    default: preconditionFailure("Unknown demo theme: \(value)")
    }
  }
}

extension DemoLocale {
  /// The apps own their main-bundle catalog. The plain capture controller uses
  /// the same compiled catalog at an explicit path when it seeds fixture data.
  public func string(_ resource: LocalizedStringResource) -> String {
    var resource = resource
    resource.locale = Locale(identifier: rawValue)
    let base = ProcessInfo.processInfo.environment["DEMOLAB_LOCALIZATION_DIR"].map(URL.init(fileURLWithPath:))
      ?? Bundle.main.resourceURL!
    let directory = base.appendingPathComponent(rawValue + ".lproj")
    if FileManager.default.fileExists(atPath: directory.path) {
      guard let bundle = Bundle(url: directory) else { preconditionFailure("Invalid localization bundle") }
      return String(localized: resource.defaultValue, table: resource.table, bundle: bundle, locale: resource.locale)
    } else {
      precondition(self == .en, "Missing compiled demo localization: \(directory.path)")
    }
    return String(localized: resource)
  }
}
