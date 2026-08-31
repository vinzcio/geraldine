# Plan 010: Keep idle-simulation pulse failures terminal

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of improvising. When done,
> update Plan 010's status in `plans/README.md` unless your reviewer says it owns
> the index.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/IdleActivitySimulator.swift Tests/GeraldineTests/IdleActivitySimulationServiceTests.swift`
> Compare the excerpts below with the live code. Any semantic mismatch in pulse
> failure, timer scheduling, or restart behavior is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: MED
- **Depends on**: none
- **Category**: bug, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

When Geraldine cannot post a synthetic input event, `pulse()` moves the service
to `.failed` and invalidates its timer. Both callers then immediately schedule
another timer anyway. The next retry can overwrite the reported failure with
`.waiting` or `.pulsing` and continue posting input after the UI said the
simulator failed. This plan makes the failure terminal until an existing,
explicit `start`/preference/permission restart occurs.

## Current state

- `Sources/Geraldine/Services/IdleActivitySimulator.swift` owns permission
  checks, HID idle reads, pulse creation, timer scheduling, and phase snapshots.
- `Sources/Geraldine/Services/KeepAwake.swift:350-379` owns when the simulator is
  started or stopped. Do not change that policy or file in this plan.
- `IdleActivitySimulationPhase.failed` already exists and
  `KeepAwakeController.idleActivityStatusLine` already presents its error. No new
  state or UI is needed.
- The service deliberately uses HID idle time rather than a global input event
  tap and limits keyboard pulses to opposing horizontal-arrow pairs. Preserve
  those safety decisions.

Current failure and scheduling behavior
(`Sources/Geraldine/Services/IdleActivitySimulator.swift:102-170`):

```swift
private func stopRuntime(phase: IdleActivitySimulationPhase, errorMessage: String? = nil) {
    timer?.invalidate()
    timer = nil
    isPulsing = false
    lastPulseUptime = nil
    self.errorMessage = errorMessage
    setPhase(phase)
}

// timerFired, while already pulsing
pulse()
schedule(after: nextPulseInterval())

private func beginPulsing() {
    isPulsing = true
    setPhase(.pulsing)
    pulse()
    schedule(after: nextPulseInterval())
}

private func pulse() {
    guard postPulse() else {
        stopRuntime(phase: .failed, errorMessage: "Could Not Post Input Events")
        return
    }
    // publish a successful pulse
}
```

The required invariant is: a failed pulse leaves phase `.failed`, preserves its
error message, owns no scheduled timer, and performs no further pulse attempt
until an existing explicit restart path calls `start`. Do not alter the current
idle-delay options, pulse interval/jitter, input tolerance, randomized action
mix, permission policy, or restart triggers.

## Commands you will need

There is no separate lint or typecheck command. Compile and test with the
verified Xcode 26.5 SDK.

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
PLAN_TMP="/private/tmp/geraldine-plan-010-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-010-$RESOURCE_TOKEN-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" \
  --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" \
  --owner "$PLAN_OWNER" \
  --purpose "Plan 010 focused and full Swift tests" \
  --profile swiftpm
```

| Purpose | Command | Expected on success |
|---|---|---|
| Clean isolated start | `test -z "$(git status --porcelain=v1 --untracked-files=all)"` | exit 0; no output |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter IdleActivitySimulationServiceTests` | exit 0; all focused tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build"` | exit 0; full suite passes |
| Patch hygiene | `git diff --check` | exit 0; no output |

The primary checkout contains unrelated, user-owned Dock-preview changes. Do
not execute this plan there. The dispatcher supplies a clean isolated checkout
based on the desired branch state and owns its lifecycle. The executor must not
create, register, finalize, or remove the checkout.

After the clean-start check and before editing:

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
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/IdleActivitySimulator.swift" && $0 != "Tests/GeraldineTests/IdleActivitySimulationServiceTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

After proof is captured, finalize temporary ownership:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" --state disposable \
  --reason "Plan 010 tests passed and proof is preserved in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/IdleActivitySimulator.swift`
- `Tests/GeraldineTests/IdleActivitySimulationServiceTests.swift` (create)
- `plans/README.md` (Plan 010 status cell only)

**Out of scope**:

- `KeepAwake.swift`, Keep Awake UI, URL automation, preferences, or assertion
  ownership.
- Idle-delay choices, pulse interval or jitter, real-input tolerance, timer
  minimums, randomized pulse actions, or key/mouse event shapes.
- Accessibility prompt behavior, TCC settings, or a new automatic retry policy.
- The current Dock-preview patch, `build.sh`, installed app, `.jj`, and any file
  not explicitly listed in scope.

## Git workflow

- Work only in the clean isolated checkout supplied by the dispatcher.
- Suggested branch: `codex/010-terminal-idle-pulse-failure`.
- If the dispatcher requests a commit, use an imperative message such as
  `Keep idle pulse failures terminal`.
- Do not create/finalize a worktree or commit unless separately assigned.
- Do not push, open a PR, install, launch, or exercise real synthetic input
  unless explicitly instructed.

## Steps

### Step 1: Add only the seams required to prove pulse failure

Add narrow internal injection points for the environmental reads that otherwise
make this state machine unsafe to test: Accessibility availability, current HID
idle duration, and the final pulse-post result. Production defaults must call
the exact existing implementations. Do not extract a generic timer framework or
change how random pulse actions are produced.

Expose at most one internal read-only observation needed by `@testable` tests to
prove whether a timer is scheduled; for example, `hasScheduledTimer`. Do not
make the timer mutable outside the service and do not add a DEBUG-only behavior
fork.

**Verify**: the focused command compiles with a smoke test using injected safe
closures; it must not post real CGEvents or query real TCC/HID state.

### Step 2: Make pulse success explicit at both scheduling sites

Change `pulse()` to return an explicit success value. On posting failure it must
call the existing `stopRuntime(phase:errorMessage:)`, return failure, and leave
the error text unchanged. On success it must retain the current `lastPulse`,
uptime, and `.pulsing` publication, then return success.

Both callers must schedule their next timer only after success:

- the already-pulsing branch in `timerFired()`;
- the first pulse in `beginPulsing()`.

Do not set `isEnabled` false on failure. Existing preference/permission flows
own whether an explicit later `start` retries; silently adding a retry or new
restart trigger is out of scope.

**Verify**: `rg -n -U 'pulse\(\)\n\s*schedule' Sources/Geraldine/Services/IdleActivitySimulator.swift`
returns no matches, and the focused test command passes.

### Step 3: Add deterministic failure and restart tests

Create `IdleActivitySimulationServiceTests.swift` with XCTest and `@testable
import Geraldine`. Use a mutable test pulse closure and snapshot recorder; never
post real input or wait on wall-clock timers.

Cover at least:

- an initial pulse failure produces `.failed`, the exact existing error message,
  one pulse attempt, and no scheduled timer;
- advancing the test/run loop without an explicit restart produces no further
  attempts and does not overwrite `.failed`;
- an explicit `start` after the injected poster becomes successful can enter
  `.pulsing` and schedule normally, proving restart remains user/policy-owned;
- a successful initial pulse preserves current last-pulse publication and owns
  one next timer;
- the already-pulsing timer path also stops scheduling after a failed pulse. If
  testing that path would require exposing a general mutable timer API, STOP and
  instead add a smaller internal state-machine method that both production call
  sites invoke and tests can drive deterministically.

**Verify**: the focused test command exits 0 with every case above passing.

### Step 4: Run complete verification and close temporary ownership

Run the full suite, hygiene check, and scope allowlist. Update only Plan 010's
README status cell, preserve proof in the transcript, and finalize the
registered SwiftPM root.

**Verify**:

- focused and full Swift tests exit 0;
- `git diff --check` exits 0;
- the scope allowlist emits no paths;
- CLAYGO closeout reports `status: pass` and no unresolved resources.

## Test plan

The required tests are in Step 3. The central regression assertion is a tuple:
`.failed` phase, existing error text, no timer, and no additional pulse count.
Testing only the return value of `pulse()` is insufficient because the defect is
owned by its two scheduling callers.

## Done criteria

- [ ] Both pulse call sites schedule only after a successful post.
- [ ] A posting failure remains `.failed` with no timer or automatic retry.
- [ ] Explicit restart still works through existing `start` ownership.
- [ ] Production permission, HID, CGEvent, timing, jitter, and action behavior is
      unchanged outside the failure gate.
- [ ] No test posts real synthetic input or waits for production intervals.
- [ ] Focused/full tests, patch hygiene, and exact scope allowlist pass.
- [ ] Plan 010's README status cell is updated.
- [ ] The SwiftPM root is removed and CLAYGO owner closeout passes.

## STOP conditions

Stop and report if:

- `pulse`, `beginPulsing`, or the pulsing branch of `timerFired` has drifted from
  the excerpt;
- the fix appears to require changing any duration, jitter, timer minimum,
  tolerance, retry count, permission rule, or input-event shape;
- tests would post real CGEvents, alter TCC permissions, or wait on production
  timers;
- `KeepAwake.swift`, UI, URL handling, or current Dock-preview files appear
  necessary;
- a focused verification fails twice after a reasonable correction.

## Maintenance notes

Any new pulse trigger must propagate the success/failure result before
scheduling more work. Reviewers should inspect both existing callers and ensure
future automatic-recovery proposals remain explicit product decisions rather
than silently weakening the terminal-failure invariant.
