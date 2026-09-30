# Geraldine

Geraldine is a native macOS 14+ utility for understanding and caring for your Mac. It is local-only freeware: there are no accounts, analytics, cloud services, or cross-device sync. Preferences and other local state live in `UserDefaults` and Application Support on this Mac.

## What it includes

- Live CPU, GPU, memory, storage, network, battery, and thermal information
- Smart Care, storage scanning, cleanup, and uninstaller workflows
- Keep Awake sessions, Stay Active, and menu-bar widgets
- Remaining-usage tiles for Antigravity, Claude, Codex, Grok, and Cursor, including several Claude or Codex logins
- Calendar and world clocks
- Opt-in Dock window previews
- Power tools for Finder, Mission Control, and common Mac maintenance tasks

Operations that can remove files or change system state show their scope and require an explicit user action. Dock previews and coding-usage tiles are off until you turn them on.

## Build and test

Requires macOS 14 or newer and Xcode 15 or newer. Geraldine is a Swift Package with no third-party dependencies.

```bash
swift test                 # run the test suite
./build.sh release         # build a local .app bundle
./build.sh release install run
```

`build.sh` signs ad-hoc by default. To keep Full Disk Access and other privacy grants across rebuilds, sign with your own Developer ID: set `CODESIGN_ID` (and `NOTARY_PROFILE` for notarization) in the environment or in a git-ignored `build.local.sh` beside the script.

## Privacy and permissions

Some features request macOS permissions only when needed, including Accessibility, Screen Recording, Location for the connected Wi-Fi name, and access to user-selected folders. A coding-usage tile runs that assistant's installed CLI with the sign-in already on this Mac, and the CLI asks its provider for remaining usage; Geraldine sends no usage requests of its own and never reads the Keychain.

## License

Geraldine is available under the [MIT License](LICENSE).

## Architecture

The app is a SwiftUI executable with feature surfaces under `Sources/Geraldine/Features`, AppKit integration for app and menu-bar behavior, and an `AppState` composition root that owns the monitoring and utility services. Shared visual behavior lives in the semantic `Theme`, `Components`, and `Motion` layers. The package also includes the small C `CThermal` target. `Package.swift` declares no third-party packages and links only Apple system frameworks.

## Coding usage

Usage tiles read remaining quota only through each assistant's official CLI,
using the sign-in that CLI or its app already keeps on this Mac. Geraldine
sends no usage requests itself, never accesses Keychain (no Security API or
command-line fallback, including supposedly silent reads), and never starts a
sign-in or OAuth flow. Settings uses **Show Usage / Hide Usage**. A missing
CLI, missing sign-in, or unrecognised output shows as unavailable, never as
zero quota or signed out.

| Provider | Source |
| --- | --- |
| Claude | `claude --print /usage --output-format json`; the `.claude.json` usage cache is used only when that command just refreshed it |
| Codex | `codex app-server --stdio`: `account/rateLimits/read` for quota, `account/read` for the email |
| Grok | The `grok` TUI `/usage` screen |
| Cursor | The `cursor-agent` TUI `/usage` pager, handed the Cursor app's existing session token |
| Antigravity | `agy --print /usage --output-format json` |

A second Claude or Codex login lives in a sibling folder, `~/.claude-<name>` or
`~/.codex-<name>`, and gets its own tile beside the default one. Its CLI runs
with `CLAUDE_CONFIG_DIR` or `CODEX_HOME` pointed at that folder; the default
login leaves both unset. Discovery lists folder names and reads Claude's
`.claude.json` profile only. A Codex sibling counts when its `auth.json`
exists; Geraldine never opens it. Menu-bar apps inherit a minimal PATH, so CLI
launches prepend the install directories Geraldine searches (`~/.local/bin`,
`~/.homebrew/bin`, `/opt/homebrew/bin`, `/usr/local/bin`).

Regression tests use isolated synthetic homes and fake CLIs, and assert that
no usage path opens an HTTP request.

### Time windows and account plans

Claude shows its five-hour allowance alongside weekly all-model and Fable
allowances when present. Codex Plus shows returned weekly/five-hour windows;
other Codex plans keep their pooled display. Read the current response's plan
and `windowDurationMins` on every refresh; never assume a primary window is
five hours or synthesize one from the plan name. A Pro account returns one
weekly window. Grok and Cursor's existing displays are unchanged.

The bounded [Claude Opus design](docs/product/claude-opus-quota-design.md) defines
the compact rows, full labels, reset tooltip, and original cache timestamp.
All supplied Claude windows must reach both the renderer and accessibility text;
do not truncate them to two rows.

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
