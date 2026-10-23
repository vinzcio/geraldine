# Geraldine development handoff

**Updated:** 2026-10-23

Geraldine is a local-only macOS utility. It has no account system, backend, or cross-device sync, and clipboard history must not be reintroduced. Preferences and app state remain on this Mac in `UserDefaults` and Application Support. Preserve unrelated user work and the existing opt-in Dock window-preview behavior.

## Terminal control surface

- `docs/agent-cli.md` is the contract: surface inventory, commands, result shapes, settings catalog, JSON envelope, security, and performance evidence.
- `GeraldineControl` is Foundation-only; `GeraldineCLI` is packaged as `Geraldine.app/Contents/Helpers/geraldine` and copied to `~/.local/bin` by `geraldine install-cli`.
- The app answers on `~/Library/Application Support/Geraldine/control.sock` (directory `0700`, socket `0600`, `getpeereid` UID check). `ControlHost.shared` starts it at the end of `applicationDidFinishLaunching` and stops it first in `applicationWillTerminate`. Keep it off the main thread's polling paths: the server waits on a dispatch read source.
- Commands must change live state through the existing controllers and persist through their normal `didSet` hooks. Do not write a preference behind a live object, and do not add a second state owner.
- Destructive actions (cleanup, uninstall, eject, launchd changes, maintenance, updater, Free RAM) stay GUI-only. Scans are read-only and cap their JSON item arrays.
- Keep the compatibility surface: the four `keepAwake.*` keys, the `geraldine:` URLs, the `Geraldine Keep Awake` assertion name, the main binary path, and the helper path.
- Performance invariants: status animation ≤30 fps with a guaranteed final frame, render-signature dedupe, shimmer cooldown, thermal at 0.2 Hz only while displayed, GPU only while displayed, no monitor timer while displays sleep. `MonitorDemandTests`, `StatusAnimationFramePolicyTests`, and `MenuBarStatusAnimationPolicyTests` guard these.
- Open proof work: no live after-change idle-CPU measurement exists because the installed app was not relaunched; re-measure only with an authorized relaunch. A packaging run plus an installed-path check is required to prove the helper's signature and location. The real-CLI latency test needs `GERALDINE_CLI_BINARY`.

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
