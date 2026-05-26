import Foundation

/// How Tatami arranges the windows of a workspace when it activates.
///
/// - `floating`: Tatami does not move or resize windows. Behaves like
///   FlashSpace's stock workspace switching.
/// - `bsp`: Binary Space Partitioning — each new window splits the
///   largest leaf horizontally or vertically, producing a recursive
///   tile layout. This is the yabai-equivalent default.
/// - `stack`: All windows occupy the full display bounds, stacked
///   front-to-back; only the focused one is visible.
public enum TilingMode: String, Codable, Hashable, Sendable, CaseIterable {
  case floating
  case bsp
  case stack
}

extension TilingMode {
  public var displayName: String {
    switch self {
    case .floating: "Floating"
    case .bsp: "BSP (tiling)"
    case .stack: "Stack"
    }
  }

  public var symbolIconName: String {
    switch self {
    case .floating: "rectangle.3.group"
    case .bsp: "square.grid.2x2"
    case .stack: "square.stack"
    }
  }
}
