# Geraldine from the terminal

Geraldine is a menu-bar app, so most of its work happens in windows and panels.
This document inventories every surface, records which ones the `geraldine`
command can drive, and defines the command, JSON, security, and performance
contracts.

## Surface inventory

Every user-facing capability is classified as one of:

- **A — first-class CLI surface.** The command is part of the supported
  terminal contract. It reads or changes the same live state as the UI and
  persists through the same preferences.
- **B — read-only CLI surface.** The scan or listing is available, but actions
  that delete, move, uninstall, or otherwise mutate user files stay in the UI.
- **C — GUI-only.** Deliberately not exposed to the CLI. The reason is listed
  next to the surface.

| Surface | Where it lives | Class | CLI / reason |
| --- | --- | --- | --- |
| App presence, build, socket health | App lifecycle | A | `status`, `doctor` |
| Keep Awake on / off / toggle | Keep Awake page, menu bar, `geraldine:` URLs | A | `awake on`, `awake off`, `awake toggle` |
| Keep Awake duration | Keep Awake honeycomb, Settings | A | `awake on --for 90m`, `awake on --indefinitely`, `settings set keepAwake.defaultDuration` |
| Keep Awake policies | Settings | A | `settings set keepAwake.allowDisplaySleep`, `.deactivateOnBattery`, `.pauseWhenScreenLocked` |
| Stay Active (idle simulation) | Keep Awake page | A | `stay-active on`, `stay-active off`, `stay-active delay <minutes>` |
| Stay Active delay | Keep Awake page | A | `stay-active delay 1|2|5`, `settings set keepAwake.idleActivityDelayMinutes` |
| CPU, memory, disk, network, battery, thermal, GPU readings | Dashboard, Activity, menu bar, popover | A | `stats cpu|memory|storage|network|battery|thermal|gpu|all` |
| Live history charts | Dashboard, Activity, popover | B | `stats <metric> --json` returns the current reading and recent history for read-only charting |
| Top processes | Activity | A | `processes --top N --sort cpu|memory` |
| Coding usage accounts and windows | Coding Usage, popover tiles | A | `usage`, `usage --refresh` |
| Connected devices | Dashboard, popover | A | `devices` |
| Device eject | Dashboard | C | Removing a mounted volume is destructive and belongs to a visible confirmation flow |
| Permission status | Permissions page, Settings | A | `permissions` |
| Permission prompts / deep links | Permissions page | C | Prompting is a user action with system dialogs; CLI only reports readiness |
| App shape (Dock / menu bar / both) | Settings | A | `settings set appShape menuBarOnly` |
| Network rate unit | Dashboard, network widget | A | `settings set networkRateUnit bitsPerSecond` |
| Launch at login | Settings | A | `settings get launchAtLogin`, `settings set launchAtLogin true` |
| Menu-bar metric | Widget layout | A | `settings set menuBar.metric cpu`, `widgets show cpu`, `widgets move cpu --front` |
| Widget layout (order, visibility, size) | Popover, Edit Widgets | A | `widgets list|show|hide|size|move|reset` |
| Calendar and world-clock settings | Calendar page | A | `settings list`, `settings set calendar.*`; world clocks accept JSON |
| Power Tools preferences | Power Tools page, Settings | A | `settings list`, `settings set powerTools.*` |
| Power Tools actions (empty Trash, sleep displays, eject, window actions) | Power Tools page and system event taps | C | They mutate other apps or destructive system state and need Accessibility; preferences remain controllable |
| Dock window previews | Power Tools | C | Visual-only; previews need Screen Recording and are never written to disk |
| Cleanup scan | Cleanup page | B | `cleanup scan` |
| Cleanup delete / move to Trash | Cleanup page | C | Destructive; requires per-item selection and confirmation |
| Large & old files scan | Large Files page | B | `large-files scan [--path] [--min-size]` |
| Large file cleanup | Large Files page | C | Destructive |
| Storage measurement | Storage page | B | `storage scan` |
| Smart Care health scan | Smart Care page | B | `smart-care scan` |
| Smart Care queued actions | Smart Care page | C | Runs cleanup, maintenance, or updater actions |
| Privacy scan | Privacy page | B | `privacy scan` |
| Browser cookie / history deletion | Privacy page | C | Destructive and sensitive |
| Uninstaller app list | Uninstaller page | B | `uninstaller list` |
| Uninstall app and leftovers | Uninstaller page | C | Destructive |
| Login items list | Login Items page | B | `login-items list` |
| Enable / disable / remove login items | Login Items page | C | Mutates launchd state; requires per-item confirmation |
| Maintenance tasks | Maintenance page | C | Needs administrator privileges and can flush DNS, rebuild indexes, and run periodic scripts |
| Free RAM | Free RAM page | C | Runs `purge`, which needs administrator privileges |
| Updater | Updater page | C | Runs Homebrew upgrades and changes installed apps |
| Network speed test | Network panel | C | Performs an explicit network transfer; the CLI adds no network traffic of its own |
| Onboarding, notifications, design QA | App shell | C | Presentation-only |
| Module navigation | Sidebar, Command Search | A | `open <page>` |
| `geraldine:` URL commands | URL handler | A (compatibility) | Existing `activate`, `deactivate`, and `toggle` URLs keep working; the CLI uses the control socket instead |

## Design rules

- **One state owner.** Commands run inside the app and change the existing
  controllers on the main actor, so `didSet` hooks, window updates, and menu-bar
  refreshes behave exactly as they do after a click.
- **Live and persistent.** Every settings change applies immediately and writes
  the same `UserDefaults` key the UI uses. No restart is required.
- **No polling.** The control server waits on a Unix-domain socket with a
  dispatch read source. It adds no timer, animation, or idle CPU work.
- **No network.** The control channel is a local Unix socket. Geraldine does not
  open a TCP port, does not phone home, and does not send usage anywhere.
- **No screen content.** Commands and responses contain settings, counters,
  process names, and file paths the user asked for. Nothing captures or logs
  screen pixels.
- **No secrets.** The control socket holds no credentials and does not read the
  Keychain.

## Command reference

```text
geraldine status [--json]
geraldine awake on [--for 90m | --indefinitely] [--json]
geraldine awake off [--json]
geraldine awake toggle [--json]
geraldine stay-active on|off [--json]
geraldine stay-active delay <minutes> [--json]
geraldine settings list [--json]
geraldine settings get <key> [--json]
geraldine settings set <key> <value> [--json]
geraldine widgets list [--json]
geraldine widgets show <id> [--json]
geraldine widgets hide <id> [--json]
geraldine widgets size <id> small|medium|large [--json]
geraldine widgets move <id> [--front | --before <id>] [--json]
geraldine widgets reset [--json]
geraldine stats [cpu|memory|gpu|network|battery|thermal|storage|all] [--watch] [--json]
geraldine processes [--top N] [--sort cpu|memory] [--json]
geraldine usage [--refresh] [--json]
geraldine devices [--json]
geraldine permissions [--json]
geraldine open [page] [--json]
geraldine doctor [--json]
geraldine cleanup scan [--json]
geraldine large-files scan [--path DIR] [--min-size MB] [--json]
geraldine storage scan [--json]
geraldine smart-care scan [--json]
geraldine privacy scan [--json]
geraldine uninstaller list [--json]
geraldine login-items list [--json]
geraldine commands [--json]
geraldine install-cli [--dir DIR] [--json]
geraldine --help
geraldine <command> --help
geraldine --version
```

`status`, `awake`, `stay-active`, `settings set`, `widgets`, `stats`,
`processes`, `usage`, `devices`, `permissions`, `open`, `doctor`, and every
scan need the app. `settings list` and `settings get` also work while Geraldine
is closed by reading the app's preference domain directly.

### Examples

```bash
# Start Keep Awake for 90 minutes, then confirm the assertions.
geraldine awake on --for 90m
geraldine status

# Turn Stay Active off for a meeting.
geraldine stay-active off

# Read every setting, or just one.
geraldine settings list
geraldine settings get keepAwake.defaultDuration

# Change a setting live. The menu bar and Settings page update immediately.
geraldine settings set menuBar.metric cpu
geraldine settings set appShape menuBarOnly

# Machine-readable output for agents.
geraldine status --json
geraldine stats all --json
geraldine commands --json

# One-shot install of the helper into ~/.local/bin.
geraldine install-cli
```

## JSON contract

Every command supports `--json`. The CLI prints one JSON object:

```json
{
  "schemaVersion": 1,
  "protocolVersion": 1,
  "id": "6F2C2B1E-...",
  "command": "status",
  "ok": true,
  "text": ["Geraldine 0.1.0", "Keep Awake: On · 1h 29m Left"],
  "result": {},
  "warnings": [],
  "error": null
}
```

- `schemaVersion` is the stable output schema. It changes only for a breaking
  field change.
- `protocolVersion` is the socket protocol. A mismatch is reported as a failed
  command rather than being reinterpreted.
- `result` is command-specific. See the command sections below.
- `warnings` is always present as an array, including when empty.
- `error` is `{ "code", "message", "hint" }` when `ok` is false. Errors are
  written to stderr in human mode and are part of the same JSON envelope in
  JSON mode.
- `--watch` emits one JSON object per line (NDJSON) in JSON mode and a refreshed
  block in human mode unless stdout is not a TTY, in which case it behaves as a
  single sample so logs and agents do not hang.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Command failed inside the app |
| 2 | Usage error: unknown command, missing argument, invalid value |
| 3 | Geraldine is not running or its control channel is unavailable |
| 4 | A permission or system capability is missing |

`settings list` and `settings get` return 0 even when Geraldine is closed; the
text and result include `"appRunning": false` and virtual settings report
`null`.

## Security

- Socket path: `~/Library/Application Support/Geraldine/control.sock`.
- The containing directory is created with mode `0700`; the socket is `0600`.
- The server calls `getpeereid(2)` and rejects any connection whose effective
  UID differs from the app's UID.
- Requests and responses are newline-delimited JSON with a maximum line size.
- There is no TCP listener and no authentication token to leak.
- The socket is removed when Geraldine quits. A stale socket left by a crash is
  removed only after a probe connection fails.
- Settings changes go through a typed allowlist. Unknown keys and invalid
  values are rejected before any state changes.

## Performance notes

The CLI is a thin client: it starts, connects, sends one JSON line, prints the
response, and exits. `GeraldineControl` is Foundation-only, so the CLI does not
link SwiftUI, AppKit, or the app's feature graph. The target is under 50 ms for
`status --json` against a running app; the measured results are recorded below
once the implementation is built.
