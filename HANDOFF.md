# Geraldine development handoff

**Updated:** 2026-08-31

Geraldine is a local-only macOS utility. It has no account system, backend, or cross-device sync, and clipboard history must not be reintroduced. Preferences and app state remain on this Mac in `UserDefaults` and Application Support. Preserve unrelated user work and the existing opt-in Dock window-preview behavior.

## Current state

The selected implementation and decision-spike queue has no open item; [`plans/README.md`](plans/README.md) is the authoritative status and dependency record. The source-only completion gate is documented in [`README.md`](README.md).

Packaged-bundle, installed-path, and live interaction/performance/accessibility proof remain unverified by this source pass. Each requires separate authorization and must be reported independently rather than inferred from source tests or compilation.

## Architecture and product boundaries

- `Package.swift` defines a native SwiftUI executable plus the C `CThermal` target and no third-party package graph.
- `AppState` composes feature services; AppKit owns app, menu-bar, Finder, Dock, and other system integration seams.
- Extend the established semantic `Theme`, `Components`, and `Motion` layers, plus `GeraldineMark` and `EyeView`, instead of creating parallel styling primitives.
- Do not pursue a generic system-monitor or AI-dashboard redesign before Geraldine has a personal identity brief.
- Keep the manual status-item architecture unless a fresh installed reproduction and explicit authorization justify reconsidering it.

The historical Keep Awake visual record and its evidence limitations are in [`design-qa.md`](design-qa.md).
