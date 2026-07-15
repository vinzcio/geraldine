# Plan 005: Extract the global keyboard policy into a reducer

> **Executor instructions**: Complete Plan 004 first. Follow each step and
> verify exact pass/suppress behavior; a global event-tap regression can affect
> every app. Stop on any STOP condition and update Plan 005's README row when
> complete unless a reviewer owns the index.
>
> **Drift check (run first)**:
> `git diff --stat c8aeca4 -- Sources/Geraldine/Services/PowerTools.swift Tests/GeraldineTests/KeyboardPowerToolsReducerTests.swift`
> Planned changes from Plans 003 and 004 are expected. Reconcile them, but stop
> if `KeyboardPowerToolsService.handle` semantics changed independently.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/004-async-power-tools-effects.md`
- **Category**: tests, tech-debt
- **Planned at**: commit `c8aeca4`, 2026-07-15

## Why this matters

The event tap suppresses a global key whenever its callback returns true.
Today modifier checks, UserDefaults reads, frontmost-app/focus checks,
double-tap timing, mutable history, beeps, and Finder side effects are
interleaved in one untested method. Extracting a deterministic reducer makes
every pass/suppress decision table-testable while leaving `CGEvent`, AppKit,
and Finder execution in a thin adapter.

## Current state

- `EventTapService.callback` returns `nil` when the handler says to suppress the
  event (`PowerTools.swift:288-300`).
- `KeyboardPowerToolsService.handle` handles Command-Q/W safety, Finder Return,
  Option-N, and Command-X/V (`PowerTools.swift:480-548`).
- Double-tap state is keyed by PID and key code and uses `Date()` with a 1.15s
  acceptance window (`PowerTools.swift:550-564`).
- `KeyboardTransportReducer` is the repository exemplar: a pure stateful value
  in `KeyboardTransportMonitor.swift:68-125`, table-tested in
  `KeyboardTransportReducerTests.swift:24-96`.

Current double-tap branch:

```swift
if keyCode == KeyCode.q, defaults.bool(forKey: PowerToolKeys.commandQDoubleTap) {
    if isAutorepeat { return true }
    return blockFirstTap(keyCode: keyCode,
                         app: NSWorkspace.shared.frontmostApplication)
}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prerequisite | `git ls-files --error-unmatch Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift && git diff --quiet HEAD -- Sources/Geraldine/Services/PowerTools.swift Sources/Geraldine/Features/PowerTools/PowerToolsView.swift Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift && git diff --cached --quiet HEAD -- Sources/Geraldine/Services/PowerTools.swift Sources/Geraldine/Features/PowerTools/PowerToolsView.swift Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift && swift test --scratch-path /tmp/geraldine-plan-005-prerequisite --filter PowerToolsOperationCoordinatorTests` | exit 0; committed base contains completed Plan 004 |
| Focused tests | `swift test --scratch-path /tmp/geraldine-plan-005-tests --filter KeyboardPowerToolsReducerTests` | exit 0 |
| Full tests | `swift test --scratch-path /tmp/geraldine-plan-005-full` | exit 0 |
| Old helper | `! rg -n 'blockFirstTap' Sources/Geraldine/Services/PowerTools.swift` | exit 0, no output |
| Marker shape | `test "$(rg -c '^// MARK: - Keyboard Power Tools Reducer$' Sources/Geraldine/Services/PowerTools.swift)" -eq 1 && test "$(rg -c '^// MARK: - Keyboard Power Tools Service$' Sources/Geraldine/Services/PowerTools.swift)" -eq 1` | exit 0 |
| Reducer slice | `sed -n '/MARK: - Keyboard Power Tools Reducer/,/MARK: - Keyboard Power Tools Service/p' Sources/Geraldine/Services/PowerTools.swift > /tmp/geraldine-keyboard-reducer.swift` | exit 0 |
| Pure reducer | `test -s /tmp/geraldine-keyboard-reducer.swift && ! rg -e 'UserDefaults' -e 'NSWorkspace' -e 'NSSound' -e 'Date\(' /tmp/geraldine-keyboard-reducer.swift` | exit 0, no output |
| Hygiene | `git diff --check` | exit 0 |

**User-patch guard (run before and after implementation):**

```sh
test "$(git diff -- Sources/Geraldine/MenuBar/MetricWidgets.swift | shasum -a 256 | cut -d ' ' -f 1)" = da9ee6c4eafd807623c825613e33929a61f9966d00981be10ca9f8739c56c5c3
```

**Plan-base and scope guard:** after the prerequisite command and before any
edit, run:

```sh
git rev-parse HEAD > /tmp/geraldine-plan-005-base
unexpected="$({ git diff --name-only HEAD -- Sources Tests; git diff --cached --name-only HEAD -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

If the base file goes missing after edits, STOP. At closeout run:

```sh
test -s /tmp/geraldine-plan-005-base
unexpected="$({ git diff --name-only "$(</tmp/geraldine-plan-005-base)" -- Sources Tests; git diff --cached --name-only "$(</tmp/geraldine-plan-005-base)" -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/Services/PowerTools\.swift$' -e '^Tests/GeraldineTests/KeyboardPowerToolsReducerTests\.swift$' -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Tests/GeraldineTests/KeyboardPowerToolsReducerTests.swift` (create)
- `plans/README.md` (Plan 005 status cell only)

**Out of scope**:

- Event-tap creation, timeout re-enabling, Dock/traffic-light behavior, or
  Accessibility permission flows.
- Changing existing shortcuts, timing windows, sounds, or Finder actions.
- Live global keyboard automation in the unit tests.
- Power Tools async file/process work completed by Plan 004.
- `MetricWidgets.swift` and jj metadata.

## Git workflow

- Start only from a commit where Plan 004 is complete and its focused tests
  pass; do not carry Plan 004 source edits uncommitted.
- Branch: `codex/005-keyboard-power-tools-reducer`, created from that verified
  prerequisite commit.
- Suggested commit: `Test global keyboard policy`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Define normalized input, preferences, and decisions

Add internal value types under explicit
`// MARK: - Keyboard Power Tools Reducer` and
`// MARK: - Keyboard Power Tools Service` boundaries containing only the
reducer inputs:

- key code, normalized modifier flags, and autorepeat. Normalize by intersecting
  raw flags with Command, Shift, Control, and Option only; Caps Lock, Numeric
  Pad, Function, and device-dependent flags remain ignored exactly as today;
- monotonic timestamp;
- optional frontmost PID and bundle identifier. For Command-Q/W history, map a
  missing application snapshot to PID `0`, preserving current protection when
  `NSWorkspace.frontmostApplication` is nil;
- whether Finder focus can accept file shortcuts;
- whether a Finder cut session exists;
- a snapshot of the five relevant feature preferences.

Define an explicit decision containing `suppress: Bool` and an optional effect:
beep, open Finder selection, create text file, prepare cut, or paste cut. Effects
are descriptions only; the reducer must not call AppKit, defaults, sound, or
Finder services.

Create `KeyboardPowerToolsReducerTests.swift` in this step with a compile-smoke
test. Steps 2 and 3 add their named behavior cases immediately; Step 5 completes
the remaining matrix.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-005-tests --filter KeyboardPowerToolsReducerTests`
compiles; zero tests is acceptable only at this intermediate step.

### Step 2: Move double-tap state and policy into the reducer

Create `KeyboardPowerToolsReducer` as a value type. Preserve existing behavior:

- first enabled Command-Q/W for a PID/key suppresses and requests a beep;
- the same PID/key with elapsed time strictly `< 1.15` seconds passes through
  and clears that key; exactly `1.15` is a new blocked first tap;
- entries are retained only while age is strictly `< 2`; exactly `2.0` is
  pruned;
- Q and W and different PIDs have independent state;
- autorepeat for protected shortcuts is suppressed without triggering effects;
- `reset()` clears timing state when the service stops.

Use the injected monotonic timestamp, not `Date()` inside the reducer.

**Verify**:
add `testDoubleTapTimingBoundaries`, then run:

```sh
swift test --scratch-path /tmp/geraldine-plan-005-tests --filter KeyboardPowerToolsReducerTests/testDoubleTapTimingBoundaries > /tmp/geraldine-plan-005-timing.log 2>&1
rg -q 'Executed 1 test' /tmp/geraldine-plan-005-timing.log
```

The case must cover `1.149`, `1.15`, `1.999`, and `2.0`, plus a nil-frontmost
snapshot using the PID-`0` bucket.

### Step 3: Encode Finder shortcut policy as pure decisions

Preserve exact modifier and context rules:

- unmodified Return in focused Finder may suppress and request Open;
- Option-N alone may suppress and request Create Text File;
- Command-X alone may suppress and request Prepare Cut;
- Command-V alone suppresses only when a cut session exists;
- non-Finder apps, unfocused Finder contexts, extra primary modifiers, disabled
  preferences, and unrelated keys pass through; ignored non-primary flags such
  as Caps Lock do not change the current decision;
- autorepeat suppresses an otherwise handled Finder shortcut without executing
  its effect.

**Verify**:
add `testFinderDecisionTable`, then run:

```sh
swift test --scratch-path /tmp/geraldine-plan-005-tests --filter KeyboardPowerToolsReducerTests/testFinderDecisionTable > /tmp/geraldine-plan-005-finder.log 2>&1
rg -q 'Executed 1 test' /tmp/geraldine-plan-005-finder.log
```

The table must include every pass/suppress/effect branch, extra primary
modifiers, and ignored-flag rows.

### Step 4: Reduce the live handler to an adapter

`KeyboardPowerToolsService.handle` should read `CGEvent`, preferences,
frontmost-app identity/focus, and cut-session presence; call the reducer once;
dispatch the returned effect on main; and return `decision.suppress`.

`stop()` must call reducer reset. Keep Plan 004's async/background ownership for
effects that may be slow; this adapter must not reintroduce synchronous copy,
move, checksum, or paste work on the event-tap callback.

**Verify**:
run the “Old helper” and “Pure reducer” commands above; both exit 0. The live
adapter may snapshot `UserDefaults`, but the marked reducer section may not.

### Step 5: Complete the exhaustive reducer tests

Create `KeyboardPowerToolsReducerTests.swift`, modeled on
`KeyboardTransportReducerTests`. Include:

- first/second/expired Command-Q and Command-W presses;
- exact `1.15`-second acceptance and `2.0`-second pruning boundaries;
- PID and key independence;
- missing frontmost application uses the protected PID-`0` history bucket;
- autorepeat, extra primary modifiers, and ignored Caps Lock/device flags;
- disabled preference behavior;
- Finder Return, Option-N, Command-X, and Command-V with and without cut state;
- non-Finder and Finder-focus rejection;
- reset behavior;
- every effect paired with its expected suppress flag.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-005-tests --filter KeyboardPowerToolsReducerTests`
passes.

### Step 6: Run the full gate

**Verify**:

- `swift test --scratch-path /tmp/geraldine-plan-005-full` exits 0.
- `git diff --check` exits 0.
- the scope allowlist emits no output, and the recorded `MetricWidgets.swift`
  diff hash is unchanged.

## Test plan

Step 5 is the required matrix. Tests must use numeric monotonic timestamps and
plain context values; never synthesize or post real `CGEvent`s. A later
installed-app pass should manually verify one protected Command-W sequence and
one Finder shortcut only after explicit authorization.

## Done criteria

- [ ] Every global keyboard decision comes from the pure reducer.
- [ ] Reducer code has no AppKit, UserDefaults, sound, Finder, or wall-clock calls.
- [ ] Live handler is a thin snapshot/effect adapter.
- [ ] Full decision matrix, reset behavior, full suite, and hygiene checks pass.
- [ ] Only in-scope files changed.
- [ ] The pre-existing `MetricWidgets.swift` diff hash is unchanged.
- [ ] Plan 005's README status is updated.

## STOP conditions

Stop and report if:

- Plan 004 is incomplete or live effect APIs no longer match these assumptions;
- tests expose ambiguity in current pass/suppress behavior; preserve current
  behavior and request a product decision rather than choosing silently;
- extraction would modify event-tap lifecycle or Accessibility permissions;
- source drift, repeated verification failure, or out-of-scope edits occur.

## Maintenance notes

Any new global shortcut must add reducer cases and pass/suppress tests before it
is connected to the event tap. Reviewers should scrutinize autorepeat,
modifier normalization, stale timing entries, PID reuse, and effect execution
on the correct actor.
