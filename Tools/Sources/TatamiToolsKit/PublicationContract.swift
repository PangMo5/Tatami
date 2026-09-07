// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Required editorial fields are decoded before dynamic metadata is carried through.
/// This keeps a malformed inventory from becoming an apparently successful empty batch.
struct PublicationContract: Decodable {
  struct Asset: Decodable {
    enum Presentation: String, Decodable {
      case dual
      case dynamicDual = "dynamic-dual"
    }

    let scene: String
    let title: String
    let description: String
    let section: String
    let maxSeconds: Double
    let maxMB: Double
    let presentation: Presentation?
    let posterSeconds: Double?
    let posterCaptionIndex: Int?
  }

  let assets: [Asset]

  func validate() throws {
    try require(!assets.isEmpty, "Publication inventory is empty")
    try require(Set(assets.map(\.scene)).count == assets.count, "Duplicate publication scene")
    for asset in assets {
      try require(fullMatch("[A-Za-z0-9_-]+", asset.scene), "Invalid scene name: \(asset.scene)")
      try require(
        !asset.title.isEmpty && !asset.description.isEmpty && !asset.section.isEmpty,
        "Missing editorial copy: \(asset.scene)",
      )
      try require(asset.maxSeconds > 1 && asset.maxMB > 0, "Invalid editorial budget: \(asset.scene)")
    }
  }
}
