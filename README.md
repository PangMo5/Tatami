# 🟫 Tatami

A macOS workspace manager with yabai-style window tiling.

**Status:** Early development, not yet usable.

Tatami is inspired by [FlashSpace] by Wojciech Kulik, and its window tiling by
[yabai]. It is released under GPL-3.0. See [NOTICE.md](NOTICE.md) for
attribution.

## Goals

- Fast virtual workspace switching (concept inspired by FlashSpace)
- yabai-style tiling integrated with the workspace model (the new thing)
- macOS 14+

## Tech stack

- **Tuist** — project generation
- **The Composable Architecture (TCA)** — app architecture
- **swift-sharing** — cross-feature state sharing
- **swift-toml** — config persistence (`~/.config/tatami/config.toml`)
- **KarrotCodableKit** — Codable ergonomics
- **SFSafeSymbols** — type-safe SF Symbol catalog
- **swiftformat** (Airbnb config) — formatting

## License

[GPL-3.0](LICENSE).

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
[yabai]: https://github.com/koekeishiya/yabai
