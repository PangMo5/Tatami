<!-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

Write repository guidance, documentation, and commit subjects/bodies in English.

## Shared guidance and personal memory

- Keep conventions needed by all contributors in repository-owned guidance, not only in an agent's personal memory. Update the relevant guidance when a shared rule changes.
- Keep personal preferences and machine-specific details in private local memory, outside repository-wide instructions.
- Keep `AGENTS.md` concise, actionable, and durable. Exclude verbose explanations, task histories, and facts likely to become stale; put version-specific findings, measurements, and temporary status in issues or reports.

For user-facing copy, follow [docs/LOCALIZATION.md](docs/LOCALIZATION.md). Keep agent guidance in English; translate only explicitly listed user documentation.

## Performance and responsiveness

- Reserve the main thread for input, UI state, and AppKit presentation. Run potentially blocking AX/WindowServer IPC, file I/O, parsing, and image processing on appropriate workers.
- Do not assume `async` or `Task` moves work off-main. Check actual isolation, synchronous calls, and locks that the main thread may wait for.
- Preserve request ownership across suspension. Cancellation, app relaunches, window replacement, and workspace changes must prevent stale results from changing focus or presentation.
- Never hold a lock needed by UI readers across IPC or I/O. Preserve atomic persistence and concurrent-edit guarantees when changing execution boundaries.
- Share or coalesce repeated queries and keep input sequences deterministic. Give caches explicit invalidation rules; an unavailable result is not authoritative emptiness.
- Keep focus, clicks, and scrolling connected to the real window. Mirrors, animations, and loading states must not trap input or expose stale content. Hover reveals an always-on-top window; keyboard focus follows only when FFM permits it or the user clicks.
- Measure the reported interaction sequence. Separate input handling, external work, and final presentation; passing tests or CLI completion times do not establish perceived responsiveness.
- Prefer fixing ownership, state, redundant work, or execution boundaries over delays, debouncing, or throttling that worsen responsiveness. Coalesce redundant work without postponing immediate input feedback whenever possible.
- Use timing controls only when the interaction or external system requires them, with evidence for the chosen behavior and latency cost. Do not use arbitrary delays, retries, or silent fallbacks to hide a broken contract or bottleneck.
