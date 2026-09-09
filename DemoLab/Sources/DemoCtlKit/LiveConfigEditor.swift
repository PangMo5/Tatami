// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
public enum LiveConfigEditor {
  /// Prepare one existing assignment off camera without changing other scenes' seed.
  public static func updateAssignment(file: URL, bundleIdentifier: String, workspace: String, profile: String, autoOpen: Bool) throws {
    var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    var currentProfile: String?, currentWorkspace: String?
    var matches = [Range<Int>]()
    var index = 0
    while index < lines.count {
      let header = lines[index].trimmingCharacters(in: .whitespaces)
      guard header.hasPrefix("[") else { index += 1; continue }
      let start = index + 1
      index = start
      while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("[") { index += 1 }
      let body = try TomlLite.parse(lines[start..<index].joined(separator: "\n"))
      switch header {
      case "[[profiles]]": currentProfile = body["name"]?.stringValue; currentWorkspace = nil
      case "[[profiles.workspaces]]": currentWorkspace = body["name"]?.stringValue
      case "[[profiles.workspaces.apps]]":
        if currentProfile == profile && currentWorkspace == workspace && body["bundleIdentifier"]?.stringValue == bundleIdentifier {
          matches.append(start..<index)
        }
      default: break
      }
    }
    guard matches.count == 1, let range = matches.first else { throw DemoCtlError.usage("expected one assignment to prepare") }
    let body = lines[range].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("autoOpen =") }
    lines.replaceSubrange(range, with: body + ["autoOpen = \(autoOpen)"])
    let text = lines.joined(separator: "\n")
    let problems = ConfigValidator.problems(in: text)
    guard problems.isEmpty else { throw DemoCtlError.usage(problems.joined(separator: "; ")) }
    try Data(text.utf8).write(to: file, options: .atomic)
  }

  public static func update(file:URL,key:String,value:String) throws {
    let sections=["borrowDefaultEdge":"switching","borrowFraction":"switching","mouseFollowsFocus":"focus","focusFollowsMouse":"focus","gapInner":"layout","gapOuter":"layout"]
    guard let section=sections[key] else {throw DemoCtlError.usage("unsupported live setting: \(key)")}
    let valid:Bool
    switch key {
    case "borrowDefaultEdge":valid=["remove","\"top\"","\"bottom\"","\"left\"","\"right\""].contains(value)
    case "borrowFraction":valid=Double(value).map {(0.15...0.65).contains($0)} ?? false
    case "mouseFollowsFocus","focusFollowsMouse":valid=["true","false"].contains(value)
    default:valid=Int(value).map {(0...40).contains($0)} ?? false
    }
    guard valid else {throw DemoCtlError.usage("invalid value for \(key): \(value)")}
    var text=try String(contentsOf:file,encoding:.utf8)
    guard let header=text.range(of:"[settings.\(section)]") else {throw DemoCtlError.usage("missing settings.\(section)")}
    let tail=text[header.upperBound...]
    let end=tail.range(of:"\n[")?.lowerBound ?? text.endIndex
    let range=header.upperBound..<end
    var body=String(text[range])
    let regex=try NSRegularExpression(pattern:"(?m)^\\s*"+NSRegularExpression.escapedPattern(for:key)+"\\s*=.*$")
    let all=NSRange(body.startIndex...,in:body)
    body=regex.stringByReplacingMatches(in:body,range:all,withTemplate:"")
    if value != "remove" {body += "\n\(key) = \(value)\n"}
    text.replaceSubrange(range,with:body)
    _=try TomlLite.parse(text)
    try Data(text.utf8).write(to:file,options:.atomic)
  }
}
