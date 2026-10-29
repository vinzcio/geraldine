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
helper. Both executables receive the existing external-rpath sanitation before
signing. `GERALDINE_BUILD_ROOT` changes where `build.sh` assembles the bundle; it
does not change the runtime paths.

### Put it on PATH

Link the bundled helper into `~/.local/bin`:

```bash
/Applications/Geraldine.app/Contents/Helpers/geraldine install-cli
```

`install-cli` creates a symlink from `~/.local/bin/geraldine` to the executable
that invoked it, resolving an existing PATH symlink back to the helper. It is
idempotent, works without the app running, and prints whether the
destination is already on `PATH`. Use `--dir DIR` for another directory:

```bash
geraldine install-cli --dir /usr/local/bin
```

Replacing the app at the same path updates the helper reached through the link
automatically. If you move the app, run its bundled helper's `install-cli` again
to update the link. The installer preserves regular files and unrelated
symlinks; it only replaces an owned link to a Geraldine bundled helper. A
previous snapshot installation must be inspected and moved aside explicitly.
The destination must be writable by your user; the installer never uses sudo.
If `~/.local/bin` is
not on `PATH`, add it to the shell profile; the default macOS `PATH` does not
include it.

### One binary, two roles

The installed helper is the same executable whether it is launched from the
bundle or from `PATH`. It is Foundation-only and links no app frameworks, which
keeps startup small; isolated process timings are recorded below.

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
        "arguments": [
          { "name": "action", "type": "enum", "required": true, "description": "on, off, or toggle" },
          { "name": "--for", "type": "duration", "required": false, "description": "Duration for on/toggle, such as 90m or 1h30m" }
        ],
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

Running `geraldine` with no command invokes `status`, including its JSON output
and unavailable-app errors. It never implicitly launches the app.
Explicit `--help` exits `0` and also supports the JSON envelope.

## Running, closed, and degraded states

| Situation | Behaviour |
| --- | --- |
| App running, control socket ready | Every command works against live state. |
| App running, default control socket absent or refusing connections | Control commands exit `3`. `awake on\|off\|toggle` retains the legacy `geraldine:` URL fallback and reports `result.method = "url"`; the resulting state cannot be confirmed. `settings list\|get` read saved preferences with `appRunning: true`. `doctor` reports the socket failure. |
| Explicit socket unavailable | `--socket` and `GERALDINE_CONTROL_SOCKET` isolate the request to that endpoint. The CLI exits `3` without a URL fallback, launch, or saved-preferences fallback, including with `--launch`. |
| Connected socket returns an invalid reply or fails during I/O | The CLI reports an error and does not retry through another transport; a state-changing request may already have taken effect. |
| App closed | `settings list\|get` read the `com.vincent.geraldine` preference domain with `appRunning: false`; the four virtual keys are omitted from `list` and report `null` from `get`. Every other command exits `3` with a hint to open the app or pass `--launch`. |
| App closed, `--launch` | The CLI requests launch once and retries immediately without a fixed sleep, including for settings and doctor. A missing/refused retry exits `3` with an unconfirmed-readiness hint; connected/protocol failures retain their error meaning. There is no second transport attempt. |

Local commands never need the app: `commands`, `install-cli`, `help`,
`--version`, and read-only `settings`. `doctor` can run locally, but exits `3`
unless the app is running and the socket is ready, because its job is to prove
the control path.

While the app is starting, the socket may not exist yet. A command returns
`3` rather than waiting; retry the command, or poll `doctor`. `--launch` only
helps when the app is not running at all.

## Command reference

Global options, accepted before or after the command name:

| Option | Meaning |
| --- | --- |
| `--json` | Print one JSON envelope instead of human text. |
| `--socket PATH` | Use another Unix socket. Also `GERALDINE_CONTROL_SOCKET`. |
| `--timeout SECONDS` | Optional finite positive deadline for the entire request, including connect, send, read, and an explicit launch/retry. There is no implicit request deadline, including for doctor. Watch applies this budget to each sample request. |
| `--launch` | Open Geraldine if it is not running, then retry once. |
| `--no-color` | Accepted for compatibility; output is already plain text. |
| `--help`, `-h` | Overview, or help for the command that follows. |
| `--version`, `-v` | CLI, protocol, and schema versions. |

`GERALDINE_CONTROL_SOCKET` is the injectable path used by tests and wrappers.
An empty override is a usage error. The path must fit a Unix socket address
(about 104 bytes on macOS). Malformed options and unsupported extra arguments
are rejected before requests, launches, or installation.

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
  requested or default duration.
- If the app refuses to activate, the command returns `ok: false`, exit `1`,
  and the controller's error. A failure here means the controller could not
  start the session, for example because macOS refused an assertion.

Duration grammar: `90m`, `2h`, `1h30m`, `45s`, `1.5h`, `2 days`, bare minutes
(`90`), or `indefinitely` / `forever` / `infinite`. Fractions are allowed.
Durations must be finite, positive, and representable by the app's whole-second
display. Subsecond/fractional seconds round up; there is no product duration
ceiling. `awake off --for 5m` is a usage error.

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
geraldine stats [cpu|memory|gpu|network|battery|thermal|storage|all] [--watch <seconds>] [--json]
```

Returns the current reading for one metric, or all of them. It does not return
history: charts are a GUI surface. `all` also includes `uptimeSeconds`,
`sampledAt`, and `samplingPaused`. Requests read the existing cache and do not
start sampling hidden metrics.

`--watch <seconds>` requires an explicit finite positive representable interval.
It waits that interval between completed requests. With `--json` it emits one
envelope per line (NDJSON); errors go to stderr and stop the stream. In human
mode it reprints a block. Stop a watch with Ctrl-C.

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

GPU and thermal objects additionally carry `sampledAt`, `samplingPaused`,
`samplingState` (`neverSampled`, `observed`, or `paused`), and `pauseReason`
(`hidden`, `displaysAsleep`, `monitorStopped`, or null). Cached readings remain
available when sampling pauses and are labeled in warnings; never-sampled
readings are not presented as a fresh observation.

Byte counts are integers. Percentages are `0...100` doubles. A reading that has
not arrived yet is `null`, never `NaN` or a fabricated zero.

### `processes`

```text
geraldine processes [--top N] [--sort cpu|memory] [--json]
```

`--top` is a positive integer, default `10`; its doubled app sampling count must
fit an integer. Sorting is descending. Each row has `pid`,
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

`--refresh` starts independent background refreshes for accounts already
connected in the layout and returns cached values immediately. `refreshed`
remains false because the response does not wait for new values; a warning
confirms background work was requested. Each account retains its last successful
`fetchedAt`, and text output includes its age. Repeated requests coalesce only
for the same in-flight login. The official provider CLIs may contact their
providers and update local caches.
Geraldine sends no usage HTTP requests of its own and reads no Keychain.

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
invariants, installed-app directory presence, actual `geraldine` resolution on
the caller's supplied `PATH`, and CLI/app build identity.

- Missing permissions and a missing CLI install are `warn`, not failures.
- A mismatched or missing assertion while Keep Awake says it is active is a
  `fail`; so is an assertion held while Keep Awake is off or paused.
- With the app answering, any `fail` makes the command exit `1`.
- Run locally without a working socket, the command exits `3` and reports the
  socket as failed.

The result is `{ "checks": [{ "name", "status", "detail" }], "socket": "..." }`
with `status` in `ok`, `warn`, `fail`. The local fallback adds `appRunning` and
omits `socket` from the top level. Both include `appInstalled`,
`installedAppPath`, `cliAppIdentityMatch` (`match`, `mismatch`, `unknown`), and
`cli` with helper version, executable, `pathOnPATH`, `currentHelperOnPATH`, and
containing-bundle metadata when available. A PATH symlink is resolved to
`Contents/Helpers/geraldine` and its app's `Info.plist` using Foundation only.
The responding app's `app` identity includes version, build, commit,
shortCommit, isDirty, builtAt, and configuration. A mismatch fails doctor;
missing metadata or an unbundled debug helper is unknown, never a fabricated
match. Directory presence does not prove which app is running. Socket file
attributes alone never prove a successful handshake.

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
Human output shows a preview; JSON carries the full arrays returned by the
existing scanners, without additional CLI adapter truncation.

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

Each group carries every item the scanner returned. Skipped-path diagnostics
are preserved. Pre-existing scanner traversal/diagnostic limits remain; the
socket and adapters add no item or line-size ceiling.
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
geraldine help [command] [--json]
geraldine --version [--json]
```

`commands` and `install-cli` are local and never contact the app. `install-cli`
returns `installed`, `path`, `source`, and `onPath`; `path` is the symlink and
`source` is the resolved helper. `--version` prints
`geraldine 0.1.0 (protocol 1, schema 1)`. With `--json`, its envelope has
`command: "version"` and `result: { "version", "protocolVersion", "schemaVersion" }`.
JSON help has `command: "help"` and `result: { "topic", "usage" }`; `topic` is
`null` for the overview or a command name. Unknown help topics exit `2` on
stderr. String settings containing spaces need shell quotes so the value is
one argument.

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
  "warnings": []
}
```

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Stable output schema. Bumped only for a breaking field change. |
| `protocolVersion` | Socket protocol. A mismatch is rejected, never reinterpreted. |
| `id` | Request identifier, echoed by the app. Locally generated for local failures. |
| `command` | The command that produced the response. |
| `ok` | `false` for any failure, including usage errors. |
| `text` | Human lines. Omitted when the command has nothing to say. |
| `result` | Command-specific object or array. Omitted when the command returns no result. |
| `warnings` | Always an array, including when empty. |
| `error` | `{ "code", "message", "hint" }` when `ok` is false; omitted otherwise. |

Optional top-level fields are omitted rather than emitted as `null`; inside a
command's `result`, a field that has no value is present and `null`. That keeps
the envelope compact without making agents guess whether a result exists.

Error codes and exit status:

| Code | Exit | Meaning |
| --- | --- | --- |
| `usage` | 2 | Unknown command, missing argument, invalid value |
| `invalidValue` | 2 | A value was well-formed but not allowed |
| `failed` | 1 | The app accepted the request but the operation failed |
| `notRunning` | 3 | Geraldine is not running, or its control socket is unavailable |
| `unsupported` | 3 | Protocol version or build does not support the request |
| `permission` | 4 | A required macOS permission is missing |

`ok: true` always means exit `0`. A command can be `ok: true` with warnings, such
as cached GPU/thermal observations whose sampling is paused.

Requests and responses are newline framed without a product line-size cap.
New chunks are searched once rather than repeatedly rescanning a growing frame.
There is no implicit server/client request deadline; an explicit `--timeout`
bounds that caller's request. A partial reply cannot reset the budget.

## Security and privacy

- Socket path:
  `~/Library/Application Support/Geraldine/control.sock`, overridable with
  `GERALDINE_CONTROL_SOCKET`.
- A newly created containing directory uses mode `0700`. Vincent approved a
  targeted startup repair only for Geraldine's owned default directory: existing
  mode `0755` is tightened to `0700` through a checked directory descriptor.
  Other existing modes and all custom parents must already be private and owned
  by the current user. Symlink parents are rejected. The socket is `0600`, and
  permission-setting/read-back errors fail startup. The Oct 23 source checks
  used fixtures; the Oct 24 deployment verified the live default directory at
  `0700` and socket at `0600` (see the deployment record below).
- Both client and server call `getpeereid(2)` and reject a different effective
  UID. There is no token to leak, and no TCP port. The client checks protocol,
  schema, request ID, command, and success/error consistency on replies.
- Requests and responses are newline-delimited JSON. A request
  must match the protocol version before it is dispatched.
- Only an owned socket whose probe is refused is eligible for stale cleanup;
  the same device/inode must still occupy the path before unlink. Regular
  files, symlinks, foreign sockets, live sockets, and other probe errors are
  preserved. A nonblocking advisory lock on the directory serializes startup
  through bind/listen without creating a lock file.
- Stop unlinks only the socket it created and closes accepted connections.
  Replaced sockets/files are preserved. Start/stop and accept state are
  synchronized; old dispatch callbacks cannot act on a restarted listener.
  `SO_NOSIGPIPE` protects each socket without changing process-wide signals.
- A connection owns its handler task; peer EOF/disconnect or server stop cancels
  that task. Cancellation is cooperative and cannot undo a committed action.
  One source cancellation handler owns descriptor close, so a late result cannot
  write to a descriptor reused by a restarted server. The listener and connections
  use dispatch readiness events, with no server polling timer or request deadline.
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

Historical fixture measurement, 2026-10-23: a debug helper built with SDK 27.0
against an isolated Python Unix-socket fixture on this Mac, after the reviewed
CLI/socket repairs. There were 50 real start-to-exit subprocess runs, excluding
three warmups:

| Metric | Result |
| --- | --- |
| Median | 6.75 ms |
| p95 | 9.71 ms |
| Minimum | 5.88 ms |
| Maximum | 11.09 ms |

The CLI-focused run on 2026-10-23 passed 64 tests, including in-process and
real-binary latency checks, cancellation/restart, large frames, JSON numeric
types, typed catalog/arguments, doctor provenance, and the approved default-only
directory repair. Another 35 executable smoke cases passed, including a scan
response larger than 1 MiB and JSON watch lines. This is local SDK 27.0 fixture
proof; the canonical SDK 26.5 gate was unavailable, and no installed-app or
whole-app CPU acceptance is implied.

The real-subprocess regression test uses `posix_spawn` + `waitpid` because
`Process.waitUntilExit` polls a run loop inside XCTest and adds about 60 ms,
which would hide the real cost. The in-process test asserts p95 under 50 ms; the
real-binary test asserts median under 50 ms and is skipped unless
`GERALDINE_CLI_BINARY` points at a built helper. These are helper/transport
fixture bounds, not a bound on full status against the actual app:

```bash
GERALDINE_CLI_BINARY=<build>/GeraldineCLI \
  swift test --scratch-path <owned-scratch-path> \
  --filter AgentControlTests
```

On 2026-10-24, the installed release helper against the actual running
`a78fd04` app measured **99.7905 ms median / 117.0821 ms p95** for
`status --json` over 50 process start-to-exit launches, excluding three warmups.
Separate component medians were 6.137 ms for helper `version`, 10.054 ms for the
catalog, 5.765 ms for `stats cpu`, 0.132 ms for direct-socket stats, and
89.979 ms for direct-socket status.

The live profile placed 1,732 of 1,737 handler samples in the blocking
`SMAppService.status` XPC query. The parent's API investigation found no
supported KVO or external status notification to fully invalidate a cache;
local setters and app activation cannot cover external changes. Its Apple DTS
reference is [thread 784801](https://developer.apple.com/forums/thread/784801).
The deployment preserves fresh authoritative launch-at-login status and reports
this OS-bound latency. No latency code or freshness-policy change was made.

The server itself adds no idle work: it waits on a dispatch read source, not a
timer, and request handling runs off the accept path. It retains the listener
and directory descriptors plus the dispatch source while idle.

### App idle CPU

Historical investigation, 2026-10-23: the installed `993433a` build showed
recurring bursts in the low-to-mid teens as a percentage of one core while the
menu-bar animation was running. Six
two-second samples of the installed app returned 0.0, 6.7, 13.8, 4.0, 11.7, and
6.4% of one core. The work was concentrated in the 144 Hz
`MenuBarController.stepStatusAnimation` path, which built and assigned a new
`NSImage` on every display-link vblank, plus per-second thermal and GPU sampling
even when nothing displayed those values.

That source-only verification round did not relaunch the installed app because
a paid shift depended on its Keep Awake and Stay Active session. The Oct 24
deployment measurements are recorded below. Source preserves the original
uncapped animation rate and one-second visible thermal cadence. Source tests
can verify state and demand decisions; they cannot prove an idle-CPU percentage
or visual parity:

| Change | Before | After | Evidence |
| --- | --- | --- | --- |
| Status animation compositing | every display-link vblank, up to 144 fps | original uncapped display-link rate retained; cached plans/final images avoid redundant work | `MonitorRenderingReviewTests`, `MenuBarStatusAnimationPolicyTests` |
| Unchanged status redraws | one `NSImage` per monitor publish | skipped when the render signature is unchanged | `StatusRenderSignature` in `MenuBarController` |
| Shimmer | existing 10 s cooldown and interruption behavior | existing policy retained | `MenuBarStatusAnimationPolicyTests` |
| Thermal cadence while visible | 1 Hz | original 1 Hz cadence retained, sensor reads off the main actor | `MonitorDemandTests` |
| Thermal cadence while hidden | 1 Hz | none | demand wiring from menu bar, popover, and window |
| GPU discovery while hidden | 1 Hz | none | demand wiring |
| Monitor wakeups while displays sleep | 1 Hz timer | timer stopped on observed sleep; one refresh on wake; startup gap found Oct 24 | `SystemMonitor` screen-sleep observers; follow-up below |
| Thermal resource setup | SMC key metadata read repeatedly | successful SMC metadata cached with capacity derived from the actual key list; original per-read HID enumeration/recovery retained | `CThermal.c` |

On 2026-10-24, fresh display-asleep measurements (15 two-second samples per
revision) gave old `993433a` mean **0.8067%**, median **0.6%**, and installed
`a78fd04` mean **1.0267%**, median **0.9%** of one core. An earlier old-build run
gave mean 9.7733%, median 10.5%, but did not record display state; it is not a
matched before/after comparison. These measurements establish no CPU win.

The `a78fd04` app launched while `CGDisplayIsAsleep` was already true, but its
monitor retained `displaysAsleep=false` and continued thermal sampling. The
notification-only initialization missed sleep that preceded launch. At this
record, a source follow-up queried the online displays at initialization and
start/restart, and shared the monitor's sleep state with menu-bar rendering.
Final parent checks and installed follow-up verification were pending; the
source diff alone is not test or live-fix proof. The parent will record final
follow-up deployment evidence in its PR. No full awake-screen CPU comparison
or visual-parity acceptance is established here.

Historical component timings from the same machine, debug build:

- A post-change `Thermal.read()` over 12 samples took 46.9–81.4 ms with 50
  sensors and `available = yes`. The per-read cost is dominated by sensor I/O;
  these historical component samples are not a benchmark of the final reviewed
  thermal implementation. The current source moves reads off the main actor and
  skips hidden demand, while preserving the original visible cadence.
- The historical fixture CLI median is a process start-to-exit number, not a
  socket round trip.

To reproduce the CPU investigation, compare `ps -o %cpu= -p <pid>` over several
short intervals with only the menu bar visible, then with the popover open, then
with the displays asleep. Use `sample <pid> 5` to confirm where the time goes.
Do not use these commands to justify killing or relaunching a working session;
they are read-only measurements.

## Historical verification record — 2026-10-23

This source/fixture and temporary-package record predates the Oct 24 deployment.
The parent verified the shared repairs with the available SDK 27.0:

- 93 combined focused tests passed with no failures or skips, including the
  actual CLI → isolated socket → production `ControlHost` → fake IOPM and
  isolated preferences workflow.
- The full suite reused that test binary with `--skip-build`: 516 XCTest cases,
  9 optional visual/UI skips, no failures, plus 8 Swift Testing passes. That is
  515 passes and 9 skips, taking 91.46 seconds in XCTest (96.79 seconds including
  the wrapper). The 60-second Stay Active timer check used fake input and
  recorded successful pulses in 28 of 60 seconds.
- An initial clean release package completed in 80.11 seconds under a temporary
  `GERALDINE_BUILD_ROOT`, using the existing default ad-hoc signature. This
  preceded the helper rpath correction.
- After `build.sh` applied the existing external-rpath sanitizer to the helper
  before signing, final reassembly/resigning passed in 8.10 seconds with SDK
  27.0 and unchanged default ad-hoc signing. Final metadata reported
  `a086cb2f64c1-dirty`, `release`, and `2026-10-23T08:23:54Z`.
- Strict deep app and helper signature checks passed. Both binaries' rpaths
  are exactly `/usr/lib/swift` and `@loader_path`, with no external Xcode path.
  `LSUIElement` is true, and the helper links no AppKit or SwiftUI.
- The actual packaged helper passed 7 isolated checks in 3.22 seconds: JSON
  version, the 22-command typed catalog, fixture install, idempotent reinstall
  via symlink, catalog via symlink, socket status, and doctor metadata/caller
  PATH. These checks used fixture endpoints and never ran the app entry point.
- All 197 staged source/test/resource files plus `Package.swift` matched the
  working tree. Runtime source/tests were unchanged since the passing full
  suite, so no full-suite rerun was needed for the script/documentation repair.
  Shell syntax and the existing Dock-presentation packaging check passed after
  the correction.

At the end of that round, the canonical `verify.sh` gate had stopped before
building because its pinned SDK 26.5 was unavailable. SDK 27.0 source/fixture
and temporary ad-hoc-package proof did not replace that gate or installed/live
acceptance. No app entry point, real input, installation, notarization, live
preference/permission change, or visible UI was exercised in that round. The
installed running build at that time was `993433a`.

## Deployment record — 2026-10-24

This records the PR #31 rollout; the subsequent sleep-state repair had not yet
received final parent verification at record time.

- [PR #31](https://github.com/vinzcio/geraldine/pull/31) merged at
  `2026-10-24T13:16:10Z` as
  `a78fd0475de044c3b3b632006a7b1cf747b931ed`.
- The canonical `build.sh` release install used clean merged source, SDK 27.0,
  and the existing Developer ID certificate, Lloyd Vincent Luardo (team
  `4S9BMP9GU3`). Release metadata was clean, built
  `2026-10-24T13:18:09Z`. Strict deep app and helper signature checks passed.
- Built and installed CDHashes matched: app
  `6f8693cc3cd8eb53daddff34d947414e6f4d261b`, helper
  `ba4e5199d4dbe9786a96db7c1999c05e0bf1d5d3`. PID `20389` was verified at
  `/Applications/Geraldine.app/Contents/MacOS/Geraldine`, with matching CLI/app
  identity. Background `open -g` left the foreground ASN unchanged.
- Keep Awake was ON indefinitely; Stay Active was ON and pulsing, with the
  preserved one-minute idle delay and `allowDisplaySleep=false`. Independent
  `pmset` inspection confirmed both real IOPM assertions. All 9 doctor checks
  passed, including Accessibility, Full Disk Access, PATH, socket, and identity.
- The approved startup repair was verified: the default directory was `0700`,
  socket `0600`, both owned by UID `501`. The functional
  `~/.local/bin/geraldine` symlink resolved to the installed bundled helper.
- Both the old `993433a` bundle and new candidate assessed as
  `Unnotarized Developer ID` under `spctl`. No trust, quarantine, or
  signing-policy change was made; this is not notarization proof.

Parent evidence was recorded under
`/private/tmp/geraldine-ship-27f5bb0a-20261024`: installation/identity,
live status/doctor, launch policy, latency components/profile, and CPU records.
The parent checkpoint was `/private/tmp/geraldine-agent-cli-27f5bb0a.md`.
The live performance measurements and startup gap are detailed above. SDK 26.5
remained unavailable, so this SDK 27.0 install does not satisfy the pinned
`verify.sh` gate. Full awake-screen CPU and visual parity were not verified.

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

Tests live in `Tests/GeraldineTests/AgentControlTests.swift`,
`AgentControlRegressionTests.swift`, `AgentControlRound2Tests.swift`, and
`DurationParserTests.swift` and cover the
envelope, socket permissions and ownership, live-socket protection, stale-socket
replacement, protocol mismatch, help and catalog shape, JSON errors and exit
codes, settings offline behaviour, the in-process latency bound, and the
optional real-binary latency bound. Regression fixtures use disposable socket
directories, fake executable sources, and injected launch/URL effects.
Set `GERALDINE_CONTROL_TEST_ROOT` to an owned scratch fixture directory to keep
all temporary sockets and installer fixtures under that root.

```bash
# Targeted control tests, in-process only.
GERALDINE_CONTROL_TEST_ROOT=<owned-root>/fixtures \
  swift test --scratch-path <owned-root>/swiftpm \
  --filter 'AgentControlTests|AgentControlRegressionTests|AgentControlRound2Tests|DurationParserTests'

# Add the real-binary latency check.
GERALDINE_CLI_BINARY=<build>/GeraldineCLI \
GERALDINE_CONTROL_TEST_ROOT=<owned-root>/fixtures \
  swift test --scratch-path <owned-root>/swiftpm \
  --filter 'AgentControlTests|AgentControlRegressionTests|AgentControlRound2Tests|DurationParserTests'

# Performance policies.
swift test --scratch-path <owned-path> \
  --filter 'StatusAnimationFramePolicyTests|MonitorDemandTests|DurationParserTests'
```

`FeatureSurfaceTests` needs `FEATURE_SURFACE_DIR` and native input; it is not
part of this surface and is not run for control changes.
