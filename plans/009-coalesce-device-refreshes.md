# Plan 009: Replay device refreshes that arrive during a scan

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of improvising. When done,
> update Plan 009's status in `plans/README.md` unless your reviewer says it owns
> the index.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/ConnectedDevices.swift Tests/GeraldineTests/DeviceMonitorRefreshTests.swift`
> Compare the excerpts below with the live code. Any semantic mismatch in
> refresh admission, scan ordering, or result publication is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug, perf, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

`DeviceMonitor` enumerates mounted drives and then waits for a comparatively
slow `system_profiler` process. A mount, unmount, rename, eject completion, or
popover refresh arriving during that interval is discarded. The first scan can
therefore publish a pre-event drive snapshot and leave it stale until some
unrelated later refresh. This plan preserves the one-scan-at-a-time invariant
while replaying exactly one coalesced follow-up whenever work arrived in flight.

## Current state

- `Sources/Geraldine/Services/ConnectedDevices.swift` owns device discovery,
  volume notifications, scan admission, result publication, and eject refreshes.
- `Sources/Geraldine/App/AppState.swift:47` creates one process-lifetime
  `DeviceMonitor`; do not change that ownership.
- `Sources/Geraldine/MenuBar/MenuBarController.swift:266-270` requests a refresh
  whenever the menu-bar panel opens. This remains a valid caller.
- `HANDOFF.md:58-61,89-91` defines Connected Devices as peripherals attached to
  this Mac, not a LAN scan, and deliberately combines Bluetooth and USB into one
  `system_profiler` invocation. Preserve that product boundary.

Current admission and scan order
(`Sources/Geraldine/Services/ConnectedDevices.swift:52-80`):

```swift
func start() {
    guard !observing else { return }
    observing = true
    let nc = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification,
                 NSWorkspace.didUnmountNotification,
                 NSWorkspace.didRenameVolumeNotification] {
        nc.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
    }
    refresh()
}

@objc private func volumesChanged() { refresh() }

func refresh() {
    guard !scanning else { return }
    scanning = true
    Task.detached(priority: .utility) {
        let drives = Self.scanDrives()
        let profile = Self.scanSystemProfiler()
        let all = (drives + profile.ios + profile.bluetooth).sorted(by: Self.order)
        await MainActor.run {
            self.devices = all
            // ...
            self.scanning = false
        }
    }
}
```

The required invariant is: at most one device scan runs at a time; any number of
requests during that scan collapse into one follow-up; a request during the
follow-up can schedule one more pass; and `scanning` does not flicker false
between chained passes. Do not add a freshness duration, polling interval,
timeout, cache-retention rule, or new scan cadence.

## Commands you will need

There is no separate lint or typecheck command. Compiling the Swift package and
running its XCTest target is the source-level gate. Use the Xcode 26.5 SDK that
was verified during planning rather than the currently selected Command Line
Tools SDK.

Before any build or test, prove this is a clean non-primary checkout, replace
the placeholder with the executor's actual Codex thread/session ID, and
register the exact scratch root. Hash the raw owner ID before using it in paths:

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-009-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-009-$RESOURCE_TOKEN-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" \
  --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" \
  --owner "$PLAN_OWNER" \
  --purpose "Plan 009 focused and full Swift tests" \
  --profile swiftpm
```

| Purpose | Command | Expected on success |
|---|---|---|
| Clean isolated start | `test -z "$(git status --porcelain=v1 --untracked-files=all)"` | exit 0; no output |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter DeviceMonitorRefreshTests` | exit 0; all focused tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build"` | exit 0; full suite passes |
| Patch hygiene | `git diff --check` | exit 0; no output |

The primary checkout currently contains unrelated, user-owned Dock-preview
changes. Do not execute this plan there. The dispatcher supplies a clean
isolated checkout whose base contains the desired branch state and owns that
checkout's lifecycle. The executor must not create, register, finalize, or
remove the checkout.

After the clean-start check and before editing, record the comparison base:

```sh
git rev-parse HEAD > "$PLAN_TMP/base-commit"
```

At closeout, this allowlist must emit no paths:

```sh
test -s "$PLAN_TMP/base-commit"
set -e
set -o pipefail
BASE="$(<"$PLAN_TMP/base-commit")"
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/ConnectedDevices.swift" && $0 != "Tests/GeraldineTests/DeviceMonitorRefreshTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

After all proof is captured in the executor transcript, finalize the registered
test root and close out its owner:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" --state disposable \
  --reason "Plan 009 tests passed and proof is preserved in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/ConnectedDevices.swift`
- `Tests/GeraldineTests/DeviceMonitorRefreshTests.swift` (create)
- `plans/README.md` (Plan 009 status cell only)

**Out of scope**:

- `AppState`, `MenuBarController`, menu-bar UI, widget layout, and notification
  registration.
- Splitting drive and peripheral providers or changing the single combined
  `system_profiler SPBluetoothDataType SPUSBDataType -json` call.
- Any freshness window, timer, timeout, polling cadence, cache lifetime, retry
  limit, or background-notification feature.
- Device ordering, low-battery thresholds, eject semantics, or error wording.
- The current Dock-preview patch, `build.sh`, installed app, `.jj`, and any file
  not explicitly listed in scope.

## Git workflow

- Work only in the clean isolated checkout supplied by the dispatcher.
- Suggested branch: `codex/009-coalesce-device-refreshes`.
- If the dispatcher requests a commit, use an imperative message such as
  `Replay device refreshes after scans`.
- Do not create/finalize a worktree or commit unless separately assigned.
- Do not push, open a PR, install, or launch Geraldine unless explicitly asked.

## Steps

### Step 1: Add a testable one-running-plus-one-pending coordinator

In `ConnectedDevices.swift`, add a small internal value type that owns only
refresh admission state. It needs three observable states in behavior, whether
represented by an enum or booleans: idle, running, and running with a pending
request.

- A request while idle transitions to running and returns `true` to start work.
- A request while running records pending and returns `false`.
- Further requests while pending remain coalesced and return `false`.
- Completion with no pending work transitions to idle and returns `false`.
- Completion with pending work consumes the pending bit, remains running, and
  returns `true` to start exactly one follow-up.

Keep this coordinator free of AppKit, `Task`, `Shell`, dates, and timers so it is
deterministically testable. Do not encode a time window.

**Verify**: run the focused command. It must compile after adding initial
coordinator tests; every completed test must pass.

### Step 2: Route every refresh through the coordinator

Replace `guard !scanning else { return }` with coordinator admission. Move the
existing detached body into one private start-scan method that is called only
when admission or completion says work should start. Preserve this exact
production scan order:

1. enumerate drives;
2. run the single Bluetooth/USB profiler command;
3. combine and sort;
4. publish devices and prune eject errors on `MainActor`.

After publication, ask the coordinator whether a follow-up is pending. If so,
start it immediately and leave published `scanning` true. If not, set
`scanning` false. A follow-up must never overlap the finishing scan.

Add the narrowest scanner seam needed for deterministic integration tests. A
small internal `@Sendable` closure/value with a production default is preferred;
do not create an application-wide process framework or move ownership out of
`DeviceMonitor`.

**Verify**: the focused tests must show one scan in flight and no publication or
state transition from a second concurrent scan.

### Step 3: Characterize coalescing and final-state publication

Create `DeviceMonitorRefreshTests.swift` with XCTest and `@testable import
Geraldine`. Model the pure state tests on
`Tests/GeraldineTests/DockActiveClickBehaviorTests.swift`; model injected worker
control on the closure-based seams in `MonitorHistoryStoreTests.swift`.

Cover at least:

- the first request starts one scan;
- multiple requests during that scan start no parallel work and collapse to one
  pending follow-up;
- first completion starts exactly one follow-up without an idle/scanning-false
  transition in between;
- completion with no pending request returns to idle;
- a request during the follow-up schedules exactly one later third pass;
- controlled first and second scan results prove the final published `devices`
  value comes from the coalesced follow-up, representing a volume event that
  arrived after the first drive enumeration;
- device ordering and eject-error pruning remain unchanged.

Do not invoke the real `system_profiler`, eject a volume, or rely on sleeps.
Use controlled continuations/gates and deterministic scanner results.

**Verify**: the focused command exits 0 with all named cases passing.

### Step 4: Run the complete source gate and close temporary ownership

Run the full suite, hygiene check, and allowlist. Preserve the output in the
task transcript, update only Plan 009's README status cell, then mark/finalize
the SwiftPM root and run owner closeout.

**Verify**:

- the focused and full commands exit 0;
- `git diff --check` exits 0;
- the scope allowlist emits no paths;
- CLAYGO closeout reports `status: pass` with no unresolved resources.

## Test plan

The required cases are in Step 3. Tests must prove both the coordinator policy
and its `DeviceMonitor` integration. The regression is not covered by merely
asserting a pending boolean: a controlled first/second result must prove the
latest snapshot lands and scans never overlap.

## Done criteria

- [ ] Requests during a scan are replayed as exactly one coalesced follow-up.
- [ ] No two device scanners run concurrently.
- [ ] `scanning` stays true between chained passes and becomes false only when
      no pending work remains.
- [ ] The final published device list reflects the follow-up result.
- [ ] No scan cadence, timeout, cache, device semantics, or UI behavior changed.
- [ ] Focused and full Swift tests pass with the verified Xcode SDK.
- [ ] `git diff --check` and the exact scope allowlist pass.
- [ ] Plan 009's README status cell is updated.
- [ ] The registered SwiftPM root is removed and owner closeout passes.

## STOP conditions

Stop and report if:

- the current refresh flow or scan order differs semantically from the excerpt;
- the intended fix appears to require a freshness interval, retry count,
  timeout, polling change, or separate background monitor;
- deterministic tests would need the real `system_profiler` or a real mounted
  volume;
- any AppState/menu-bar/UI or current Dock-preview file appears necessary;
- another device scan can overlap after two reasonable implementation attempts;
- any verification fails twice after a focused correction.

## Maintenance notes

Future device sources must request work through the same coordinator instead of
creating their own in-flight flags. Reviewers should scrutinize the completion
transition and confirm `scanning` cannot flicker between chained passes. A
future proposal to split drive and peripheral refresh cadence is a separate
product/performance decision and is not authorized by this plan.
