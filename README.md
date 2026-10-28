# Geraldine

Geraldine is a native macOS 14+ utility for understanding and caring for your Mac. It is local-only freeware: there are no accounts, analytics, cloud services, or cross-device sync. Preferences and other local state live in `UserDefaults` and Application Support on this Mac. Published builds update themselves from `geraldine.hemisthia.com`; see [Updates](#updates).

## What it includes

- Live CPU, GPU, memory, storage, network, battery, and thermal information
- Smart Care, storage scanning, cleanup, and uninstaller workflows
- Keep Awake sessions, Stay Active, and menu-bar widgets
- Remaining-usage tiles for Antigravity, Claude, Codex, Grok, and Cursor, including several Claude or Codex logins
- Calendar and world clocks
- Opt-in Dock window previews
- Power tools for Finder, Mission Control, and common Mac maintenance tasks

Operations that can remove files or change system state show their scope and require an explicit user action. Dock previews and coding-usage tiles are off until you turn them on.

## Exploring activity and coding usage

- Click a dashboard metric to open its detail page. CPU and memory open the corresponding Activity chart.
- Hover or drag an Activity chart to inspect the same timestamp across CPU, GPU, and memory. Arrow keys inspect a focused chart. Missing recording intervals show “No sample.”
- Search Activity by app, helper name, or PID, expand beyond the first eight groups, and open a group to inspect its sampled processes. App helpers are grouped by their containing app bundle; totals cover the existing top-process sample, not every running process.
- Coding Usage compares accounts and all returned allowance windows, with reset dates and last successful update times. A failed refresh keeps older values explicitly labeled. Showing usage retains the existing opt-in and menu-bar tile behavior.
- Press **⌘K**, or use Search in the sidebar, to find pages and actions. Type to filter, use arrow keys to select, Return to open, and Escape to close. Refresh Coding Usage only refreshes accounts already enabled.

`ActivityExplorationTests` covers grouping, searching, chart gaps, and command matching. Set `FEATURE_SURFACE_DIR` to an owned output directory to run `FeatureSurfaceTests`: native mouse and keyboard events go directly to test windows outside all displays, without focus or system input. It also renders synthetic usage states and process details for visual review. These checks do not verify the installed app.

## Build and test

Requires macOS 14 or newer and Xcode 15 or newer. Geraldine is a Swift Package whose one third-party dependency is [Sparkle](https://sparkle-project.org) 2.10.0, pinned exactly, for self-updates.

The main checkout is `skyward:/root/Coding Projects/Geraldine`; Fasaj's clone
is the secondary checkout at the same path for load-balanced work. The old
OneDrive folder is a pointer. Geraldine itself and its preferences remain on
the Mac mini.

The Mac mini is a test machine and keeps no repository copies. Both VPSes
reach it through `ssh mac-mini`. Run native builds and tests there from a
temporary copy of a committed revision, preserving the verifier's Git
provenance and pinned SDK requirements. After the run, delete that copy and
`build.sh`'s staging (`~/Library/Caches/GeraldineBuild/src` and `build`).
Over SSH the login keychain is locked, so Developer ID signing fails with
`errSecInternalComponent`; run `build.sh` as a one-shot launchd job in
`gui/$(id -u)` instead.

```bash
swift test                 # run the test suite
./build.sh release         # build a local .app bundle
./build.sh release install run
```

`build.sh` signs ad-hoc by default. To keep Full Disk Access and other privacy grants across rebuilds, sign with your own Developer ID: set `CODESIGN_ID` (and `NOTARY_PROFILE` for notarization) in the environment or in a git-ignored `build.local.sh` beside the script.

## Updates

Published releases check `https://geraldine.hemisthia.com/updates/appcast.xml` at launch, every hour, and on **Check for Updates** (Geraldine menu, ⌘K, or Settings ▸ Updates). Each feed and archive must carry a valid signature from Geraldine's own update key, and the new app must come from the same Developer ID team. By default an update downloads in the background and Geraldine restarts to install it only while its window and menu bar panel are closed; a running Keep Awake session, with Stay Active, continues after the restart with its original end time. Settings ▸ Updates can turn off automatic installs or checks.

`./build.sh` builds name no feed and never update themselves. `CFBundleVersion` is the commit count of `HEAD`; `VERSION` in `build.sh` is the marketing version. Releases are packaged with `scripts/release/package-update.sh` and published with `scripts/release/publish-update.sh`. [`docs/updates.md`](docs/updates.md) has the client contract, the release runbook, the key and host setup, and the isolated end-to-end update test.

## Terminal and agents

The built app ships a `geraldine` helper at `Contents/Helpers/geraldine`. Put it on `PATH` once:

```bash
/Applications/Geraldine.app/Contents/Helpers/geraldine install-cli
geraldine status
```

The installer creates a symlink to the bundled helper, so replacing the app at the same path keeps the CLI current. It preserves unrelated files and links.

It controls Keep Awake and Stay Active, reads settings and cached metrics, drives the read-only scans, and supports `--json` on every command for agents, including help and version. Bare `geraldine` means `status`; `stats --watch <seconds>` uses the caller's interval. Requests have no implicit deadline; use `--timeout <seconds>` when needed. Destructive actions stay in the UI. While Geraldine is closed, `settings list` and `settings get` still read saved preferences. An explicit socket override stays isolated from the installed app's launch, URL, and preferences fallbacks.

[`docs/agent-cli.md`](docs/agent-cli.md) documents the surface inventory, every command and result shape, the settings catalog, the JSON contract, exit codes, security, and the performance evidence.

## Privacy and permissions

Some features request macOS permissions only when needed, including Accessibility, Screen Recording, Location for the connected Wi-Fi name, and access to user-selected folders. A coding-usage tile runs that assistant's installed CLI with the sign-in already on this Mac, and the CLI asks its provider for remaining usage; Geraldine sends no usage requests of its own and never reads the Keychain. The update check is the only request Geraldine makes on its own: one GET of the signed feed, plus the archive when an update exists, with Sparkle's User-Agent and no system profile or identifiers.

## License

Geraldine is available under the [MIT License](LICENSE).

## Architecture

The app is a SwiftUI executable with feature surfaces under `Sources/Geraldine/Features`, AppKit integration for app and menu-bar behavior, and an `AppState` composition root that owns the monitoring and utility services. Shared visual behavior lives in the semantic `Theme`, `Components`, and `Motion` layers. The package also includes the small C `CThermal` target. `Package.swift` declares one third-party package, Sparkle 2.10.0 (pinned exactly), which `build.sh` embeds as `Contents/Frameworks/Sparkle.framework`; everything else links only Apple system frameworks.

## Coding usage

Usage tiles read remaining quota only through each assistant's official CLI,
using the sign-in that CLI or its app already keeps on this Mac. Geraldine
sends no usage requests itself, never accesses Keychain (no Security API or
command-line fallback, including supposedly silent reads), and never starts a
sign-in or OAuth flow. Settings uses **Show Usage / Hide Usage**. A missing
CLI, missing sign-in, or unrecognised output shows as unavailable, never as
zero quota or signed out. A failed check keeps the last successful values,
labeled with the error and the time they were read, until each window resets.

| Provider | Source |
| --- | --- |
| Claude | `claude --print /usage --output-format json --no-session-persistence`; the `.claude.json` usage cache is used only when that command just refreshed it |
| Codex | `codex app-server --stdio`: `account/rateLimits/read` for quota, `account/read` for the email |
| Grok | `grok agent --no-leader stdio`: ACP `initialize`, then the `x.ai/billing` extension the TUI `/usage` screen uses |
| Cursor | The `cursor-agent --disable-auto-update` TUI `/usage` pager, handed the Cursor app's existing session token |
| Antigravity | `agy --print /usage --output-format json`, stopped after 150 seconds; a bucket agy marks `disabled` (a 5-hour limit while its group's weekly limit is spent) gets no row |

Checks leave nothing behind: no saved Claude transcripts, no Grok session (the
agent starts no MCP servers or session hooks and exits when its stdin closes),
and no half-finished Cursor self-update. The Cursor TUI runs in Geraldine's own
empty folder, `~/Library/Application Support/Geraldine/Usage Workspace`, so its
`--trust` and any MCP decision apply there, never to the home folder. An MCP
approval screen is only ever answered "Continue without approval". The TUI gets
its own session with the PTY as its controlling terminal, so it exits if
Geraldine quits mid-check.

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

The canonical source gate runs on the Mac mini. It stages only `Package.swift`,
`Sources`, and `Tests` outside the checkout, runs the full suite, and performs
a separate clean release compilation:

```bash
./verify.sh --owner <thread/session-id> --minimum-free-kib <explicitly-approved-positive-value>
```

The minimum-free-space value is operator-owned and mandatory; Geraldine supplies no default. For a focused test, use an owned scratch path outside the checkout with the same pinned toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test \
  --scratch-path <owned-scratch-path> \
  --filter <test-name>
```

`build.sh` is packaging-oriented; it is not the source verifier.

Run `python3 -B Tests/PackagingTests/test_dock_presentation.py` to verify the bundle starts as an agent before applying the saved Dock mode. This guards menu-bar-only launch and reopen behavior at the packaging boundary.

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
