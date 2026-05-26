# 🟫 Tatami

A macOS workspace manager with yabai-style window tiling.

**Status:** Early development, not yet usable.

Tatami is inspired by and licensed compatibly with [FlashSpace] by Wojciech
Kulik. It is not a direct fork — it is a new project that reuses some logic from
FlashSpace under the same license. See [NOTICE.md](NOTICE.md) for attribution.

## Goals

- Fast virtual workspace switching (inherited concept from FlashSpace)
- yabai-style tiling integrated with workspace model (the new thing)
- macOS 14+

## Tech stack

- **Tuist** — project generation
- **The Composable Architecture (TCA)** — app architecture
- **swift-sharing** — cross-feature state sharing
- **sqlite-data** — config persistence (StructuredQueries)
- **KarrotCodableKit** — Codable ergonomics
- **swiftformat** (Airbnb config) — formatting

## License

[GPL-3.0](LICENSE), same as upstream FlashSpace.

[FlashSpace]: https://github.com/wojciech-kulik/FlashSpace
