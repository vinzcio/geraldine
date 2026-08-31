# Plan 005: Extract the global keyboard policy into a reducer

> **Executor instructions**: Execute serially after Plan 004 is integrated and
> its focused tests pass. Preserve every pass/suppress/effect decision exactly;
> a global event-tap regression affects every app. The dispatcher owns
> `plans/README.md`, the checkout/worktree, commits, and integration.
>
> **Current handoff**: refreshed in the source-only export
> `/private/tmp/geraldine-power-tools-lane-01a05441`. It has no `.git`, so source
> and tests may be implemented and statically reviewed there, but the Git/build
> gates below remain mandatory for the integration owner and must not be
> reported as run from the export.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (global suppression policy)
- **Depends on**: completed `plans/004-async-power-tools-effects.md`
- **Also preserves**: Plan 007 Dock targeting in the same source file and Plan
  001's Finder Backspace-to-Trash boundary
- **Category**: correctness, tests, maintainability
- **Prepared from**: repository commit `cd1d60403c1221a8be104c4c11567b40ad816062`
  plus the post-Plan-007 source fingerprint documented in Plan 004,
  2026-08-31

## Why this matters

The event tap suppresses a global key whenever its callback returns `true`.
The current handler interleaves raw flags, defaults, frontmost/focus checks,
wall-clock state, beeps, and Finder effects. A pure reducer makes that policy
deterministic while leaving `CGEvent`, AppKit, Accessibility, and async Finder
execution in a thin adapter.

## Verified current decision contract

The current pre-Plan-004 keyboard service slice has SHA-256
`f0e2e36f2ebd1382f2641984fea4500e38de94ad3e56b0a0efe79bc235ff09b4`.
Plan 004 is expected to alter only effect dispatch/API shapes, so Plan 005 must
recon the post-004 handler rather than require this old whole-slice hash.

There are **six preferences and seven effectful branches**, not the obsolete
five-preference contract:

1. Command-Q double-tap safety;
2. Command-W double-tap safety;
3. Finder Return opens selection;
4. Finder Option-N creates a text file;
5. Finder unmodified Backspace/Delete (`keyCode 51`) moves selection to Trash;
6. Finder Command-X prepares a cut session; and
7. Finder Command-V transfers only when a cut session exists.

Current protected-key behavior is load-bearing:

```swift
if isAutorepeat { return true }
let appPID = app?.processIdentifier ?? 0
lastSafetyPress = lastSafetyPress.filter { now.timeIntervalSince($0.value) < 2 }
let previous = lastSafetyPress[safetyKey]
lastSafetyPress[safetyKey] = now
if let previous, now.timeIntervalSince(previous) < 1.15 {
    lastSafetyPress[safetyKey] = nil
    return false
}
```

Finder handling is entered only for frontmost bundle
`com.apple.finder` when `AXTools.canHandleFinderFileShortcut` is true. Primary
modifiers are Command, Shift, Control, and Option. Caps Lock, Numeric Pad,
Function, and device-dependent bits are ignored exactly as the current flag
tests ignore them. Every otherwise-handled autorepeat is suppressed with no
effect. Command-V without a cut session passes through.

## Scope

**Only implementation/test files in scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Tests/GeraldineTests/KeyboardPowerToolsReducerTests.swift` (new)

**Plan-maintenance file in scope before implementation only**:

- `plans/005-keyboard-power-tools-reducer.md`

**Out of scope**:

- `plans/README.md` and `Sources/Geraldine/MenuBar/MetricWidgets.swift`
- `PowerToolsView.swift` and Plan 004 coordinator/runner semantics
- Plan 007 `DockTarget`, Dock/traffic-light/Mission Control behavior
- event-tap creation, timeout recovery, run-loop ownership, Accessibility
  permission flow, shortcut/preferences/default values, sound choice, timing
  thresholds, Finder action/result semantics, or cut-session lifecycle
- live event posting, Finder/UI automation, build/install/launch, commit/push/PR
  in the source-only handoff

## Fail-closed post-Plan-004 preflight

Run from the same clean isolated integration checkout after Plan 004 has been
committed or otherwise made the clean `HEAD`. This plan deliberately does not
guess the post-004 `PowerTools.swift` hash.

```sh
set -e
set -o pipefail
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
git merge-base --is-ancestor c1f51ea HEAD
git ls-files --error-unmatch \
  Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift \
  Tests/GeraldineTests/FinderTrashShortcutTests.swift \
  Tests/GeraldineTests/DockTargetResolutionTests.swift
rg -n '^struct PowerToolsOperationCoordinator|^enum PowerToolsEffectRunner|runningActionID' \
  Sources/Geraldine/Services/PowerTools.swift
rg -n 'finderBackspaceMovesToTrash|KeyCode\.delete|moveFinderSelectionToTrash' \
  Sources/Geraldine/Services/PowerTools.swift
rg -n 'KeyCode\.q|KeyCode\.w|KeyCode\.returnKey|KeyCode\.n|KeyCode\.x|KeyCode\.v' \
  Sources/Geraldine/Services/PowerTools.swift

dock_slice="$(sed -n '/^private struct DockTarget {/,/^}$/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$dock_slice" | shasum -a 256 | awk '{print $1}')" = \
  'b3b79935ac8ac84c3b741d12d9fba31d5cc8dea770a953f4aa6b7d593057c6ac'
```

Expected: exact clean checkout, Plan 004 types/tests exist, all seven current
branches print, and the Plan 007 slice matches. Otherwise STOP and refresh this
plan against the post-004 source.

## CLAYGO and verification substrate

```sh
PLAN005_OWNER='<current-thread-or-session-id>'
test "$PLAN005_OWNER" != '<current-thread-or-session-id>'
PLAN005_ROOT="/private/tmp/geraldine-plan-005-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN005_RECEIPT="/tmp/$(basename "$PLAN005_ROOT")-receipt.json"
test ! -e "$PLAN005_ROOT"
test ! -e "$PLAN005_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN005_ROOT" --temp-root /private/tmp --receipt "$PLAN005_RECEIPT" \
  --owner "$PLAN005_OWNER" --purpose "Geraldine Plan 005 SwiftPM verification" \
  --profile swiftpm
git rev-parse HEAD > "$PLAN005_ROOT/executor-base"
df -Pk /private/tmp
pgrep -afil 'swift-build|swift-test|xcodebuild' || true

test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = '26.5'
test -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
```

If disk/concurrent-build inspection says a heavy gate is unsafe, defer only the
build/test commands. The dispatcher owns the checkout lifecycle; this executor
owns only the registered SwiftPM root.

## Steps

### Step 1: Define pure snapshots and explicit decisions

Under exactly one `// MARK: - Keyboard Power Tools Reducer`, add internal value
types for:

- key code, normalized primary modifiers, autorepeat, and monotonic timestamp;
- optional frontmost PID/bundle identifier, Finder-focus eligibility, and cut
  session presence;
- a snapshot of all six relevant preferences; and
- a decision containing `suppress` plus optional effect: beep, open Finder
  selection, create text file, move Finder selection to Trash, prepare cut, or
  paste cut.

The reducer section must contain no `CGEvent`, `UserDefaults`, `NSWorkspace`,
`NSSound`, Finder service call, Accessibility call, or `Date()`. Modifier
normalization from `CGEventFlags` belongs in the service adapter section.

### Step 2: Move double-tap state into the reducer

Use the injected monotonic timestamp. Preserve exactly:

- enabled Command-Q/W first press: suppress + beep;
- same PID/key with elapsed time strictly `< 1.15`: pass and clear;
- exactly `1.15`: suppress + beep as a new first press;
- prune ages not strictly `< 2`; exactly `2.0` is removed;
- Q/W and different PIDs have independent histories;
- missing frontmost app uses PID `0`;
- protected autorepeat suppresses without beep or state mutation; and
- `reset()` removes all history when the service stops.

Expose only a narrow read-only pending-history count if needed to directly test
the otherwise unobservable `1.999`/`2.0` pruning boundary.

### Step 3: Encode the full Finder decision table

After the safety branch, require exact Finder identity and focus. Preserve:

- no-primary Return -> suppress/open when enabled;
- Option-only N -> suppress/create when enabled;
- no-primary Backspace/Delete 51 -> suppress/move-to-Trash when enabled;
- Command-only X -> suppress/prepare cut when enabled;
- Command-only V -> suppress/paste only when enabled and a cut session exists;
- autorepeat for any otherwise-handled Finder shortcut -> suppress/no effect;
- extra primary modifiers, disabled preferences, unrelated keys, non-Finder,
  unfocused Finder, and Command-V without cut state -> pass/no effect; and
- ignored non-primary flags do not change the decision.

### Step 4: Make the live service a thin adapter

Under exactly one `// MARK: - Keyboard Power Tools Service`, the handler must:

1. read one raw event snapshot;
2. normalize modifiers;
3. snapshot all six defaults, frontmost identity/focus, cut-session state, and
   `ProcessInfo.processInfo.systemUptime` (monotonic);
4. invoke the reducer exactly once;
5. dispatch the described effect on `@MainActor`; and
6. return `decision.suppress`.

Keep Plan 004's async effect split: Backspace Trash and Command-V transfer are
awaited async from a main-actor task, never executed synchronously inside the
event-tap callback. Other Finder/AppKit effects retain their current actor and
result semantics. Preserve the old main-queue FIFO behavior for Option-N,
Backspace, Command-X, and Command-V with one token-safe serial queue: a shortcut
that the reducer suppresses must not be silently dropped merely because an
earlier file effect is awaiting. `stop()` stops the tap and calls
`reducer.reset()`.

Keep `KeyboardPowerToolsService.isFinderTrashShortcut(keyCode:flags:)` as a
compatibility policy seam for the existing `FinderTrashShortcutTests`; it must
agree with normalized no-primary Delete behavior and must not execute effects.

### Step 5: Add exhaustive reducer tests

Create `KeyboardPowerToolsReducerTests.swift` using plain inputs and numeric
timestamps only. No real `CGEvent`, event posting, AppKit, Finder, sound, or
live permissions. Cover:

- Q and W first/second/expired presses, `1.149`, `1.15`, `1.999`, and `2.0`;
- PID/key independence, PID `0`, protected autorepeat, and reset;
- every Finder pass/suppress/effect branch, including Backspace-to-Trash;
- FIFO file-effect admission, stale-completion rejection, and queue
  invalidation without a live Finder or event tap;
- Command-V with and without cut state;
- disabled preferences, unrelated key, non-Finder, and Finder focus rejection;
- extra primary modifier rejection; and
- ignored Caps Lock, Numeric Pad, and Function flag normalization.

Every effect row must assert both the effect and `suppress` value.

### Step 6: Static and executable gates

Static gates:

```sh
test "$(rg -c '^// MARK: - Keyboard Power Tools Reducer$' Sources/Geraldine/Services/PowerTools.swift)" -eq 1
test "$(rg -c '^// MARK: - Keyboard Power Tools Service$' Sources/Geraldine/Services/PowerTools.swift)" -eq 1
sed -n '/MARK: - Keyboard Power Tools Reducer/,/MARK: - Keyboard Power Tools Service/p' \
  Sources/Geraldine/Services/PowerTools.swift > "$PLAN005_ROOT/reducer-slice.swift"
test -s "$PLAN005_ROOT/reducer-slice.swift"
! rg -n 'CGEvent|UserDefaults|NSWorkspace|NSSound|FinderPowerToolsService|AXTools|Date\(' \
  "$PLAN005_ROOT/reducer-slice.swift"
! rg -n 'blockFirstTap|lastSafetyPress' Sources/Geraldine/Services/PowerTools.swift
test "$(rg -c 'reducer\.reduce' Sources/Geraldine/Services/PowerTools.swift)" -eq 1

dock_slice="$(sed -n '/^private struct DockTarget {/,/^}$/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$dock_slice" | shasum -a 256 | awk '{print $1}')" = \
  'b3b79935ac8ac84c3b741d12d9fba31d5cc8dea770a953f4aa6b7d593057c6ac'
git diff --check
```

After the dispatcher clears the heavy-build gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN005_ROOT/swiftpm" \
  --filter KeyboardPowerToolsReducerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN005_ROOT/swiftpm" \
  --filter FinderTrashShortcutTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN005_ROOT/swiftpm" \
  --filter PowerToolsOperationCoordinatorTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN005_ROOT/swiftpm"
```

Perform a scoped local review. If an accepted fix changes code, rerun all
focused/full tests, static gates, hygiene, and review.

## Closeout scope guard

```sh
set -e
set -o pipefail
BASE="$(<"$PLAN005_ROOT/executor-base")"
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/PowerTools.swift" && $0 != "Tests/GeraldineTests/KeyboardPowerToolsReducerTests.swift" { print }')"
test -z "$unexpected"
test -z "$(git status --short -- plans/README.md Sources/Geraldine/MenuBar/MetricWidgets.swift Sources/Geraldine/Features/PowerTools/PowerToolsView.swift)"
```

Finalize only the registered scratch root:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN005_RECEIPT" --state disposable \
  --reason "Plan 005 verification complete; proof retained in task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN005_RECEIPT" --check-open-files
test ! -e "$PLAN005_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN005_OWNER" --finalize-disposable
test ! -e "$PLAN005_RECEIPT"
```

## Done criteria

- [ ] Plan 004 is integrated, clean, and its focused test passes.
- [ ] Every global keyboard decision comes from the pure reducer.
- [ ] All six preferences and all seven effectful branches are represented,
      including Finder Backspace-to-Trash.
- [ ] Exact timing, autorepeat, modifier, Finder-focus, and cut-session
      semantics are unchanged.
- [ ] The live adapter invokes the reducer once and preserves Plan 004 async
      execution for slow effects.
- [ ] Reducer, Finder Trash, Plan 004, and full tests pass under macOS SDK 26.5.
- [ ] Plan 007 Dock slice, README, `MetricWidgets.swift`, `PowerToolsView.swift`,
      and all other out-of-scope files are unchanged.
- [ ] Static gates, hygiene, scope guard, local review, and CLAYGO closeout pass.

## STOP conditions

STOP if Plan 004 is incomplete/dirty; the post-004 handler lacks or adds a
shortcut branch; current pass/suppress semantics are ambiguous; exact modifier
or timing behavior would have to change; the adapter would run slow effects
synchronously; the Dock slice changes; event-tap lifecycle or permissions would
need modification; SDK 26.5 is unavailable; a gate fails twice after one narrow
in-scope correction; another file changes; or the registered temporary root
cannot be safely closed.

## Maintenance notes

Any future global shortcut must add a reducer input/effect and table row before
the live adapter is changed. Reviewers should treat suppression, autorepeat,
modifier normalization, PID bucketing, monotonic timing, and actor-correct
effect dispatch as security-sensitive behavior.
