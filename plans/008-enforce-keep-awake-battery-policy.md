# Plan 008: Enforce the Keep Awake battery policy at activation

> **Executor instructions**: Follow this plan in order and verify each step.
> Work in a clean isolated checkout supplied by the dispatcher. Stop on any
> STOP condition rather than broadening scope. When complete, update only Plan
> 008's status cell in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/KeepAwake.swift Tests/GeraldineTests/KeepAwakeControllerTests.swift`
> Compare the live code with the excerpts below. Semantic drift in activation,
> power-source handling, URL dispatch, or error clearing is a STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: bug, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

The setting is named **Deactivate On Battery**, but Keep Awake can be started
while the Mac is already on battery power. Enforcement currently happens only
when the setting changes or IOKit later delivers a power-source callback. The
controller can therefore create timers and sleep assertions contrary to the
visible policy. Activation must consult the same current-source policy before
starting any session.

## Current state

- `Sources/Geraldine/Services/KeepAwake.swift` owns Keep Awake state, timers,
  IOPM assertions, power-source observation, and URL automation.
- `Tests/GeraldineTests/KeepAwakeControllerTests.swift` is the existing
  `@MainActor` XCTest suite; extend it rather than adding another test file.
- Existing UI reads `lastError` while inactive, so no view change is needed.

The setting handles only a setting transition (`KeepAwake.swift:99-105`):

```swift
@Published var deactivateOnBattery: Bool {
    didSet {
        defaults.set(deactivateOnBattery, forKey: DefaultsKey.deactivateOnBattery)
        if deactivateOnBattery {
            handlePowerSourceChange()
        }
    }
}
```

All public start paths converge on an unchecked activation boundary
(`KeepAwake.swift:234-265`):

```swift
func activateDefault() { activate(duration: defaultDuration.seconds) }
func activate(option: KeepAwakeDuration) { activate(duration: option.seconds) }

func activate(duration: TimeInterval?) {
    lastError = nil
    isActive = true
    isPaused = false
    pauseReason = nil
    let now = Date()
    activeSince = now
    activeUntil = duration.map { now.addingTimeInterval(max(1, $0)) }
    updateRemaining()
    scheduleExpirationTimer()
    startTicker()
    refreshAssertions()
    applyIdleActivitySimulation()
}
```

Power-source callbacks use an uninjectable static read
(`KeepAwake.swift:430-433,522-526`):

```swift
private func handlePowerSourceChange() {
    guard deactivateOnBattery, isActive, Self.isOnBatteryPower() else { return }
    deactivate()
}

private static func isOnBatteryPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return (source as String) == (kIOPSBatteryPowerValue as String)
}
```

The required invariant is:

1. Policy disabled: activation remains allowed on AC, battery, or unknown.
2. Policy enabled + AC: activation remains unchanged.
3. Policy enabled + battery: create no new session dates, timers, idle
   simulation, or assertions. If a duration replacement reaches this boundary
   while an older session is active, end that older session first.
4. Refusal leaves the controller fully off and publishes one stable error
   explaining that Deactivate On Battery blocked Keep Awake.
5. Existing active-session power callbacks keep today's behavior: they call
   `deactivate()` and do not gain a new notification or persistence policy.
6. Recognized URL commands retain their current Boolean contract; `true` means
   recognized even when the policy prevents a session from starting.
7. An unknown IOKit source preserves today's non-battery fallback.

Do not add polling, debounce, timeouts, battery thresholds, notifications, new
preferences, or changes to durations and assertion behavior.

## Commands you will need

Before tests, prove this is a clean non-primary checkout, replace the
placeholder with the actual executor thread/session ID, and register only the
SwiftPM scratch root. Hash the raw owner ID before using it in paths:

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-008-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-008-$RESOURCE_TOKEN-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" \
  --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" \
  --owner "$PLAN_OWNER" \
  --purpose "Plan 008 focused and full Swift tests" \
  --profile swiftpm
git rev-parse HEAD > "$PLAN_TMP/base-commit"
```

| Purpose | Command | Expected on success |
|---|---|---|
| Clean isolated start | `test -z "$(git status --porcelain=v1 --untracked-files=all)"` | exit 0; no output |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter KeepAwakeControllerTests` | all controller tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build"` | full suite passes |
| Patch hygiene | `git diff --check` | exit 0; no output |

At closeout, this allowlist must emit no paths:

```sh
set -e
set -o pipefail
BASE="$(<"$PLAN_TMP/base-commit")"
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/KeepAwake.swift" && $0 != "Tests/GeraldineTests/KeepAwakeControllerTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

After proof is preserved in the transcript:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" --state disposable \
  --reason "Plan 008 tests passed and proof is preserved in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/KeepAwake.swift`
- `Tests/GeraldineTests/KeepAwakeControllerTests.swift`
- `plans/README.md` (Plan 008 status cell only)

**Out of scope**:

- Keep Awake views, settings labels, URL parsing and return semantics;
- duration choices, timer cadence, assertions, screen-lock policy, idle-pulse
  policy, and any new battery threshold/notification behavior;
- generic environment/IOKit abstraction, schema/default changes, and new
  limits;
- current Dock-preview work, `build.sh`, installed apps, and user data.

## Git workflow

- Work only in the clean isolated checkout supplied by the dispatcher.
- Suggested branch: `codex/008-enforce-keep-awake-battery-policy`.
- If the dispatcher requests a commit, use an imperative message such as
  `Enforce Keep Awake battery policy`.
- Do not create/finalize a worktree, commit, merge, push, install, or launch
  unless the dispatcher separately assigns that operation.

## Steps

### Step 1: Inject only the current battery read

Add a stored closure such as `currentPowerSourceIsBattery: () -> Bool` to
`KeepAwakeController`. Extend its initializer with a defaulted argument backed
by the current static IOKit reader. Existing call sites must compile unchanged.
Change policy code to call the stored closure while leaving the production
reader and its `false` fallback intact.

Do not inject timers, assertions, observers, a clock, or a general environment.

**Verify**: run existing `KeepAwakeControllerTests` before changing behavior.
They must pass with the production-default initializer.

### Step 2: Guard the single activation boundary

At the very start of `activate(duration:)`, evaluate only:

```swift
deactivateOnBattery && currentPowerSourceIsBattery()
```

When true, call the existing private `endSession()` only if a session is
already active, then publish one local refusal constant, for example `"Keep
Awake is off while Deactivate On Battery is enabled."`, and return before
`lastError = nil`, `isActive = true`, new dates, timers, assertions, or idle
simulation. Do not call public `deactivate()`, which would erase the refusal
message. Tests must assert the chosen constant rather than duplicating a second
literal.

Do not duplicate guards in `activateDefault`, `activate(option:)`, `toggle`,
`selectDuration`, or `handle(url:)`; their convergence on `activate(duration:)`
is the contract. Do not change the callback's existing `deactivate()` behavior.

**Verify**: inspect ordering in `activate(duration:)`, then run the focused
suite. The guard must be visibly before every session mutation.

### Step 3: Add deterministic entry-point and transition tests

Extend `KeepAwakeControllerTests.swift` using its existing `@MainActor`,
UUID-scoped `UserDefaults`, and `defer { controller.shutdown() }` conventions.
Inject closure values; do not read or change the developer Mac's real source.

Cover at least:

- policy enabled + AC permits activation;
- policy disabled + battery permits activation;
- policy enabled + battery blocks direct duration activation and leaves
  `isActive == false`, `statusLine == "Off"`, `activeUntil == nil`, and
  `remaining == nil` with the stable refusal error;
- `activateDefault`, `activate(option:)`, inactive `toggle`, URL `activate`,
  and inactive URL `toggle` all reach the same guard;
- replacing an active AC session after the injected source changes to battery
  ends the prior session and does not create a replacement;
- recognized blocked URL commands still return `true`;
- an active AC session still deactivates when the injected source changes to
  battery and the setting is enabled, preserving current callback semantics;
- a later allowed activation clears the earlier refusal via the existing
  `lastError = nil` path; and
- existing duration and URL-override tests remain unchanged.

Do not expose private timers/assertions or use sleeps. If checking a callback
requires a seam broader than the injected read, test the synchronous setting
`didSet` route instead.

### Step 4: Run full verification and close ownership

Run focused tests, full tests, `git diff --check`, and the scope allowlist.
Perform a scoped local review of ordering, unchanged callback behavior, URL
semantics, and the two-file diff. After any accepted fix, rerun focused/full
tests. Update only Plan 008's README status cell, then finalize the registered
SwiftPM root and close out its owner.

## Test plan

The focused suite must cover allowed AC, allowed battery with the policy off,
blocked battery through every existing activation surface, recognized URL
return values, existing active-session deactivation, and later recovery. All
power-source values are injected; no live IOKit state or installed app is part
of the proof.

## Done criteria

- [ ] One narrow injected current-source read retains the IOKit production
      default and unknown-source fallback.
- [ ] The single activation boundary checks policy before every mutation.
- [ ] Every existing UI/URL start surface reaches that boundary.
- [ ] Blocked activation leaves the session fully off with a stable error.
- [ ] Existing active-session source-change behavior, URL Boolean semantics,
      durations, timers, assertions, and settings remain unchanged.
- [ ] Focused and full tests pass under the explicit SDK.
- [ ] `git diff --check` and the scope allowlist pass.
- [ ] Only Plan 008's README status cell changes outside the two code files.
- [ ] SwiftPM scratch finalization and owner closeout pass.
- [ ] No build, install, launch, real power change, push, or packaging ran.

## STOP conditions

Stop and report if:

- the isolated checkout is dirty or the owner ID is unavailable;
- activation or power-source handling differs materially from the excerpts;
- correct enforcement appears to require a view, URL parser, new preference,
  timer/assertion change, notification, threshold, timeout, or polling policy;
- deterministic proof needs a real battery/charger change;
- any out-of-scope file appears necessary; or
- a verification fails twice after one reasonable in-scope correction.

## Maintenance notes

All future Keep Awake start surfaces must continue to call the single
`activate(duration:)` boundary. Keep the injected seam limited to one current
battery Boolean. Richer AC/UPS/unknown semantics, alerts, or threshold policies
are separate product decisions and are not authorized here.
