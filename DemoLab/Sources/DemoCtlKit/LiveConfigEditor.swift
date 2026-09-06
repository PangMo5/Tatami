// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
public enum LiveConfigEditor {
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
