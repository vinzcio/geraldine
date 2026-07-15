# Plan 004: Move slow Power Tools effects off the main actor

> **Executor instructions**: Execute only after Plans 001 and 003. Follow each
> gate, preserve UI preparation on the main actor, and stop on any listed
> condition. Update Plan 004's README row when complete unless a reviewer owns
> the index.
>
> **Drift check (run first)**:
> `git diff --stat c8aeca4 -- Sources/Geraldine/Services/PowerTools.swift Sources/Geraldine/Features/PowerTools/PowerToolsView.swift Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift`
> Plans 003 and 001 are expected to have changed Finder selection and Trash
> internals. Reconcile those planned changes; stop for unrelated semantic drift.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-safe-trash-boundary.md`, `plans/003-structured-finder-selection.md`
- **Category**: perf, tech-debt, tests
- **Planned at**: commit `c8aeca4`, 2026-07-15

## Why this matters

`PowerToolsController` is main-actor isolated and synchronously performs one
`shasum` process per file, copy/move loops, disk eject commands, and permanent
Trash deletion. Slow media or large files can freeze the main window, menu-bar
panel, status animation, and event handling. This plan separates main-actor UI
preparation and result publication from background-safe effects, provides one
operation-ownership state machine, and consolidates Empty Trash onto the tested
Plan 001 boundary.

## Current state

- `PowerToolsController` directly writes `lastResult` after synchronous service
  calls (`PowerTools.swift:182-220`).
- `PowerToolsView.perform` yields once, then still calls the synchronous action
  on `@MainActor` (`PowerToolsView.swift:308-323`).
- Finder selection, pasteboard, panels, and `NSWorkspace` reveal/open operations
  are AppKit work and must stay on main.
- Checksums (`PowerTools.swift:716-727`), transfers (`828-851`), disk ejects
  (`887-900`), and Trash deletion (`903-950`) are the slow effect phase.
- Plan 001 provides the canonical Trash classifier/effect seam. Plan 003
  provides a structured `[URL]` Finder selection.

Current UI pattern:

```swift
Task { @MainActor in
    await Task.yield()
    action()
    workingActionID = nil
}
```

Yielding does not move `action()` off the main actor.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prerequisites | `git ls-files --error-unmatch Tests/GeraldineTests/TrashServiceTests.swift Tests/GeraldineTests/FinderSelectionDescriptorTests.swift && git diff --quiet HEAD -- Sources/Geraldine/Services/TrashService.swift Tests/GeraldineTests/TrashServiceTests.swift Sources/Geraldine/Services/PowerTools.swift Tests/GeraldineTests/FinderSelectionDescriptorTests.swift && git diff --cached --quiet HEAD -- Sources/Geraldine/Services/TrashService.swift Tests/GeraldineTests/TrashServiceTests.swift Sources/Geraldine/Services/PowerTools.swift Tests/GeraldineTests/FinderSelectionDescriptorTests.swift && swift test --scratch-path /tmp/geraldine-plan-004-trash --filter TrashServiceTests && swift test --scratch-path /tmp/geraldine-plan-004-finder --filter FinderSelectionDescriptorTests` | exit 0; committed base contains completed Plans 001 and 003 |
| Focused tests | `swift test --scratch-path /tmp/geraldine-plan-004-tests --filter PowerToolsOperationCoordinatorTests` | exit 0 |
| Full tests | `swift test --scratch-path /tmp/geraldine-plan-004-full` | exit 0 |
| Warning build | `swift test --scratch-path /tmp/geraldine-plan-004-warnings > /tmp/geraldine-plan-004-build.log 2>&1` | exit 0; failed tests fail this command |
| Deprecation | `! rg -e 'performFileOperation' -e 'destroyOperation.*deprecated' /tmp/geraldine-plan-004-build.log` | exit 0, no output |
| Hygiene | `git diff --check` | exit 0 |

**User-patch guard (run before and after implementation):**

```sh
test "$(git diff -- Sources/Geraldine/MenuBar/MetricWidgets.swift | shasum -a 256 | cut -d ' ' -f 1)" = da9ee6c4eafd807623c825613e33929a61f9966d00981be10ca9f8739c56c5c3
```

**Plan-base and scope guard:** after prerequisites and before editing, run:

```sh
git rev-parse HEAD > /tmp/geraldine-plan-004-base
unexpected="$({ git diff --name-only HEAD -- Sources Tests; git diff --cached --name-only HEAD -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

If the base file goes missing after edits, STOP. At closeout run:

```sh
test -s /tmp/geraldine-plan-004-base
unexpected="$({ git diff --name-only "$(</tmp/geraldine-plan-004-base)" -- Sources Tests; git diff --cached --name-only "$(</tmp/geraldine-plan-004-base)" -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/Services/PowerTools\.swift$' -e '^Sources/Geraldine/Features/PowerTools/PowerToolsView\.swift$' -e '^Tests/GeraldineTests/PowerToolsOperationCoordinatorTests\.swift$' -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
- `Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift` (create)
- `plans/README.md` (Plan 004 status cell only)

**Out of scope**:

- Event-tap or keyboard decision policy; Plan 005 owns it.
- Moving `NSOpenPanel`, Finder selection AppleScript, pasteboard writes,
  `NSWorkspace` UI calls, or published state off-main.
- A general application-wide process framework or changes to `Shell.swift`.
- Changing confirmation wording or silently parallelizing destructive actions.
- Installed-app launch/reinstall in this implementation plan.
- `MetricWidgets.swift` and jj metadata.

## Git workflow

- Start only from a commit where Plans 001 and 003 are complete and both
  prerequisite test filters pass; do not carry their source edits uncommitted.
- Branch: `codex/004-async-power-tools-effects`, created from that verified
  prerequisite commit.
- Suggested commit: `Move Power Tools effects off main`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Add a single-operation coordinator

Introduce an internal, main-actor-owned coordinator/state inside
`PowerToolsController` (or a narrowly separate internal type in the same file)
with an explicit action identifier, running/idle state, and latest result.
Expose read-only published state to the view. Starting an action while another
is running must be rejected or disabled; results from an older operation must
never overwrite the current action.

Make `lastResult` `private(set)` and provide explicit clear/start/finish methods
instead of allowing the view to mutate controller state directly.

**Verify**:
focused tests compile with a controllable suspended operation.

### Step 2: Split Finder preparation, effect, and publication

For checksum, view-triggered copy/move, and keyboard-triggered cut/paste:

1. On main, read the structured Finder selection from Plan 003 and present any
   destination panel.
2. Pass immutable URLs/options into a concrete internal
   `PowerToolsEffectRunner` that starts an explicitly `Task.detached` operation
   with an `@Sendable` effect closure and awaits its value. Keep this runner
   outside `@MainActor`; an inherited `Task` or an async closure's ability to
   suspend is not evidence of executor separation.
3. Off-main, run checksums or `FileManager` copy/move loops and build a
   `PowerToolResult` plus any pasteboard text.
4. Back on main, write the pasteboard, reveal created files if applicable, and
   publish the result only if the operation still owns the coordinator.

Specifically replace the current Command-V path that synchronously invokes
`pasteCut()` on the main queue. Snapshot the cut-session URLs on main, submit
the transfer through the same coordinator/background effect path, then always
clear `cutItems` after the transfer returns, including warning and failure
results, exactly as current `pasteCut()` does. Publish the result on main.
Command-X may prepare the session on main;
the transfer itself must never execute inside the event-tap/main-queue adapter.

Do not access `NSOpenPanel`, `NSPasteboard`, or Finder AppleScript inside the
background phase. Preserve current skip/failure counting and unique-name rules.

**Verify**:
`rg -n 'Task \{ @MainActor' Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
must not identify a wrapper whose closure performs the slow effect synchronously.

### Step 3: Move system effects off-main and consolidate Empty Trash

Run `pmset`, `diskutil`, Trash enumeration/deletion, and other blocking system
effects through the same background operation path. For Empty Trash, enumerate
the user Trash and pass `ScanItem`s through the tested Plan 001 `TrashService`
boundary; translate its result to existing `PowerToolResult` wording.

Remove `NSWorkspace.performFileOperation(.destroyOperation, ...)` and the
deprecated fallback. Do not weaken failure reporting if `FileManager` cannot
delete an item.

**Verify**:
the deprecation command in “Commands you will need” passes.

### Step 4: Make the view await controller-owned actions

Change `PowerToolsView.perform` to start an async controller action and await
completion without blocking the main actor. Derive working/disabled state from
the controller's operation state so all slow/destructive controls are disabled
while one owns the coordinator. Preserve success auto-clear, warning/failure
display, cancellation messages, and the Empty Trash confirmation.

Quick synchronous UI-only actions such as clearing the pasteboard may remain
main-actor operations, but they must still respect coordinator ownership.

**Verify**:
the focused coordinator tests pass and the view compiles without writable
access to `lastResult`.

### Step 5: Add deterministic concurrency tests

Create `PowerToolsOperationCoordinatorTests.swift`. With injected async
closures/continuations, prove:

- starting an operation publishes its exact action ID and running state;
- a second overlapping operation cannot start;
- completion publishes the owning result and returns to idle;
- a stale completion cannot replace a newer result;
- thrown/cancelled operation paths return to idle with a deterministic result;
- clearing a displayed result does not cancel or orphan active ownership.
- the detached runner starts a gated *synchronous* injected effect that signals
  entry and blocks on a test semaphore; before releasing that semaphore, the
  test successfully runs a separately enqueued `@MainActor` sentinel. This
  would time out if the blocking effect inherited the main actor;
- the injected effect also records `Thread.isMainThread == false`, and compiler
  isolation keeps preparation/publication adapters `@MainActor` while the
  effect closure is `@Sendable` and detached-runner owned.

No test may invoke live Finder, Trash, disk eject, or system sleep.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-004-tests --filter PowerToolsOperationCoordinatorTests`
passes.

### Step 6: Run full verification

**Verify**:

- full tests pass;
- the deprecation-warning gate passes;
- `git diff --check` passes;
- the scope allowlist emits no output, and the recorded `MetricWidgets.swift`
  diff hash is unchanged.

## Test plan

The coordinator cases are in Step 5. Existing Plan 001 tests cover actual
Trash routing; Plan 003 tests cover selection integrity. Do not duplicate those
tests here. A later authorized installed-app pass should manually exercise one
large checksum/copy while confirming the menu bar remains interactive.

## Done criteria

- [ ] Slow file/process effects do not execute on `@MainActor`.
- [ ] AppKit preparation and result publication remain on main.
- [ ] Only one slow/destructive Power Tool runs at a time.
- [ ] Empty Trash reuses `TrashService`; deprecated destroy APIs are gone.
- [ ] Coordinator tests, full tests, warning gate, and `git diff --check` pass.
- [ ] Only in-scope files changed.
- [ ] The pre-existing `MetricWidgets.swift` diff hash is unchanged.
- [ ] Plan 004's README status is updated.

## STOP conditions

Stop and report if:

- Plans 001 or 003 are incomplete;
- an AppKit API must run in the detached/background phase;
- preserving user-visible behavior requires a general `Shell` rewrite;
- safe cancellation would terminate a copy/move midway without a defined
  partial-result contract;
- source drift, repeated verification failure, or out-of-scope edits occur.

## Maintenance notes

Future Power Tools must declare their main-actor preparation, background effect,
and main-actor publication phases. Reviewers should scrutinize ownership races,
Sendable captures, partial file transfers, and whether buttons truly disable
during an active destructive operation.
