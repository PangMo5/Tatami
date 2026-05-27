# 🟫 Tatami

A macOS workspace manager with yabai-style window tiling.

**Status:** In active development.

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
- **KeyboardShortcuts** — global hotkey recording
- **SFSafeSymbols** — type-safe SF Symbol catalog
- **Sparkle** — app updates
- **swiftformat** — formatting

## License

[GPL-3.0](LICENSE).

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
[yabai]: https://github.com/koekeishiya/yabai
