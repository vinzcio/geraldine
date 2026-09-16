# Geraldine

Geraldine is native macOS 14+ local-only freeware for Mac care and small system utilities. It has no accounts, backend, or cross-device sync. Clipboard history remains removed. Preferences and other local state live in `UserDefaults` and Application Support on this Mac.

## Architecture

The app is a SwiftUI executable with feature surfaces under `Sources/Geraldine/Features`, AppKit integration for app and menu-bar behavior, and an `AppState` composition root that owns the monitoring and utility services. Shared visual behavior lives in the semantic `Theme`, `Components`, and `Motion` layers. The package also includes the small C `CThermal` target. `Package.swift` declares no third-party packages and links only Apple system frameworks.

## AI usage credentials: no permission dialogs

AI usage discovery, connection, popover refresh, and background polling must never
access Keychain. `AIUsageCredentialStore` reads only existing credential files
and Cursor local database entries. Missing or rejected usage access is reported
as unavailable, never inferred to mean the user is signed out. There is no Security API or command-line Keychain fallback, including
supposedly silent reads. Query-level prompt suppression proved insufficient in
the installed app and was removed.

Preserve this invariant across new providers and rebuilds. Do not change Keychain
ACLs, request Always Allow, or copy credentials into new storage to work around
it. Claude reads the existing `~/.claude.json` usage snapshot first, without
accessing credentials or making a network request. The cached account must match
the signed-in account. Settings and the tile tooltip show its original update
time; refreshing Geraldine rereads the file, while Claude Code owns updating it.
If no snapshot or file credential is available, run `/usage` in Claude Code and
refresh Geraldine. Missing usage does not mean Claude is signed out.
Other providers whose credentials exist only in Keychain may be unavailable.
Regression tests use isolated synthetic credential files, including missing and
malformed data. Installed verification must also check startup and usage refresh;
a mocked query flag is not proof that dialogs are suppressed.

### Existing sessions for every coding assistant

Showing a usage tile immediately reads the existing source; there is no separate
Geraldine connection or login. Settings uses **Show Usage / Hide Usage**.
Missing data or a rejected usage request must not offer Sign In or initiate OAuth.
Keep the source distinctions explicit:

| Provider | Existing source |
| --- | --- |
| Claude | Account-matched Claude Code usage cache, then an existing file token |
| Codex | Existing Codex auth file used directly for the provider usage endpoint |
| Grok | Existing Grok auth file used directly for billing/usage |
| Cursor | Existing auth file or read-only Cursor database token used for usage |
| Antigravity | Running local language server quota first, then an existing file token |

Not every provider exposes a readable usage cache. Do not invent cached quota
from per-session token counts or copy secrets out of Keychain. If Antigravity is
not running and no file token is available, report unavailable and explain that
its app must be opened before retrying. Do not launch it automatically.

## Stay Active timing

Once the selected idle delay has elapsed, Stay Active posts a mouse nudge and a
paired Control-key press/release at a newly randomized interval of 2.0–2.4
seconds. Activity is counted as distinct one-second intervals containing a
successful pulse: the cadence targets 24–30 of 60 seconds (40–50%), with 0.1
seconds of allowance for timer lateness before reaching a 2.5-second gap. Events
within one nudge do not count as multiple active seconds. Pulses return the
pointer to its starting position. Keyboard pulses use only the Control modifier,
never arrow keys or text characters.

Real input restarts the idle delay. Turning the feature off, stopping/pausing
Keep Awake, or losing Accessibility access stops pulses. The 40–50% target applies
to uninterrupted pulsing minutes, excluding those states and time when macOS
suspends or stalls the process. This is Geraldine's event coverage definition,
not a guarantee about another app's activity score. Deterministic rolling-minute
tests and a 60-second real-run-loop test verify cadence with a synthetic event
sink, without sending test input into the user's apps.

## Source verification

The canonical source gate stages only `Package.swift`, `Sources`, and `Tests` outside OneDrive, runs the full suite, and performs a separate clean release compilation:

```bash
./verify.sh --owner <thread/session-id> --minimum-free-kib <explicitly-approved-positive-value>
```

The minimum-free-space value is operator-owned and mandatory; Geraldine supplies no default. For a focused test, use an owned scratch path outside OneDrive with the same pinned toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test \
  --scratch-path <owned-path-outside-OneDrive> \
  --filter <test-name>
```

`build.sh` is packaging-oriented; it is not the source verifier.

## Evidence ladder

These proof levels are separate and must not be substituted for one another:

1. **Source proof** — `verify.sh` binds exact staged inputs, runs tests, and compiles a clean release. It does not produce or prove an app bundle.
2. **Packaged-bundle proof** — an explicitly authorized packaging run proves the resulting bundle and signature. It does not prove what is installed.
3. **Installed-path proof** — an explicitly authorized installation check proves `/Applications` provenance and correspondence. It does not prove runtime behavior.
4. **Live proof** — explicitly authorized interaction, performance, and accessibility checks prove the running app's behavior. They are not implied by source, package, or install success.

## Project records

- [`HANDOFF.md`](HANDOFF.md) lists only current invariants and genuinely open proof work.
- [`design-qa.md`](design-qa.md) is a historical visual-QA record with explicit evidence limits.
- [`plans/README.md`](plans/README.md) is the authoritative implementation and decision-spike index.
