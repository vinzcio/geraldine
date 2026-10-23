# Geraldine from the terminal

Geraldine is a menu-bar app, so most of its work happens in windows and panels.
The `geraldine` command exposes the parts that make sense without a pointer: it
reads live state, starts and stops Keep Awake, changes the same settings the UI
changes, and runs the read-only scans. It is designed for both people at a
prompt and agents that need a stable, documented surface.

This document is the contract:

- the surface inventory, classifying every capability as first-class CLI,
  read-only CLI, or GUI-only;
- installation and discovery;
- what happens while the app is running, starting, or closed;
- every command, its arguments, and its result shape;
- the settings catalog;
- the JSON envelope and exit codes;
- security, privacy, and the performance evidence.

The command is a thin client. All state changes happen inside the running app on
the main actor, through the same controllers the UI uses.

## Install

### From a built bundle

`build.sh` compiles both products and ships the CLI inside the app:

```text
/Applications/Geraldine.app/Contents/Helpers/geraldine
```

The helper is copied before the app is signed and is signed with the identifier
`com.vincent.geraldine.helper`, so the app's signature covers the finished
helper. `GERALDINE_BUILD_ROOT` changes where `build.sh` assembles the bundle; it
does not change the runtime paths.

### Put it on PATH

Copy the bundled helper into `~/.local/bin`:

```bash
/Applications/Geraldine.app/Contents/Helpers/geraldine install-cli
```

`install-cli` copies the executable that invoked it into `~/.local/bin/geraldine`
with mode `0755`. It works without the app running and prints whether the
destination is already on `PATH`. Use `--dir DIR` for another directory:

```bash
geraldine install-cli --dir /usr/local/bin
```

The copy is a snapshot. After replacing the app, run `install-cli` again so the
helper and the app speak the same protocol. The destination must be writable by
your user; `/usr/local/bin` usually needs an administrator. If `~/.local/bin` is
not on `PATH`, add it to the shell profile; the default macOS `PATH` does not
include it.

### One binary, two roles

The installed helper is the same executable whether it is launched from the
bundle or from `PATH`. It is Foundation-only and links no app frameworks, which
keeps start-up in the low single-digit milliseconds.

## Surface inventory

Every user-facing capability is classified as one of:

- **A — first-class CLI surface.** The command is part of the supported
  terminal contract. It reads or changes the same live state as the UI and
  persists through the same preferences.
- **B — read-only CLI surface.** The scan or listing is available, but actions
  that delete, move, uninstall, eject, or otherwise mutate user files stay in
  the UI.
- **C — GUI-only.** Deliberately not exposed to the CLI. The reason is listed
  next to the surface.

| Surface | Where it lives | Class | CLI / reason |
| --- | --- | --- | --- |
| App presence, build, socket health | App lifecycle | A | `status`, `doctor` |
| Keep Awake on / off / toggle | Keep Awake page, menu bar, `geraldine:` URLs | A | `awake on`, `awake off`, `awake toggle` |
| Keep Awake duration | Keep Awake honeycomb, Settings | A | `awake on --for 90m`, `awake on --indefinitely`, `settings set keepAwake.defaultDuration` |
| Keep Awake policies | Settings | A | `settings set keepAwake.allowDisplaySleep`, `.deactivateOnBattery`, `.pauseWhenScreenLocked` |
| Stay Active (idle simulation) | Keep Awake page | A | `stay-active on`, `stay-active off`, `stay-active delay <minutes>` |
| Stay Active delay | Keep Awake page | A | `stay-active delay 1\|2\|5`, `settings set keepAwake.idleActivityDelayMinutes` |
| CPU, memory, disk, network, battery, thermal, GPU readings | Dashboard, Activity, menu bar, popover | A | `stats cpu\|memory\|storage\|network\|battery\|thermal\|gpu\|all` |
| Live history charts | Dashboard, Activity, popover | C | Charts are drawn from the app's in-memory history. The CLI returns the current reading, not a time series. |
| Top processes | Activity | A | `processes --top N --sort cpu\|memory` |
| Coding usage accounts and windows | Coding Usage, popover tiles | A | `usage`, `usage --refresh` |
| Connected devices | Dashboard, popover | A | `devices` |
| Device eject | Dashboard | C | Removing a mounted volume is destructive and belongs to a visible confirmation flow |
| Permission status | Permissions page, Settings | A | `permissions` |
| Permission prompts / deep links | Permissions page | C | Prompting is a user action with system dialogs; CLI only reports readiness |
| App shape (Dock / menu bar / both) | Settings | A | `settings set appShape menuBarOnly` |
| Network rate unit | Dashboard, network widget | A | `settings set networkRateUnit bitsPerSecond` |
| Launch at login | Settings | A | `settings get launchAtLogin`, `settings set launchAtLogin true` |
| Menu-bar metric | Widget layout | A | `settings set menuBar.metric cpu`, `widgets show cpu`, `widgets move cpu --front` |
| Widget layout (order, visibility, size) | Popover, Edit Widgets | A | `widgets list\|show\|hide\|size\|move\|reset` |
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

## Discovery for people and agents

```bash
geraldine --help                 # overview
geraldine awake --help           # one command: usage, args, side effects
geraldine help awake             # same
geraldine commands --json        # machine-readable catalog
geraldine --version
```

`commands --json` returns the catalog inside the standard envelope (shown abridged):

```json
{
  "schemaVersion": 1,
  "protocolVersion": 1,
  "command": "commands",
  "ok": true,
  "result": {
    "schemaVersion": 1,
    "protocolVersion": 1,
    "commands": [
      {
        "name": "awake",
        "summary": "Turn Keep Awake on, off, or toggle it.",
        "usage": "geraldine awake on [--for 90m | --indefinitely] | off | toggle [--json]",
        "subcommands": ["on", "off", "toggle"],
        "arguments": [],
        "needsRunningApp": true,
        "sideEffects": ["Creates or releases IOPM power assertions."]
      }
    ]
  },
  "warnings": []
}
```

Every entry declares `needsRunningApp` and `sideEffects`, so an agent can decide
whether a call requires the app and whether it changes state before invoking it.
`geraldine <command> --help` also prints the side effects and the argument
types, and names the subcommands.

Running `geraldine` with no command prints the same overview and exits `2`:
without a command, there is nothing to do. Explicit `--help` exits `0`.

## Running, closed, and degraded states

| Situation | Behaviour |
| --- | --- |
| App running, control socket ready | Every command works against live state. |
| App running, no control socket | Control commands exit `3` and say the app is running but the socket is unavailable. `awake on\|off\|toggle` falls back to the `geraldine:` URL handler and reports `result.method = "url"`; the result cannot be confirmed. `settings list\|get` read saved preferences with `appRunning: true`. `doctor` reports the socket failure. |
| App closed | `settings list\|get` read the `com.vincent.geraldine` preference domain with `appRunning: false`; the four virtual keys are omitted from `list` and report `null` from `get`. Every other command exits `3` with a hint to open the app or pass `--launch`. |
| App closed, `--launch` | The CLI opens the app once, waits two seconds, and retries the original request. It never launches the app implicitly. If the retry still fails, it exits `3`. |

Local commands never need the app: `commands`, `install-cli`, `help`,
`--version`, and read-only `settings`. `doctor` can run locally, but exits `3`
unless the app is running and the socket is ready, because its job is to prove
the control path.

While the app is starting, the socket may not exist yet. A command returns
`3` rather than waiting; retry with `--launch`, or poll `doctor`.

## Command reference

Global options, accepted before or after the command name:

| Option | Meaning |
| --- | --- |
| `--json` | Print one JSON envelope instead of human text. |
| `--socket PATH` | Use another Unix socket. Also `GERALDINE_CONTROL_SOCKET`. |
| `--timeout SECONDS` | Client connect and read deadline. Default `120`. |
| `--launch` | Open Geraldine if it is not running, then retry once. |
| `--no-color` | Accepted for compatibility; output is already plain text. |
| `--help`, `-h` | Overview, or help for the command that follows. |
| `--version`, `-v` | CLI, protocol, and schema versions. |

`GERALDINE_CONTROL_SOCKET` is the injectable path used by tests and wrappers. The
path must fit a Unix socket address (about 104 bytes on macOS).

### `status`

```text
geraldine status [--json]
```

The single call an agent should prefer. It returns the app identity, Keep Awake
and Stay Active state, the power assertions Geraldine actually holds, and every
vital.

```json
{
  "app": {
    "name": "Geraldine",
    "version": "0.1.0",
    "build": "0.1.0",
    "configuration": "debug",
    "pid": 51481,
    "appShape": "menuBarAndWindow",
    "launchAtLogin": true,
    "socket": "/Users/me/Library/Application Support/Geraldine/control.sock",
    "fullDiskAccess": true,
    "accessibility": true
  },
  "keepAwake": {
    "active": true,
    "paused": false,
    "statusLine": "On · 1h 29m Left",
    "endTimeLine": "Until 18:42",
    "defaultDuration": "oneHour",
    "allowDisplaySleep": false,
    "deactivateOnBattery": false,
    "pauseWhenScreenLocked": false,
    "idleActivityStatusLine": "On · waiting for 2m idle",
    "remainingSeconds": 5340.0,
    "activeUntil": "2026-10-23T10:42:00Z",
    "progressFraction": 0.86,
    "pauseReason": null,
    "lastError": null,
    "assertions": {
      "available": true,
      "systemSleepPrevented": true,
      "displaySleepPrevented": true,
      "assertionCount": 2
    }
  },
  "stayActive": {
    "enabled": true,
    "delayMinutes": 2,
    "phase": "waiting",
    "needsAccessibility": false,
    "statusLine": "On · waiting for 2m idle",
    "lastPulse": null,
    "lastUserInput": "2026-10-23T09:10:01Z",
    "error": null
  },
  "vitals": { }
}
```

`vitals` has the same shape as `stats all`. Dates are ISO 8601 strings with a
`Z` suffix. `remainingSeconds` and `activeUntil` are `null` for an indefinite
session. `pauseReason` is a human string when a policy paused the session.

### `awake`

```text
geraldine awake on [--for <duration> | --indefinitely] [--json]
geraldine awake off [--json]
geraldine awake toggle [--json]
```

- `awake on` uses `keepAwake.defaultDuration` unless a duration is given.
- `awake off` takes no duration and releases the assertions.
- `awake toggle` deactivates an active session, otherwise activates with the
  requested duration.
- If the app refuses to activate, the command returns `ok: false`, exit `1`,
  and the controller's error. The default failure path is macOS rejecting an
  assertion, not bad input.

Duration grammar: `90m`, `2h`, `1h30m`, `45s`, `1.5h`, `2 days`, bare minutes
(`90`), or `indefinitely` / `forever` / `infinite`. Fractions are allowed.
Durations must be at least one second and at most 30 days. `awake off --for 5m`
is a usage error.

Result:

```json
{
  "active": true,
  "paused": false,
  "statusLine": "On · 1h 30m Left",
  "endTimeLine": "Until 18:42",
  "remainingSeconds": 5400.0,
  "activeUntil": "2026-10-23T10:42:00Z",
  "defaultDuration": "oneHour",
  "assertions": {
    "available": true,
    "systemSleepPrevented": true,
    "displaySleepPrevented": true,
    "assertionCount": 2
  },
  "pauseReason": null,
  "lastError": null
}
```

### `stay-active`

```text
geraldine stay-active on|off [--json]
geraldine stay-active delay <1|2|5> [--json]
```

Stay Active pulses synthetic input only while Keep Awake is active, after the
selected idle delay. Enabling it without Accessibility access still persists the
setting, but the command returns `ok: false` with code `permission` and exit `4`,
and the text says it is enabled but blocked. That distinction matters: an agent
should report the permission problem, not assume the setting failed.

Result is the `stayActive` object shown under `status`.

### `settings`

```text
geraldine settings list [--json]
geraldine settings get <key> [--json]
geraldine settings set <key> <value> [--json]
```

Live behaviour:

- `list` returns every key in `settings` and the catalog in `definitions`, in
  catalog order. `appRunning` is `true`.
- `get` returns `key`, `value`, `kind`, `options`, `requiresRunningApp`, and
  `readOnly`.
- `set` validates the key and value in the CLI, sends the change to the app, and
  returns `key`, `previousValue`, `value`, and `changed`. The change is applied
  through the live controller and persisted through its normal `didSet` path.
  There is no restart and no parallel write behind the controller.

Offline behaviour:

- `list` returns `appRunning: false` and `settings` without the four keys that
  only exist while the app runs. The human lines say the app is not running.
- `get` returns `appRunning`, `key`, `value`, and `requiresRunningApp`. A key
  that needs the app returns `null` and `requiresRunningApp: true`.
- `set` exits `3` with the hint that changes need the app.

Value parsing:

- **bool** accepts `true`, `yes`, `on`, `1` and `false`, `no`, `off`, `0`.
- **int** must be an integer, and must be one of the listed options when the key
  has options.
- **enum** is case-insensitive and is stored canonically.
- **string** is taken as written after trimming outer whitespace.
- **json** must be valid JSON. `calendar.worldClocks.v1` and
  `geraldine.widgetLayout.v3` are additionally checked against their object
  shape before the app applies them.

### `widgets`

```text
geraldine widgets list [--json]
geraldine widgets show <id> [--json]
geraldine widgets hide <id> [--json]
geraldine widgets size <id> small|medium|large [--json]
geraldine widgets move <id> [--front | --before <id>] [--json]
geraldine widgets reset [--json]
```

Widget ids are the layout's kind ids, for example `cpu`, `memory`, `storage`,
`battery`, `network`, `temperature`, `gpu`, `calendar`, or `ai.claude`. `list`
marks the item currently driving the menu bar. `show` and `hide` change
visibility, `size` only works for resizable widgets, `move` reorders, and
`reset` restores Geraldine's defaults.

Result:

```json
{
  "items": [
    {
      "kind": "cpu",
      "title": "CPU",
      "size": "small",
      "isShown": true,
      "canResize": true
    }
  ],
  "menuBarMetric": "cpu"
}
```

`settings set menuBar.metric <metric>` shows that metric and moves it to the
front, exactly like choosing it in the UI; `widgets move` changes order without
changing visibility.

### `stats`

```text
geraldine stats [cpu|memory|gpu|network|battery|thermal|storage|all] [--watch] [--json]
```

Returns the current reading for one metric, or all of them. It does not return
history: charts are a GUI surface. `all` also includes `uptimeSeconds`.

`--watch` repeats the request every two seconds. With `--json` it emits one
envelope per line (NDJSON) and never stops on its own; stop it with Ctrl-C. In
human mode it reprints a block. When stdout is not a TTY, `--watch` in human
mode prints one sample and a warning instead of looping, so scripts and agents
do not hang by accident. JSON watch is explicit and always loops.

Metric shapes:

| Metric | Fields |
| --- | --- |
| `cpu` | `percent`, `loadAverage1m` |
| `memory` | `usedBytes`, `totalBytes`, `usedPercent` |
| `gpu` | `devices[]` with `id`, `name`, `state`, `activityPercent`; `available`; `selectedID` |
| `network` | `downBytesPerSecond`, `upBytesPerSecond`, `unit`, `down`, `up` |
| `battery` | `hasBattery`, `charging`, `onAC`, `draining`, `full`, `levelPercent`, `healthPercent`, `cycles`, `minutesToEmpty`, `minutesToFull` |
| `thermal` | `available`, `sensorCount`, `cpuCelsius`, `peakCelsius`, `cpuSource`, `batteryCelsius`, `storageCelsius` |
| `storage` | `totalBytes`, `usedBytes`, `freeBytes`, `usedPercent` |

Byte counts are integers. Percentages are `0...100` doubles. A reading that has
not arrived yet is `null`, never `NaN` or a fabricated zero.

### `processes`

```text
geraldine processes [--top N] [--sort cpu|memory] [--json]
```

`--top` is `1...200`, default `10`. Sorting is descending. Each row has `pid`,
`name`, `cpuPercent`, `memoryPercent`, and `path` (null when unavailable). The
sample is a point-in-time snapshot, not an average.

### `usage`

```text
geraldine usage [--refresh] [--json]
```

Returns every discovered coding-assistant identity with its status (`ready`,
`loading`, `needsSignIn`, `disconnected`, or `error`), plan, account email when
known, and all returned quota windows with `usedPercent`, `remainingPercent`,
`resetsAt`, and `durationSeconds`.

`--refresh` asks the existing `AIUsageMonitor` to refresh the accounts already
connected in the layout, then waits up to 25 seconds for that batch. It does not
start a second refresh, does not poll, and does not launch a provider CLI that
the UI would not launch. If the batch is still running, the response keeps the
last known values and adds a warning. Geraldine sends no usage HTTP requests of
its own; the providers' CLIs own that traffic.

Result:

```json
{
  "accounts": [
    {
      "id": "claude.default",
      "provider": "claude",
      "account": "default",
      "displayName": "Claude",
      "status": "ready",
      "plan": "Max",
      "windows": [
        {
          "id": "fiveHour",
          "title": "5-hour",
          "usedPercent": 42.0,
          "remainingPercent": 58.0,
          "resetsAt": "2026-10-23T12:00:00Z",
          "durationSeconds": 18000.0
        }
      ],
      "fetchedAt": "2026-10-23T09:15:00Z",
      "sourceLabel": null,
      "accountEmail": null,
      "error": null
    }
  ],
  "refreshed": false
}
```

### `devices`

```text
geraldine devices [--json]
```

Lists external drives, iOS devices, and Bluetooth peripherals. Each device has
`id`, `name`, `kind` (`drive`, `iosDevice`, `bluetooth`), `batteryPercent`,
`detail`, `ejectable`, and `path`. The top-level `scanning` flag says whether a
device scan is still running. Nothing is mounted or ejected.

### `permissions`

```text
geraldine permissions [--json]
```

Returns `fullDiskAccess`, `accessibility`, `screenRecording`, `location`
(`authorized`, `undetermined`, `denied`), and `requiredReady` (Full Disk Access
and Accessibility). It only reads status; it never opens a system prompt. Grant
access in System Settings, then rerun.

### `open`

```text
geraldine open [page] [--json]
```

Pages: `dashboard`, `smartCare`, `activity`, `codingUsage`, `storage`,
`battery`, `keepAwake`, `calendar`, `cleanup`, `largeFiles`, `uninstaller`,
`powerTools`, `privacy`, `loginItems`, `maintenance`, `updater`, `permissions`,
`settings`. Omitting the page opens the dashboard. The window is shown and
focused; the result names the page title.

### `doctor`

```text
geraldine doctor [--json]
```

Checks, in order: the app process, the control socket (type, owner, mode `0600`),
Full Disk Access, Accessibility, launch at login, the Keep Awake assertion
invariants, and whether the CLI is installed at `~/.local/bin/geraldine`.

- Missing permissions and a missing CLI install are `warn`, not failures.
- A mismatched or missing assertion while Keep Awake says it is active is a
  `fail`; so is an assertion held while Keep Awake is off or paused.
- With the app answering, any `fail` makes the command exit `1`.
- Run locally without a working socket, the command exits `3` and reports the
  socket as failed.

The result is `{ "checks": [{ "name", "status", "detail" }], "socket": "..." }`
with `status` in `ok`, `warn`, `fail`. The local fallback adds `appRunning` and
omits `socket` from the top level.

### Read-only scans

```text
geraldine cleanup scan [--json]
geraldine large-files scan [--path DIR] [--min-size MB] [--json]
geraldine storage scan [--json]
geraldine smart-care scan [--json]
geraldine privacy scan [--json]
geraldine uninstaller list [--json]
geraldine login-items list [--json]
```

None of these deletes, moves, uninstalls, ejects, or changes launchd state.
Human output shows a bounded preview; JSON carries the full, capped arrays.

`cleanup`, `large-files`, and `privacy` share this shape:

```json
{
  "groups": [
    {
      "title": "Caches",
      "itemCount": 312,
      "totalBytes": 123456789,
      "safeByDefault": true,
      "items": [
        { "name": "Example", "path": "/Users/me/Library/Caches/Example", "detail": "12 days old", "bytes": 4567890 }
      ]
    }
  ],
  "totals": { "bytes": 123456789, "items": 312 },
  "diagnostics": {
    "scannedItems": 5000,
    "skippedTotal": 2,
    "skipped": ["/Users/me/Library/...: Operation not permitted"],
    "failure": null,
    "cancelled": false,
    "finishedAt": "2026-10-23T09:20:00Z"
  }
}
```

Each group carries at most 50 items; `itemCount` and `totalBytes` still describe
the whole group. A skipped path is reported rather than silently dropped.
`large-files` adds `root` and `minSizeMB`; `--min-size` defaults to 100 MB and
`--path` defaults to the home folder.

`storage scan` returns `{ "capacity": { totalBytes, usedBytes, freeBytes,
usedPercent }, "categories": [{ label, detail, bytes, confidence }] }`.
`confidence` is `measured` or `estimated`.

`smart-care scan` returns `score` (`0...100`), `findings[]` (`title`, `detail`,
`scope`, `confidence`, `severity`, `actionable`, `module`, `actionTitle`), and
`vitals` (`diskFreeBytes`, `diskTotalBytes`, `diskUsedPercent`,
`memoryUsedPercent`, `reviewableJunkBytes`, `userLaunchAgents`). Findings that
would need an action are reported, never queued.

`uninstaller list` returns `apps[]` with `name`, `bundleID`, `version`, `bytes`,
`path`, `protected`, `protectedReason`, plus `count`, `totalBytes`,
`scannedItems`, and `diagnostics`. `login-items list` returns `items[]` with
`label`, `name`, `program`, `plistPath`, `scope`, `enabled`, `editable`, plus
`count` and `diagnostics`.

### `commands`, `install-cli`, `help`, `version`

```text
geraldine commands [--json]
geraldine install-cli [--dir DIR] [--json]
geraldine help [command]
geraldine --version
```

`commands` and `install-cli` are local and never contact the app. `install-cli`
returns `installed`, `path`, `source`, and `onPath`. `--version` prints
`geraldine 0.1.0 (protocol 1, schema 1)`.

## Settings catalog

Thirty-nine keys are exposed. Every key applies live and persists through the
same preference the UI uses. "App" means the key is only readable or writable
while Geraldine is running; the rest also read offline from
`UserDefaults(suiteName: "com.vincent.geraldine")`.

### Keep Awake

| Key | Kind | Values (default first where noted) |
| --- | --- | --- |
| `keepAwake.defaultDuration` | enum | `tenMinutes`, `thirtyMinutes`, `oneHour` (default), `twoHours`, `fourHours`, `eightHours`, `twelveHours`, `indefinitely` |
| `keepAwake.allowDisplaySleep` | bool | `false` (default) |
| `keepAwake.deactivateOnBattery` | bool | `false` (default) |
| `keepAwake.pauseWhenScreenLocked` | bool | `false` (default) |
| `keepAwake.simulateIdleActivity` | bool | `false` (default) |
| `keepAwake.idleActivityDelayMinutes` | int | `1`, `2` (default), `5` |

### App, menu bar, and layout

| Key | Kind | Values |
| --- | --- | --- |
| `appShape` | enum | `menuBarAndWindow` (default), `menuBarOnly`, `windowOnly` |
| `networkRateUnit` | enum | `bytesPerSecond` (default), `bitsPerSecond` |
| `launchAtLogin` | bool, app | `false` (default); registers with ServiceManagement |
| `menuBar.metric` | enum, app | `temperature` (default), `cpu`, `gpu`, `memory`, `storage`, `battery`, `network` |
| `geraldine.widgetLayout.v3` | json, app | non-empty array of `{kind, size, isShown}`; replaces the popover layout |
| `geraldine.aiUsage.connected` | json, app, read-only | sorted identities currently shown |

### Power Tools

| Key | Kind | Values |
| --- | --- | --- |
| `powerTools.dock.actionsEnabled` | bool | `false` |
| `powerTools.dock.windowPreviewsEnabled` | bool | `false` |
| `powerTools.dock.activeClickBehavior` | enum | `system` (default), `hideApp`, `minimizeWindows`, `cycleWindows` |
| `powerTools.dock.middleClickBehavior` | enum | `system` (default), `hideApp`, `minimizeWindows`, `newWindow`, `quitApp` |
| `powerTools.dock.shiftClickNewWindow` | bool | `false` |
| `powerTools.window.unminimizeOnActivation` | bool | `false` |
| `powerTools.window.greenButtonFillsWindow` | bool | `false` |
| `powerTools.window.yellowButtonHidesApp` | bool | `false` |
| `powerTools.window.missionControlTwoFingerClose` | bool | `true` |
| `powerTools.keyboard.commandQDoubleTap` | bool | `false` |
| `powerTools.keyboard.commandWDoubleTap` | bool | `false` |
| `powerTools.finder.returnOpens` | bool | `false` |
| `powerTools.finder.cutPaste` | bool | `false` |
| `powerTools.finder.optionNNewFile` | bool | `false` |
| `powerTools.finder.backspaceMovesToTrash` | bool | `false` |

Power Tools keys reload the active event hooks immediately. The hooks
themselves are GUI-only because they act on other apps.

### Calendar and world clocks

| Key | Kind | Values |
| --- | --- | --- |
| `calendar.showCalendar` | bool | `true` |
| `calendar.firstWeekday` | enum | `system` (default), `sunday`, `monday`, `saturday` |
| `calendar.showWeekNumbers` | bool | `false` |
| `calendar.highlightWeekends` | bool | `true` |
| `calendar.clockStyle` | enum | `system` (default), `twelveHour`, `twentyFourHour` |
| `calendar.showSeconds` | bool | `false` |
| `calendar.dateStyle` | enum | `full` (default), `long`, `medium`, `custom` |
| `calendar.customDateFormat` | string | `EEEE, MMM d` |
| `calendar.showWorldClocks` | bool | `true` |
| `calendar.showDayNightIcons` | bool | `true` |
| `calendar.showTimeTravel` | bool | `true` |
| `calendar.worldClocks.v1` | json | array of `{timeZoneID, label}` |

Calendar changes refresh the calendar and clocks immediately. World clocks
require a valid IANA `timeZoneID`; an unknown zone is rejected before any state
changes.

## JSON contract

`--json` prints exactly one object per response (or one per line with `--watch`)
on stdout, and nothing else. Failures print the same object on stderr, so a
successful pipeline can parse stdout without filtering errors. No ANSI escapes
are emitted in any mode; human output is plain text whether or not stdout is a
TTY.

```json
{
  "schemaVersion": 1,
  "protocolVersion": 1,
  "id": "6F2C2B1E-6B5A-4C0D-9E2F-2B7C1A4D8E90",
  "command": "status",
  "ok": true,
  "text": ["Geraldine 0.1.0 (running, pid 51481) — Menu bar and window", "Keep Awake: On · 1h 29m Left"],
  "result": {},
  "warnings": [],
  "error": null
}
```

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Stable output schema. Bumped only for a breaking field change. |
| `protocolVersion` | Socket protocol. A mismatch is rejected, never reinterpreted. |
| `id` | Request identifier, echoed by the app. Locally generated for local failures. |
| `command` | The command that produced the response. |
| `ok` | `false` for any failure, including usage errors. |
| `text` | Human lines. Absent when the command has nothing to say. |
| `result` | Command-specific object or array; `null` only when absent. |
| `warnings` | Always an array, including when empty. |
| `error` | `{ "code", "message", "hint" }` when `ok` is false. |

Error codes and exit status:

| Code | Exit | Meaning |
| --- | --- | --- |
| `usage` | 2 | Unknown command, missing argument, invalid value |
| `invalidValue` | 2 | A value was well-formed but not allowed |
| `failed` | 1 | The app accepted the request but the operation failed |
| `notRunning` | 3 | Geraldine is not running, or its control socket is unavailable |
| `unsupported` | 3 | Protocol version or build does not support the request |
| `permission` | 4 | A required macOS permission is missing |

`ok: true` always means exit `0`. A command can be `ok: true` with warnings; for
example, `usage --refresh` that times out keeps the previous values and adds a
warning.

The app enforces a 1 MiB maximum for one request or response line. The server
reads with a 15-second receive timeout and writes with a 120-second send
timeout; the client default is 120 seconds. `--timeout` lowers or raises the
client side. Oversized responses are rejected rather than buffered.

## Security and privacy

- Socket path:
  `~/Library/Application Support/Geraldine/control.sock`, overridable with
  `GERALDINE_CONTROL_SOCKET`.
- The containing directory is created with mode `0700` (and re-chmodded), the
  socket is `0600`.
- The server calls `getpeereid(2)` and closes any connection whose effective UID
  differs from the app's UID. There is no token to leak, and no TCP port.
- Requests and responses are newline-delimited JSON with a 1 MiB cap. A request
  must match the protocol version before it is dispatched.
- A stale socket left by a crash is removed only after a probe connection fails.
  A live one makes the new server back off instead of stealing the path.
- The socket is removed on quit. SIGPIPE is ignored and `SO_NOSIGPIPE` is set so
  a client that disconnects mid-request cannot kill the app.
- Settings go through a typed allowlist. Unknown keys, read-only keys, invalid
  values, and malformed JSON are rejected before any state changes.
- No Keychain access, no network listener, no usage HTTP requests from
  Geraldine, and no capture or logging of screen content. The command surface
  reads counters, settings, process names, and paths; it adds no new data
  collection.
- Read-only scans never delete, move, uninstall, eject, or change launchd state.
  Destructive actions remain in the UI behind their confirmations.

## Performance

### CLI latency

`GeraldineControl` is Foundation-only, so the CLI does not link SwiftUI, AppKit,
or the app's feature graph. A `status --json` run opens one Unix socket, writes
one line, reads one line, prints it, and exits.

Measured on this Mac against a local Unix-socket server, start-to-exit over
repeated real spawns:

| Metric | Result |
| --- | --- |
| Median | 5.65 ms |
| p95 | 6.79 ms |
| Minimum | 5.18 ms |
| Maximum | 12.54 ms |

The real-subprocess regression test uses `posix_spawn` + `waitpid` because
`Process.waitUntilExit` polls a run loop inside XCTest and adds about 60 ms,
which would hide the real cost. The in-process test asserts p95 under 50 ms; the
real-binary test asserts median under 50 ms and is skipped unless
`GERALDINE_CLI_BINARY` points at a built helper:

```bash
GERALDINE_CLI_BINARY=<build>/GeraldineCLI \
  swift test --scratch-path <owned-scratch-path> \
  --filter AgentControlTests
```

The server itself adds no idle work: it waits on a dispatch read source, not a
timer, and request handling runs off the accept path. The only cost while idle
is one open file descriptor.

### App idle CPU

The live installed build showed recurring bursts in the low-to-mid teens as a
percentage of one core while the menu-bar animation was running. Six
two-second samples of the installed app returned 0.0, 6.7, 13.8, 4.0, 11.7, and
6.4% of one core. The work was concentrated in the 144 Hz
`MenuBarController.stepStatusAnimation` path, which built and assigned a new
`NSImage` on every display-link vblank, plus per-second thermal and GPU sampling
even when nothing displayed those values.

The installed app could not be relaunched during this change (a paid shift
depends on its Keep Awake and Stay Active session), so no after idle-CPU
percentage is claimed here. The after evidence is component-level and
reproducible from source:

| Change | Before | After | Evidence |
| --- | --- | --- | --- |
| Status animation compositing | every display-link vblank, up to 144 fps | capped at 30 fps; the final frame always renders | `StatusAnimationFramePolicyTests` |
| Unchanged status redraws | one `NSImage` per monitor publish | skipped when the render signature is unchanged | `StatusRenderSignature` in `MenuBarController` |
| Shimmer | could fire on every unchanged sample | at most once per 10 s, and never while a real value change is animating | `MenuBarController` cooldown |
| Thermal cadence while visible | 1 Hz | 0.2 Hz (5 s) | `MonitorDemandTests`, `ThermalSamplePolicyTests` |
| Thermal cadence while hidden | 1 Hz | none | demand wiring from menu bar, popover, and window |
| GPU discovery while hidden | 1 Hz | none | demand wiring |
| Monitor wakeups while displays sleep | 1 Hz timer | timer stopped; one refresh on wake | `SystemMonitor` screen-sleep observers |
| Thermal resource setup | SMC key info and IOHID service list rebuilt per read | cached and reused | `CThermal.c` |

Component timings from the same machine, debug build:

- A post-change `Thermal.read()` over 12 samples took 46.9–81.4 ms with 50
  sensors and `available = yes`. The per-read cost is dominated by sensor I/O;
  the win is that it now runs off the main thread and 25 times less often while
  visible, and never while hidden.
- The CLI median above is the start-to-exit number, not a socket round trip.

To reproduce the CPU investigation, compare `ps -o %cpu= -p <pid>` over several
short intervals with only the menu bar visible, then with the popover open, then
with the displays asleep. Use `sample <pid> 5` to confirm where the time goes.
Do not use these commands to justify killing or relaunching a working session;
they are read-only measurements.

## Compatibility

These names and behaviours are part of the contract and must not change:

- Preference keys `keepAwake.simulateIdleActivity`,
  `keepAwake.defaultDuration`, `keepAwake.idleActivityDelayMinutes`, and
  `keepAwake.allowDisplaySleep`.
- URL commands `geraldine:activate?duration=indefinitely`,
  `geraldine:deactivate`, and `geraldine:toggle`.
- Power assertion name `Geraldine Keep Awake`.
- Main binary path `/Applications/Geraldine.app/Contents/MacOS/Geraldine`.
- The helper path `/Applications/Geraldine.app/Contents/Helpers/geraldine`.

The socket protocol and the JSON schema are versioned independently. Additive
fields do not bump `schemaVersion`; removing or changing the meaning of a field
does. A CLI from another build is rejected when `protocolVersion` differs.

## Development notes

`Sources/GeraldineControl` owns the protocol, socket, catalog, settings model,
duration parser, and the command line. `Sources/GeraldineCLI/main.swift` is the
executable entry point. The app side lives in `Sources/Geraldine/App/ControlHost.swift`,
`Sources/Geraldine/Control/`, and starts the server at the end of
`applicationDidFinishLaunching`; it stops it first in `applicationWillTerminate`.

Tests live in `Tests/GeraldineTests/AgentControlTests.swift` and cover the
envelope, socket permissions and ownership, live-socket protection, stale-socket
replacement, protocol mismatch, help and catalog shape, JSON errors and exit
codes, settings offline behaviour, the in-process latency bound, and the
optional real-binary latency bound.

```bash
# Targeted control tests, in-process only.
swift test --scratch-path <owned-path> --filter AgentControlTests

# Add the real-binary latency check.
GERALDINE_CLI_BINARY=<build>/GeraldineCLI \
  swift test --scratch-path <owned-path> --filter AgentControlTests

# Performance policies.
swift test --scratch-path <owned-path> \
  --filter 'StatusAnimationFramePolicyTests|MonitorDemandTests|DurationParserTests'
```

`FeatureSurfaceTests` needs `FEATURE_SURFACE_DIR` and native input; it is not
part of this surface and is not run for control changes.
