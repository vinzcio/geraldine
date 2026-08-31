# Plan 004: Move slow Power Tools effects off the main actor

> **Executor instructions**: Execute only after Plans 001, 003, and 007 are
> present in the supplied base. Follow every fail-closed gate. The dispatcher
> owns `plans/README.md`, the checkout/worktree, commits, and integration; do not
> edit the index or mutate Git state in this lane.
>
> **Current handoff**: this plan was refreshed in the source-only export
> `/private/tmp/geraldine-power-tools-lane-01a05441`. That export has no `.git`
> directory, so its source work may be implemented and reviewed statically but
> no Git, build, or test gate may be claimed there. The integration owner must
> run the complete gate below from a clean isolated Git checkout before handoff.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-safe-trash-boundary.md`,
  `plans/003-structured-finder-selection.md`, and
  `plans/007-fail-closed-dock-action-targeting.md`
- **Compatible with**: completed Plans 011 and 014; their files remain outside
  this plan
- **Category**: performance, correctness, tests
- **Prepared from**: repository commit `cd1d60403c1221a8be104c4c11567b40ad816062`
  (which contains plan index commit `c1f51ea`) plus the exact post-Plan-007
  `PowerTools.swift` fingerprint below, 2026-08-31

## Why this matters

`PowerToolsController` is `@MainActor` and currently performs checksum
processes, file copy/move loops, terminal launch, disk ejection, Finder Trash
moves, and permanent Trash deletion synchronously. `PowerToolsView.perform`
yields once but then invokes that work on the main actor. Large or slow media
can therefore freeze the menu-bar UI and event handling. This plan keeps Finder,
AppKit, and published-state preparation on main, moves only immutable
file/process effects to an explicitly detached runner, and gives every view
action one fail-closed ownership state.

## Verified current state

The refreshed source snapshot has these exact pre-edit identities:

- `Sources/Geraldine/Services/PowerTools.swift`:
  `46ab2ed8f80474fec465f4248f48ec9bee45bf6550aeeef1b958ed544363161b`
- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`:
  `152bb4c9a8a4086c888ab69007843e5340a9fcc6453bc3b604f6072c15f6fd58`
- `Sources/Geraldine/Services/TrashService.swift`:
  `42a6792d606a0c747b11c8cdd1a8d5d7e17f8b2a470e9b476689e7f9749ebb47`
- `Tests/GeraldineTests/TrashServiceTests.swift`:
  `141e11de67e9ec27240f3bfc6a69fc2e51343f999c34ede1740d74fea76968d2`
- `Tests/GeraldineTests/FinderSelectionDescriptorTests.swift`:
  `c275b5905995ac24e627b48fe08b8718ee74f494775ac059046dd3b3e310e9da`

Plan 001 provides `TrashService.clean` and `moveToTrash`; Plan 003 provides
structured Finder selection decoding. Plan 007 is present in the same file and
must survive byte-for-byte. Its current complete `DockTarget` slice has SHA-256
`b3b79935ac8ac84c3b741d12d9fba31d5cc8dea770a953f4aa6b7d593057c6ac`:

```swift
private struct DockTarget {
    let app: NSRunningApplication

    static func target(at point: CGPoint) -> DockTarget? {
        guard let dockProcessIdentifier = DockWindowPreviewAccessibility.dockProcessIdentifier(),
              let target = DockWindowPreviewAccessibility.target(
                  at: point,
                  dockProcessIdentifier: dockProcessIdentifier,
                  candidates: DockWindowPreviewAccessibility.applicationCandidates()
              ) else { return nil }
        return DockTarget(app: target.app)
    }
}
```

The controller currently publishes writable result state after synchronous
calls:

```swift
@Published var lastResult: PowerToolResult?

func copyFinderSHA256() {
    lastResult = finder.copyChecksumSHA256()
}

func emptyTrash() {
    lastResult = system.emptyTrash()
}
```

The view still blocks because `action()` inherits `@MainActor`:

```swift
Task { @MainActor in
    await Task.yield()
    action()
    workingActionID = nil
}
```

## Scope

**Only implementation/test files in scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
- `Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift` (new)

**Plan-maintenance file in scope before implementation only**:

- `plans/004-async-power-tools-effects.md`

**Out of scope**:

- `plans/README.md` (dispatcher-owned)
- `Sources/Geraldine/MenuBar/MetricWidgets.swift`
- Plan 007's Dock target resolver, Dock event ownership, and every
  Dock-preview file
- keyboard pass/suppress policy (Plan 005 owns extraction)
- `Shell.swift`, event-tap lifecycle, permission flows, feature defaults,
  persistence, product strings, layouts, or styling
- build, install, launch, live Finder/Trash/disk actions, commit, push, or PR
  creation in the source-only handoff

## Fail-closed executor preflight

Run from a dispatcher-supplied, clean, isolated checkout. Do not run this block
in the primary OneDrive checkout or in the source-only export.

```sh
set -e
set -o pipefail
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
git merge-base --is-ancestor c1f51ea HEAD

test "$(shasum -a 256 Sources/Geraldine/Services/PowerTools.swift | awk '{print $1}')" = \
  '46ab2ed8f80474fec465f4248f48ec9bee45bf6550aeeef1b958ed544363161b'
test "$(shasum -a 256 Sources/Geraldine/Features/PowerTools/PowerToolsView.swift | awk '{print $1}')" = \
  '152bb4c9a8a4086c888ab69007843e5340a9fcc6453bc3b604f6072c15f6fd58'
test "$(shasum -a 256 Sources/Geraldine/Services/TrashService.swift | awk '{print $1}')" = \
  '42a6792d606a0c747b11c8cdd1a8d5d7e17f8b2a470e9b476689e7f9749ebb47'
test "$(shasum -a 256 Tests/GeraldineTests/TrashServiceTests.swift | awk '{print $1}')" = \
  '141e11de67e9ec27240f3bfc6a69fc2e51343f999c34ede1740d74fea76968d2'
test "$(shasum -a 256 Tests/GeraldineTests/FinderSelectionDescriptorTests.swift | awk '{print $1}')" = \
  'c275b5905995ac24e627b48fe08b8718ee74f494775ac059046dd3b3e310e9da'

dock_slice="$(sed -n '/^private struct DockTarget {/,/^}$/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$dock_slice" | shasum -a 256 | awk '{print $1}')" = \
  'b3b79935ac8ac84c3b741d12d9fba31d5cc8dea770a953f4aa6b7d593057c6ac'
git ls-files --error-unmatch \
  Sources/Geraldine/Services/TrashService.swift \
  Tests/GeraldineTests/TrashServiceTests.swift \
  Tests/GeraldineTests/FinderSelectionDescriptorTests.swift \
  Tests/GeraldineTests/DockTargetResolutionTests.swift
```

Any mismatch means the source or dependency moved after this recon. STOP and
refresh the plan instead of applying offsets or weakening a guard.

## CLAYGO and verification substrate

The dispatcher owns the checkout. The Plan 004 executor owns only this SwiftPM
scratch root. Replace the owner placeholder, then initialize before any build
or test. First inspect free space and concurrent Swift/Xcode work; if the heavy
gate is not safe, defer only builds/tests and continue static review.

```sh
PLAN004_OWNER='<current-thread-or-session-id>'
test "$PLAN004_OWNER" != '<current-thread-or-session-id>'
PLAN004_ROOT="/private/tmp/geraldine-plan-004-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN004_RECEIPT="/tmp/$(basename "$PLAN004_ROOT")-receipt.json"
test ! -e "$PLAN004_ROOT"
test ! -e "$PLAN004_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN004_ROOT" --temp-root /private/tmp --receipt "$PLAN004_RECEIPT" \
  --owner "$PLAN004_OWNER" --purpose "Geraldine Plan 004 SwiftPM verification" \
  --profile swiftpm
git rev-parse HEAD > "$PLAN004_ROOT/executor-base"
df -Pk /private/tmp
pgrep -afil 'swift-build|swift-test|xcodebuild' || true
```

Use the exact selected macOS SDK for every Swift command:

```sh
test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = '26.5'
test -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
```

## Steps

### Step 1: Add a controller-owned single-operation state machine

Make `PowerToolResult`/status equatable and sendable. Add an internal pure
`PowerToolsOperationCoordinator` with an opaque owner token, exact action ID,
latest result, begin/finish/invalidate/clear operations, and strict owner
matching. It must reject overlap and reject stale completion after invalidation
or replacement. `PowerToolsController` mirrors its state through
`@Published private(set) var runningActionID` and
`@Published private(set) var lastResult`; the view clears results through an
explicit method, never writable publication.

Add a non-main `PowerToolsEffectRunner` whose API accepts an `@Sendable`
synchronous effect and executes it with `Task.detached`. An async wrapper alone
is not proof of executor separation.

### Step 2: Separate Finder preparation, effects, and publication

Keep structured Finder selection, front-window folder lookup, `NSOpenPanel`,
pasteboard writes, Finder reveal, and cut-session mutation on `@MainActor`.
Pass only immutable URLs/options/content into the detached runner for:

- text/Markdown file creation;
- SHA-256 process loops;
- terminal-launch process execution;
- view-triggered Copy To / Move To transfer loops;
- Command-V cut transfer, clearing `cutItems` after every completed transfer as
  today; and
- Finder Backspace Trash movement.

Preserve every current message, partial-transfer count, same-directory skip,
unique-name rule, shortcut, and cut-session behavior. Command-X preparation,
Return-open, selection AppleScript, pasteboard, panel, and reveal remain main.
The global keyboard adapter may start an async task for slow effects, but must
not synchronously run them on the event-tap callback or main queue.

### Step 3: Move blocking system effects and reuse TrashService

Run `pmset`, mounted-volume enumeration/`diskutil`, Trash enumeration, and
deletion through the detached runner. Empty Trash must enumerate the current
user Trash, create `ScanItem`s, and call `TrashService.clean` with that exact
Trash root as the classifier authority. Translate the result back to the exact
existing empty/success/partial/all-failed strings. Remove the deprecated
`NSWorkspace.performFileOperation(.destroyOperation, ...)` fallback. Clearing
the pasteboard remains main, but still participates in operation ownership.

### Step 4: Make the view await one controller-owned action

Replace per-view `workingActionID` ownership with controller
`runningActionID`. Map all existing action IDs and all current action/result
semantics to one async controller entry point. `perform` must await completion,
reject overlap without changing active UI, preserve the Empty Trash
confirmation/cancellation wording, and preserve two-second success auto-clear.
Controls for another action must not start work while an owner is active.

Do not change any action title, icon, role, grid/layout, toggle, preference,
result wording, section ownership, or Dock-preview UI.

### Step 5: Add deterministic tests

Create `PowerToolsOperationCoordinatorTests.swift` without live Finder, Trash,
disk, pasteboard, event tap, or app launch. Prove:

- exact running action publication and overlap rejection;
- owning completion publishes the result and returns idle;
- invalidated/stale completion cannot replace a newer result;
- clearing a displayed result preserves active ownership; and
- a gated synchronous effect enters on a non-main thread while a separately
  enqueued `@MainActor` sentinel completes before the gate is released.

The runner test must fail if the blocking closure inherits the main actor.

### Step 6: Static review, tests, and full gate

Before tests, verify Plan 007 is unchanged and the deprecated fallback is gone:

```sh
dock_slice="$(sed -n '/^private struct DockTarget {/,/^}$/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$dock_slice" | shasum -a 256 | awk '{print $1}')" = \
  'b3b79935ac8ac84c3b741d12d9fba31d5cc8dea770a953f4aa6b7d593057c6ac'
! rg -n 'performFileOperation|destroyOperation' Sources/Geraldine/Services/PowerTools.swift
! rg -n '@Published var lastResult' Sources/Geraldine/Services/PowerTools.swift
git diff --check
```

Then, only after the dispatcher clears the heavy-build gate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN004_ROOT/swiftpm" \
  --filter TrashServiceTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN004_ROOT/swiftpm" \
  --filter FinderSelectionDescriptorTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN004_ROOT/swiftpm" \
  --filter FinderTrashShortcutTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN004_ROOT/swiftpm" \
  --filter PowerToolsOperationCoordinatorTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN004_ROOT/swiftpm"
```

Perform a scoped local review after tests. If an accepted fix changes code,
rerun focused/full tests, static gates, hygiene, and review.

## Closeout scope guard

```sh
set -e
set -o pipefail
BASE="$(<"$PLAN004_ROOT/executor-base")"
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/PowerTools.swift" && $0 != "Sources/Geraldine/Features/PowerTools/PowerToolsView.swift" && $0 != "Tests/GeraldineTests/PowerToolsOperationCoordinatorTests.swift" { print }')"
test -z "$unexpected"
test -z "$(git status --short -- plans/README.md Sources/Geraldine/MenuBar/MetricWidgets.swift)"
```

Finalize only the registered SwiftPM scratch root:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN004_RECEIPT" --state disposable \
  --reason "Plan 004 verification complete; proof retained in task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN004_RECEIPT" --check-open-files
test ! -e "$PLAN004_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN004_OWNER" --finalize-disposable
test ! -e "$PLAN004_RECEIPT"
```

## Done criteria

- [ ] Exact prerequisite hashes and post-Plan-007 Dock slice passed preflight.
- [ ] AppKit/Finder preparation and publication remain `@MainActor`.
- [ ] Blocking file/process effects use the explicit detached runner.
- [ ] One owner serializes view actions; stale completion cannot publish.
- [ ] Every current action ID, result/cancellation string, shortcut, cut-session,
      partial-transfer, and UI behavior is preserved.
- [ ] Empty Trash uses `TrashService`; deprecated destroy fallback is absent.
- [ ] Focused and full tests, static gates, hygiene, scope guard, and local
      review pass in the integration checkout.
- [ ] README, `MetricWidgets.swift`, Dock behavior, and all out-of-scope files
      are unchanged.
- [ ] CLAYGO root/receipt are absent and owner closeout succeeds.

## STOP conditions

STOP if the checkout is primary, dirty, or not Git-backed; a fingerprint or
Dock slice differs; Plans 001/003/007 are absent; AppKit would need to run in a
detached closure; preserving current transfer/cut/result semantics would require
an architectural rewrite; another action must be cancelled mid-transfer; SDK
26.5 is unavailable; a gate fails twice after one narrow in-scope correction;
an out-of-scope file changes; or the registered temporary root cannot be safely
closed.

## Maintenance notes

Every future Power Tool should declare three phases: main-actor preparation,
immutable detached effect, and owner-checked main-actor publication. Every new
slow keyboard effect must reuse that split rather than putting file/process work
back on the event tap or main queue.
