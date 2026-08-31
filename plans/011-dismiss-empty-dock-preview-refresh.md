# Plan 011: Dismiss an empty live Dock-preview refresh

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of improvising. When done,
> update only Plan 011's status cell in `plans/README.md`, unless the dispatcher
> says it owns the index.
>
> **Required handoff**: Do not execute in the planning checkout. The dispatcher
> must supply a clean isolated worktree with the committed Dock-preview lane and
> completed Plan 007. Do not mutate a worktree/branch in this plan.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/DockWindowPreviewService.swift Tests/GeraldineTests/DockWindowPreviewTests.swift plans/README.md`
> The two Dock-preview files are expected to be new relative to `7b6fa41`.
> Their pre-edit SHA-256 values must exactly match the prerequisite gate below.
> If a hash or relevant code shape differs, STOP and report the drift.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/007-fail-closed-dock-action-targeting.md` and the exact committed Dock-preview lane
- **Category**: bug, tests
- **Planned at**: commit `7b6fa41` plus the exact hashes below, 2026-08-31

## Why this matters

A cached list can present while a live Accessibility refresh checks current
windows. An empty result now clears the cache but leaves stale UI visible. This
plan dismisses only that process's presentation while preserving generation,
process-isolation, cache, prewarm, and nonactivating-panel behavior.

## Current state

This targets user-owned, uncommitted work at `HEAD` `7b6fa41`; never edit that planning copy.

- `Sources/Geraldine/Services/DockWindowPreviewService.swift` owns refresh and
  presentation; SHA-256 `d78f3cca69e0dbaef415d60830341934d5c282e4710cd67f1c9278f85a796694`.
- `Tests/GeraldineTests/DockWindowPreviewTests.swift` contains pure policy tests;
  SHA-256 `02a138eadacb83af6c84819e8e11b30272f80ca56d6ed09635922c3f5d0211a8`.

Cached windows can be shown before live enumeration
(`DockWindowPreviewService.swift:236-262`):

```swift
let cachedWindows = windowSnapshots[processIdentifier] ?? []
let windows = cachedWindows.isEmpty
    ? DockWindowPreviewAccessibility.visibleWindows(processIdentifier: processIdentifier)
    : cachedWindows
guard !windows.isEmpty else { return false }
present(target: target, windows: windows, refreshWindows: true)
```

After storing/showing the nonactivating presentation, `present` schedules live
verification with `if refreshWindows { refreshWindowSnapshot(for: target) }`
at `DockWindowPreviewService.swift:365`.

The bug is in the accepted empty branch
(`DockWindowPreviewService.swift:408-430`):

```swift
guard let self, self.isRunning, !target.app.isTerminated,
      self.windowSnapshotGenerations[processIdentifier] == generation else { return }
if windows.isEmpty {
    self.windowSnapshots.removeValue(forKey: processIdentifier)
    return
}
self.windowSnapshots[processIdentifier] = windows
guard let presentation = self.presentation,
      presentation.session.processIdentifier == processIdentifier,
      !DockPreviewWindowSnapshotMatching.equivalent(presentation.session.windows, windows) else {
    return
}
self.present(
    target: DockPreviewTarget(app: target.app, itemFrame: presentation.quartzItemFrame),
    windows: windows, refreshWindows: false
)
```

The generation comparison is load-bearing: a superseded refresh must return
before any cache or presentation mutation. The existing narrow dismissal
primitive (`DockWindowPreviewService.swift:453-458`) is the required effect:

```swift
private func dismissPresentation() {
    captureTask?.cancel()
    captureTask = nil
    panel.dismiss()
    presentation = nil
}
```

Use this instead of `dismiss()`, which also changes hover generation and the
pending pointer. The pure-test exemplar is
`DockPreviewWindowSnapshotMatchingTests` (`DockWindowPreviewTests.swift:125-149`):
it passes value inputs directly to `equivalent(...)` without service, AX, panel,
or live Dock state.

## Commands and prerequisite gates

| Purpose | Command | Expected on success |
|---|---|---|
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5" && test -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk` | exit 0 |
| Focused refresh tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN011_ROOT/swiftpm" --filter DockPreviewWindowRefreshPolicyTests` | exit 0; all new tests pass |
| Snapshot tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN011_ROOT/swiftpm" --filter DockPreviewWindowSnapshotMatchingTests` | exit 0; existing tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN011_ROOT/swiftpm"` | exit 0; full suite passes |
| Patch hygiene | `git diff --check` | exit 0, no output |

Run this in the dispatcher-supplied isolated worktree before editing:

```sh
PLAN011_PLANNING_CHECKOUT='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
PLAN011_WORKTREE="$(git rev-parse --show-toplevel)"
test "$(cd "$PLAN011_WORKTREE" && pwd -P)" != "$(cd "$PLAN011_PLANNING_CHECKOUT" && pwd -P)"
test -z "$(git status --short)"
git merge-base --is-ancestor 7b6fa41 HEAD
test "$(git rev-parse HEAD)" != "$(git rev-parse 7b6fa41)"
git ls-files --error-unmatch \
  Sources/Geraldine/Services/DockWindowPreviewService.swift \
  Tests/GeraldineTests/DockWindowPreviewTests.swift \
  Tests/GeraldineTests/DockTargetResolutionTests.swift
test "$(shasum -a 256 Sources/Geraldine/Services/DockWindowPreviewService.swift | awk '{print $1}')" = \
  'd78f3cca69e0dbaef415d60830341934d5c282e4710cd67f1c9278f85a796694'
test "$(shasum -a 256 Tests/GeraldineTests/DockWindowPreviewTests.swift | awk '{print $1}')" = \
  '02a138eadacb83af6c84819e8e11b30272f80ca56d6ed09635922c3f5d0211a8'
rg -n '^\| 007 \|.*\| DONE \|$' plans/README.md
rg -n '^\| 011 \|' plans/README.md
```

Expected: all exit 0, hashes match, Plan 007 is `DONE`, and Plan 011 exists. Otherwise STOP.

Register only the task's SwiftPM scratch root. The dispatcher owns the supplied
worktree lifecycle; do not register, remove, or finalize it here.

```sh
PLAN011_OWNER='<current-thread-or-session-id>'
test "$PLAN011_OWNER" != '<current-thread-or-session-id>'
PLAN011_ROOT="/private/tmp/geraldine-plan-011-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN011_RECEIPT="/tmp/$(basename "$PLAN011_ROOT")-receipt.json"
test ! -e "$PLAN011_ROOT"
test ! -e "$PLAN011_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN011_ROOT" --temp-root /private/tmp \
  --receipt "$PLAN011_RECEIPT" --owner "$PLAN011_OWNER" \
  --purpose "Geraldine Plan 011 focused and full SwiftPM tests" --profile swiftpm
git rev-parse HEAD > "$PLAN011_ROOT/executor-base"
```

Before closeout, run this allowlist guard:

```sh
PLAN011_BASE="$(<"$PLAN011_ROOT/executor-base")"
set -e
set -o pipefail
git cat-file -e "$PLAN011_BASE^{commit}"
test "$(git rev-parse HEAD)" = "$PLAN011_BASE"
unstaged="$(git diff --name-only "$PLAN011_BASE" -- .)"
staged="$(git diff --cached --name-only "$PLAN011_BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/DockWindowPreviewService.swift" && $0 != "Tests/GeraldineTests/DockWindowPreviewTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
git diff "$PLAN011_BASE" -- plans/README.md
```

Expected: `unexpected` is empty; only Plan 011's status cell changes in the
index. STOP rather than cleaning/reverting if another path appears.

## Scope

**In scope** (the only files to modify):

- `Sources/Geraldine/Services/DockWindowPreviewService.swift`
- `Tests/GeraldineTests/DockWindowPreviewTests.swift` (extend, do not replace)
- `plans/README.md` (Plan 011 status cell only)

**Out of scope**:

- Every other Dock-preview file; `PowerTools.swift`, `PowerToolsView.swift`,
  `Permissions.swift`, `build.sh`, and Plan 007's test.
- Cache/prewarm/timing/generation/queue, event, panel, permission, capture,
  identity, selection, preference, or UI changes.
- New time/cache policies, ceilings, quotas, retries, or retention rules.
- Worktree/branch mutation, commits, pushes, installation, launch, signing,
  notarization, or live Dock/event/permission use.
- Repository cleanup, `.jj`, installed apps, user data, and unrelated work.

No extra file: keep the policy beside its service and tests in the existing test file.

## Steps

### Step 1: Add a pure refresh-presentation decision

In `DockWindowPreviewService.swift`, add internal file-scope types, available to
`@testable import`, equivalent to:

```swift
enum DockPreviewWindowRefreshAction: Equatable {
    case keepCurrentPresentation, dismissCurrentPresentation, replaceCurrentPresentation
}

enum DockPreviewWindowRefreshPolicy {
    static func action(refreshedProcessIdentifier: pid_t,
                       presentedProcessIdentifier: pid_t?,
                       windowsAreEmpty: Bool,
                       snapshotsAreEquivalent: Bool) -> DockPreviewWindowRefreshAction {
        guard presentedProcessIdentifier == refreshedProcessIdentifier else {
            return .keepCurrentPresentation
        }
        if windowsAreEmpty { return .dismissCurrentPresentation }
        return snapshotsAreEquivalent ? .keepCurrentPresentation : .replaceCurrentPresentation
    }
}
```

The policy contains no queues, UUIDs, caches, effects, timing, or capture state.
No/different PID keeps; empty same PID dismisses; changed same PID replaces.

**Verify**:

```sh
rg -n 'enum DockPreviewWindowRefresh(Action|Policy)|static func action' Sources/Geraldine/Services/DockWindowPreviewService.swift
policy_slice="$(sed -n '/enum DockPreviewWindowRefreshAction/,/^}/p; /enum DockPreviewWindowRefreshPolicy/,/^}/p' Sources/Geraldine/Services/DockWindowPreviewService.swift)"
test -z "$(printf '%s\n' "$policy_slice" | rg 'DispatchQueue|UUID|windowSnapshots|Accessibility|panel|captureTask|Date|Timer' || true)"
```

### Step 2: Apply it after the unchanged generation guard

In `refreshWindowSnapshot(for:)`, keep UUID creation/storage and the main-queue
generation guard unchanged and ahead of all mutations. After that guard:

- empty results still remove only the refreshed PID's cache;
- nonempty results still update only that PID's cache;
- compute the action using the current presentation PID and snapshot
  equivalence;
- `keep` returns after cache handling;
- `dismiss` calls `self.dismissPresentation()` exactly once; and
- `replace` retains the existing `present(...)` call with the presentation's
  `quartzItemFrame`, live windows, and `refreshWindows: false`.

Do not edit `presentCachedPreview`, `present`, `dismissPresentation`, `dismiss`,
prewarming, timing, queues, or the generation dictionary outside this callback.

**Verify**:

```sh
refresh_slice="$(sed -n '/private func refreshWindowSnapshot(for target:/,/^    }$/p' Sources/Geraldine/Services/DockWindowPreviewService.swift)"
test "$(printf '%s\n' "$refresh_slice" | rg -c 'windowSnapshotGenerations\[processIdentifier\] == generation')" -eq 1
test "$(printf '%s\n' "$refresh_slice" | rg -c 'DockPreviewWindowRefreshPolicy\.action')" -eq 1
test "$(printf '%s\n' "$refresh_slice" | rg -c 'self\.dismissPresentation\(\)')" -eq 1
test -z "$(printf '%s\n' "$refresh_slice" | rg 'self\.dismiss\(\)|self\.panel\.dismiss\(' || true)"
test "$(printf '%s\n' "$refresh_slice" | rg -c 'self\.windowSnapshots\.removeValue')" -eq 1
test "$(printf '%s\n' "$refresh_slice" | rg -c 'self\.windowSnapshots\[processIdentifier\] = windows')" -eq 1
test "$(printf '%s\n' "$refresh_slice" | rg -c 'refreshWindows: false')" -eq 1
```

### Step 3: Add pure decision regression tests

Extend `DockWindowPreviewTests.swift` with
`DockPreviewWindowRefreshPolicyTests`. Directly test fake PIDs and booleans:

- empty + same PID -> dismiss;
- empty + different PID -> keep;
- empty + no presentation -> keep;
- nonempty equivalent + same PID -> keep;
- nonempty changed + same PID -> replace; and
- nonempty changed + different PID -> keep.

Do not instantiate the service, running apps, panels, windows, AX elements, or
event monitors. The Step 2 source gate protects stale-generation rejection;
do not duplicate generation state in the presentation policy.

**Verify**: run the focused refresh command; all six or more tests pass.

### Step 4: Run gates, review, and update the index

Run focused refresh tests, existing snapshot tests, the full suite, and
`git diff --check`, then rerun Steps 1–2 static gates. Review:

```sh
PLAN011_BASE="$(<"$PLAN011_ROOT/executor-base")"
git diff "$PLAN011_BASE" -- \
  Sources/Geraldine/Services/DockWindowPreviewService.swift \
  Tests/GeraldineTests/DockWindowPreviewTests.swift plans/README.md
```

Confirm generation precedes mutations; other PIDs cannot dismiss; empty same
PID uses `dismissPresentation`; nonempty equivalent/changed behavior and
`refreshWindows: false` remain; and no out-of-scope policy moved. If a review
fix changes code, rerun all tests, static gates, hygiene, and review.

After everything passes, change only Plan 011's README status from `TODO` to
`DONE`, run the allowlist guard, and verify:

```sh
rg -n '^\| 011 \|.*\| DONE \|$' plans/README.md
```

### Step 5: Finalize only the SwiftPM scratch root

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN011_RECEIPT" --state disposable \
  --reason "Plan 011 tests and review completed; proof is in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN011_RECEIPT" --check-open-files
test ! -e "$PLAN011_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN011_OWNER" --finalize-disposable
test ! -e "$PLAN011_RECEIPT"
```

Expected: exact scratch absence and owner closeout success. Report the supplied
worktree path/status to the dispatcher; do not register, finalize, remove,
commit, or push it.

## Test plan

The focused policy suite covers empty and nonempty refreshes for the same,
different, and absent presentation PIDs. Existing snapshot-equivalence tests
protect replacement behavior; static ordering gates prove generation rejection
still precedes every cache or presentation mutation; the full suite protects
the complete Dock-preview lane without live Dock or permission state.

## Done criteria

- [ ] Exact hashes, clean isolated-worktree gate, Plan 007 `DONE`, SDK gate, and
      Plan 011 row pass before editing.
- [ ] Six pure cases cover empty same/other/no PID and nonempty
      equivalent/changed decisions.
- [ ] Generation still precedes mutations; empty clears its PID cache and
      dismisses only its presentation; replacement remains nonrecursive.
- [ ] Focused refresh, snapshot, and full SDK 26.5 tests plus static, hygiene,
      scoped-review, and allowlist gates pass.
- [ ] Only the two source/test files and Plan 011 status cell differ; all listed
      prewarm/cache/time/queue/panel/permission/capture/event policies stay fixed.
- [ ] SwiftPM scratch is absent, CLAYGO closes out, and no live Dock, app,
      installation, event tap, permission, capture, commit, push, or publication occurred.

## STOP conditions

STOP and report if the lane is absent/dirty/mismatched; the executor is not in
a clean dispatcher-supplied isolated worktree; Plan 007 is not `DONE`; either
recorded hash differs; the excerpts drift; the generation guard cannot remain
ahead of mutations; another PID could dismiss; a fix needs another file or any
new cache/time/policy behavior; the SDK is not 26.5; a test needs live Dock/AX/
Screen Recording/panel/event/capture/app state; a focused/full gate fails twice
after one reasonable in-scope correction; the index row is absent; the scope
guard finds another path; or CLAYGO cannot finalize/close out. Do not improvise,
clean, revert, create a worktree, or broaden scope.

## Maintenance notes

Generation answers whether a refresh may affect state; exact PID equality
answers whether that accepted refresh owns the current presentation. Future
changes must preserve both boundaries and must keep replacement
`refreshWindows: false`. Cache expiry, retries, refresh intervals, extra
prewarming, and live Dock verification remain explicitly outside this fix.
