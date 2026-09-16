# Geraldine development handoff

**Updated:** 2026-09-15

Geraldine is a local-only macOS utility. It has no account system, backend, or cross-device sync, and clipboard history must not be reintroduced. Preferences and app state remain on this Mac in `UserDefaults` and Application Support. Preserve unrelated user work and the existing opt-in Dock window-preview behavior.

## Current state

The Plan 001–019 queue is closed; [`plans/README.md`](plans/README.md) remains the historical status record. The source-only completion gate is documented in [`README.md`](README.md).

**Active pickup:** remaining-usage tiles in the **menu-bar popover**. Showing a tile fetches usage. Claude Max draws Fable + all-models bars; Plus draws all-models only. Cursor draws Cursor models + other models. Codex and Grok stay one pooled bar. Grok uses the grok.com mark. Details: [`docs/product/coding-usage-handoff.md`](docs/product/coding-usage-handoff.md).

## Architecture and product boundaries

- After every authorized rebuild/reinstall on Vincent's Mac, turn on **Keep Awake** and **Stay Active** and verify both in the running installed app. Preserve the existing duration and activity-delay choices. This is a post-install workflow requirement, not a change to app launch defaults.
- Stay Active uses mouse nudges and paired Control-key pulses at randomized 2.0–2.4-second intervals after idle activation, targeting 24–30 distinct active seconds (40–50%) per uninterrupted minute. No arrow keys. Preserve the real-input, stop, pause, and permission handling; see the timing contract and tests in `README.md`.

- `Package.swift` defines a native SwiftUI executable plus the C `CThermal` target and no third-party package graph.
- `AppState` composes feature services; AppKit owns app, menu-bar, Finder, Dock, and other system integration seams.
- Extend the established semantic `Theme`, `Components`, and `Motion` layers, plus `GeraldineMark` and `EyeView`, instead of creating parallel styling primitives.
- Do not pursue a generic system-monitor or AI-dashboard redesign before Geraldine has a personal identity brief.
- Keep the manual status-item architecture unless a fresh installed reproduction and explicit authorization justify reconsidering it.

The historical Keep Awake visual record and its evidence limitations are in [`design-qa.md`](design-qa.md).
