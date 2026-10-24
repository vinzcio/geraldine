# Geraldine development handoff

**Updated:** 2026-10-24

Geraldine is a local-only macOS utility. It has no account system, backend, or cross-device sync, and clipboard history must not be reintroduced. Preferences and app state remain on this Mac in `UserDefaults` and Application Support. Preserve unrelated user work and the existing opt-in Dock window-preview behavior.

## Terminal control surface

- `docs/agent-cli.md` is the contract: surface inventory, commands, result shapes, settings catalog, JSON envelope, security, and performance evidence.
- `GeraldineControl` is Foundation-only; `GeraldineCLI` is packaged as `Geraldine.app/Contents/Helpers/geraldine` and symlinked into `~/.local/bin` by `geraldine install-cli`. Regular files and unrelated links are preserved; app replacements at the same path keep the link current.
- The app answers on `~/Library/Application Support/Geraldine/control.sock` (directory `0700`, socket `0600`, `getpeereid` UID check). `ControlHost.shared` starts it at the end of `applicationDidFinishLaunching` and stops it first in `applicationWillTerminate`. Keep it off the main thread's polling paths: the server waits on a dispatch read source.
- Commands must change live state through the existing controllers and persist through their normal `didSet` hooks. Do not write a preference behind a live object, and do not add a second state owner.
- CLI/socket repair, 2026-10-23: strict argument validation and JSON help/version/errors; explicit endpoints disable installed-app fallbacks; failed or uncorrelated replies never trigger another transport; stale cleanup and stop preserve foreign/replaced paths. Socket permissions and options are checked without process-wide SIGPIPE changes. Focused regression fixtures inject launch/URL effects and use fake helper sources.
- CLI/socket review repair, 2026-10-23: bare invocation means status; current-user process lookup and Foundation JSON numeric types are corrected. Typed catalog arguments describe conditional offline reads and provider CLI effects. No added duration/process/frame ceilings or implicit socket deadlines remain; watch requires its interval and explicit launch retries without a fixed sleep. Connections own handler cancellation and descriptor close. Doctor uses caller PATH and containing-bundle metadata; unbundled identity stays unknown. `AgentControlRound2Tests` covers these boundaries.
- Approved startup permission repair, 2026-10-23: only Geraldine's owned default directory may tighten from `0755` to `0700`, with descriptor checks and permission read-back. Custom directories, symlink parents, foreign owners, and other non-private modes fail without repair. The Oct 23 source tests used disposable fixtures; live startup permissions were verified on Oct 24 (below).
- Destructive actions (cleanup, uninstall, eject, launchd changes, maintenance, updater, Free RAM) stay GUI-only. Scans are read-only and preserve all scanner-returned JSON items and diagnostics; pre-existing scanner limits remain.
- Keep the compatibility surface: the four `keepAwake.*` keys, the `geraldine:` URLs, the `Geraldine Keep Awake` assertion name, the main binary path, and the helper path.
- Performance invariants: original uncapped status animation and one-second visible thermal sampling, completed-image/signature dedupe, the existing shimmer policy, thermal/GPU only while displayed, no monitor timer while displays sleep. Source demand/render tests guard intended state decisions; Oct 24 live measurements exposed a startup sleep-state gap (below). Awake-screen CPU and visual parity remain unverified. Thermal caches successful metadata without a read-count TTL or guessed cache capacity.

### Historical verification — 2026-10-23

- CLI child proof, 2026-10-23: 64 focused tests and 35 isolated executable smokes passed on actual SDK 27.0; debug-helper start-to-exit over 50 isolated launches measured 6.75 ms median and 9.71 ms p95 against an isolated socket fixture.
- Parent SDK 27.0 proof, 2026-10-23: 93 combined focused tests passed with no failures or skips, including the actual CLI → isolated socket → production `ControlHost` → fake IOPM/isolated defaults workflow. The full suite reused that test binary with `--skip-build`: 516 XCTest cases (9 optional visual/UI skips, 0 failures) plus 8 Swift Testing passes, totaling 515 passes and 9 skips. The 60-second Stay Active timer check recorded successful fake pulses in 28 of 60 seconds; no real input or app entry point ran.
- Temporary release-package proof, 2026-10-23: the initial clean compile/package took 80.11 seconds. After the helper rpath correction, parent reassembly/resigning passed in 8.10 seconds using actual SDK 27.0 and unchanged default ad-hoc signing. Final metadata: `a086cb2f64c1-dirty`, `release`, built `2026-10-23T08:23:54Z`. Strict deep app and helper signatures passed; both binaries' rpaths are exactly `/usr/lib/swift` and `@loader_path`. `LSUIElement` is true; the helper links no AppKit/SwiftUI.
- Final packaged-helper proof: 7 isolated checks passed in 3.22 seconds, covering JSON version, the 22-command typed catalog, fixture install and idempotent reinstall via symlink, catalog via symlink, socket status, and doctor metadata/caller PATH. All 197 staged source/test/resource files plus `Package.swift` matched the working tree; runtime source/tests were unchanged since the passing full suite. Shell syntax and the existing Dock-presentation packaging check passed after the correction.
- Limits at that record: canonical `verify.sh` stopped before building because pinned SDK 26.5 was unavailable; SDK 27.0 results did not satisfy that gate. Installed-path correspondence, live CPU, and visual acceptance were unverified; the running installed revision was `993433a`. No production install, notarization, app entry-point execution, real input, or live preference/permission change occurred in that verification round.

### Shipping evidence — 2026-10-24

- [PR #31](https://github.com/vinzcio/geraldine/pull/31) merged as `a78fd0475de044c3b3b632006a7b1cf747b931ed`. The canonical `build.sh` release install used SDK 27.0 and the existing Developer ID certificate, Lloyd Vincent Luardo (team `4S9BMP9GU3`), from clean merged source; build time was `2026-10-24T13:18:09Z`. Strict deep app/helper signatures passed and built/installed CDHashes matched. PID `20389` was verified at `/Applications/Geraldine.app/Contents/MacOS/Geraldine`; background `open -g` left the foreground ASN unchanged.
- Live controls passed: Keep Awake ON indefinitely, Stay Active ON/pulsing with the preserved one-minute idle delay, and `allowDisplaySleep=false`. Independent `pmset` inspection confirmed both IOPM assertions; all 9 doctor checks passed. The owned default directory was `0700`, socket `0600`, UID `501`; `~/.local/bin/geraldine` resolved to the installed helper and worked.
- Actual installed `status` over 50 process launches measured 99.7905 ms median / 117.0821 ms p95. Profiling found 1,732 of 1,737 handler samples blocked in `SMAppService.status`. Fresh authoritative launch-at-login status is preserved; no latency code or freshness-policy change was made. The historical <50 ms fixture checks prove helper/transport performance only.
- Display-asleep CPU samples (15 × 2 seconds each) measured old `993433a` mean 0.8067% / median 0.6%, and `a78fd04` mean 1.0267% / median 0.9% of one core. The earlier old mean 9.7733% / median 10.5% lacked a recorded display state and is not a matched comparison. No CPU improvement is established. `a78fd04` launched while the display was already asleep but continued monitor/thermal sampling. At record time, the source follow-up reconciled initial/start sleep state and shared it with menu-bar rendering; final parent checks and installed follow-up verification were pending. See [`docs/agent-cli.md`](docs/agent-cli.md#app-idle-cpu).
- SDK 26.5 verification and full awake-screen CPU/visual parity remain unproved. Both old and new bundles assessed as `Unnotarized Developer ID`; no trust, quarantine, or signing-policy change was made. This records the PR #31 deployment, not final acceptance of the subsequent sleep-state repair.

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
