# Plan 012: Cancel superseded Smart Care scans

> **Executor instructions**: Follow this plan step by step in the clean isolated
> worktree supplied by the dispatcher. Run every verification command and
> confirm its expected result before continuing. If a STOP condition occurs,
> stop and report it instead of improvising. Update only Plan 012's status cell
> in `plans/README.md` after all implementation gates pass. Do not create or
> finalize a worktree, commit, push, install, or launch Geraldine.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Features/SmartCare/SmartCareView.swift Tests/GeraldineTests/SmartCareScanCancellationTests.swift plans/README.md`
> A README-only change that adds the Plan 012 row is expected. Any source/test
> change, or a semantic mismatch with the excerpts below, is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf, bug, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31
- **Downstream**: Plan 017 depends on this task-ownership boundary

## Why this matters

Every Smart Care rescan launches another unretained task. The `scanID` prevents
an old result from publishing, but it does not stop the old recursive cache,
log, and Trash traversals. Rapid rescans can therefore perform duplicate disk
work in parallel, and removing the view cannot cancel work whose handle the
view model never retained. This plan gives Smart Care one owned worker, sends
cancellation to the actual detached task, serializes a replacement behind the
worker it supersedes, and publishes only the latest completed scan.

## Current state

- `Sources/Geraldine/Features/SmartCare/SmartCareView.swift` contains the
  `Finding` model, `SmartCareViewModel`, scoring, queue/reveal UI, and rescan
  action. Keep this one-file ownership; do not extract a scan framework.
- `Sources/Geraldine/Services/DiskScan.swift:77-110` already checks
  `Task.isCancelled` inside recursive directory enumeration. It can cooperate
  only when the task performing that enumeration is the task being cancelled.
- `SmartCareView.swift:227` declares
  `@StateObject private var vm = SmartCareViewModel()`, and
  `Navigation/RootView.swift:249-268` replaces module content by module identity.
  The existing `onDisappear` block at lines 282-285 is therefore a valid owner
  cleanup boundary; no global shutdown registry or lifecycle notification is
  needed.
- Create `Tests/GeraldineTests/SmartCareScanCancellationTests.swift` with
  XCTest, `@testable import Geraldine`, and `@MainActor`, matching the repository's
  view-model tests. Tests must inject all scan work.

The view model records only logical identity (`SmartCareView.swift:65,78-89`):

```swift
private var scanID = UUID()

func scan() {
    let id = UUID()
    scanID = id
    phase = .scanning
    scanDate = nil
    // capture live disk/memory values
    Task {
        let extras = await Self.gather()
        guard self.scanID == id else { return }
        // build findings, score, date, and results phase
    }
}
```

The background worker is a detached child whose handle is immediately lost
(`SmartCareView.swift:207-219`):

```swift
private struct Extras { var junk: UInt64; var startupItems: Int }

private static func gather() async -> Extras {
    await Task.detached(priority: .userInitiated) { () -> Extras in
        let junk = DiskScan.size(of: home.appendingPathComponent("Library/Caches"))
            + DiskScan.size(of: home.appendingPathComponent("Library/Logs"))
            + DiskScan.size(of: home.appendingPathComponent(".Trash"))
        return Extras(junk: junk, startupItems: agents)
    }.value
}
```

`SmartCareView.swift:282-285` currently cancels only `revealTask` on disappear;
`rescan()` at lines 367-375 resets queue/reveal presentation and calls
`vm.scan()`. Preserve those resets while adding scan ownership cleanup.

Required invariants:

1. `scan()` owns exactly one stored `Task<Void, Never>?` representing the
   detached traversal/publication worker, not merely a logical UUID.
2. A replacement cancels the prior handle, waits for that prior task to finish,
   and only then enters the injected scanner. Even three rapid requests must
   never execute two scanner closures concurrently.
3. Cancellation is observed in the direct worker task, so the existing
   `DiskScan.size` check receives it. Do not hide another unowned
   `Task.detached` inside the production scanner.
4. A cancelled or stale task publishes no findings, score, date, or phase.
   The latest successful task clears its owned handle and publishes `.results`.
5. Owner cleanup cancels the worker and moves `.scanning` to `.idle`; it retains
   the cancelled handle only so a same-model restart can await its drain before
   replacement. It does not allow a cancelled result to land.
6. Finding text, thresholds, penalty scoring, sorting, queue/reset behavior,
   module routing, reveal animation, and normal result presentation are
   unchanged.

## Commands and isolated-worktree guard

Recon verified the explicit macOS 26.5 SDK below. Replace the owner placeholder
with the executor's actual thread/session ID. Register only the SwiftPM scratch
root; the dispatcher owns the worktree lifecycle.

```zsh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
PLAN_KEY="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-012-$PLAN_KEY"
PLAN_RECEIPT="/tmp/geraldine-plan-012-$PLAN_KEY-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" \
  --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" \
  --owner "$PLAN_OWNER" \
  --purpose 'Plan 012 focused and full SwiftPM tests' \
  --profile swiftpm

git rev-parse HEAD > "$PLAN_TMP/base-commit"
SDKROOT_26_5='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk'
test -d "$SDKROOT_26_5"
```

Keep these variables in the same zsh session.

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT="$SDKROOT_26_5" CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter SmartCareScanCancellationTests` | exit 0; all focused tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT="$SDKROOT_26_5" CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build"` | exit 0; full suite passes |
| Hygiene | `git diff --check "$(<"$PLAN_TMP/base-commit")"` | exit 0, no output |

At closeout, the following allowlist must emit no paths:

```zsh
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
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Features/SmartCare/SmartCareView.swift" && $0 != "Tests/GeraldineTests/SmartCareScanCancellationTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Features/SmartCare/SmartCareView.swift`
- `Tests/GeraldineTests/SmartCareScanCancellationTests.swift` (create)
- `plans/README.md` (Plan 012 status cell only, after verification)

**Out of scope**:

- `DiskScan.swift`, other feature scanners/view models, `AppState`, `RootView`,
  module routing, and app termination handling.
- Finding content, confidence/severity thresholds, penalty math, sorting,
  queued actions, reveal timing/animation, scan-on-appear, or rescan resets.
- Retention, caches, persistence, timeouts, retries, polling/cadence changes,
  traversal limits, scan limits, or a general scanning/task framework.
- The dirty primary checkout and its Dock-preview work, `build.sh`, `.jj`,
  installation, signing, launch, commit, push, or any file not listed above.

## Steps

### Step 1: Add the narrow scanner seam and direct worker ownership

In `SmartCareView.swift`, replace private `Extras` with a small internal
`SmartCareScanExtras: Sendable, Equatable` containing only `junk: UInt64` and
`startupItems: Int`. Add an internal closure alias such as:

```swift
typealias SmartCareScanner = @Sendable () async -> SmartCareScanExtras
```

Give `SmartCareViewModel` an initializer with a default production scanner and
store that closure. Add exactly one owned
`private var scanTask: Task<Void, Never>?`. Make the production gather function
`nonisolated` and async, but remove its inner `Task.detached`; it performs the
same three `DiskScan.size` calls and launch-agent count when invoked by the
worker created in `scan()`.

Move the existing finding construction/publication into one private main-actor
method that accepts the captured disk/memory snapshot, extras, and scan ID.
Move it mechanically: no strings, thresholds, modules, penalties, ordering, or
date behavior may change.

**Verify**: run the focused command. It may report zero matching tests at this
intermediate step, but package compilation must exit 0.

### Step 2: Cancel, serialize, and publish only the latest scan

At the start of `scan()`, capture the previous `scanTask`, cancel it, create a
new scan ID, set `.scanning`, clear `scanDate`, and capture the same four live
monitor values as today. Copy the injected scanner to a local value so the
worker does not retain the view model.

Create one `Task.detached(priority: .userInitiated)` and store its handle in
`scanTask`. Its ordered body must:

1. await the previous task's `value`, if one exists;
2. return if the new task was cancelled while waiting;
3. await the injected scanner directly (with no nested detached task);
4. return if cancellation arrived during scanning;
5. call the private main-actor publisher through a weak view-model reference.

The publisher must first guard the scan ID. Only that latest publisher may set
`findings`, `score`, `scanDate`, `.results`, and `scanTask = nil`. Waiting for
the cancelled predecessor is required: cancellation is cooperative, so merely
cancelling and immediately starting another traversal does not satisfy the
no-parallel-work invariant.

Add `cancelScan()` for the owner boundary. While scanning, it invalidates
`scanID`, cancels `scanTask`, and changes the phase to `.idle`. Keep the
cancelled handle as the next scan's predecessor until it drains; clearing it
immediately would let a quick same-model restart overlap the old traversal.
The method is a no-op after completed results and must not rewrite findings or
score.

**Verify**:

```zsh
test "$(rg -c 'private var scanTask: Task<Void, Never>\?' Sources/Geraldine/Features/SmartCare/SmartCareView.swift)" -eq 1
test "$(rg -c 'Task\.detached' Sources/Geraldine/Features/SmartCare/SmartCareView.swift)" -eq 1
/usr/bin/env SDKROOT="$SDKROOT_26_5" \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" \
  /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" \
  --filter SmartCareScanCancellationTests
```

Expected: structural checks and compilation exit 0.

### Step 3: Prove cancellation and serialization without filesystem work

Create `SmartCareScanCancellationTests.swift`. Build a test-only controlled
scanner actor/helper around checked continuations and a task cancellation
handler. It must record invocation order, cancellation, current active calls,
and maximum concurrent calls, and resume each continuation exactly once.
XCTest fulfillment timeouts may guard a hung test; do not use `Task.sleep`,
run-loop delays, semaphores, or the real home directory.

Cover at least:

- one normal injected scan publishes `.results`, a non-nil `scanDate`, and the
  existing junk/startup finding text for its supplied extras;
- starting scan B while A is suspended cancels A's actual scanner task; B does
  not enter its scanner until A's cancellation continuation finishes;
- A returning a distinctive stale result after cancellation cannot publish;
  B's distinctive result is the only one present and B clears the task/phase;
- three rapid scans invoke the first and latest scanners but never let the
  middle cancelled-while-waiting task enter the scanner; maximum concurrency is
  exactly one;
- `cancelScan()` while scanning delivers cancellation, leaves `.idle`, keeps
  `scanDate == nil`, and cannot later transition to `.results` when the
  controlled scanner unwinds;
- a scan started immediately after `cancelScan()` waits for that cancelled
  predecessor and still keeps maximum concurrency at one;
- cancelling an already completed model is a no-op for completed results.

Assert `.scanning` while a replacement waits so the UI never falls back to
idle or remains permanently stuck. Every model in a test must use the injected
scanner; a test that reaches production `gather()` is invalid.

**Verify**: run the focused command; every named case passes with no real scan
or sleep.

### Step 4: Connect cleanup to the proven view owner and run full gates

Extend the existing `SmartCareView.onDisappear` block to call
`vm.cancelScan()` before cancelling `revealTask`. This is the only lifecycle
hook allowed: the view creates the private state object and `DetailHost`
removes that module view by identity. Do not add `deinit`, AppDelegate shutdown,
notifications, or hidden-window observers.

Run the focused, full, and hygiene commands first. After they pass, change Plan
012's README status from `TODO` to `DONE`; do not alter another cell or
dependency note. Then run the final scope allowlist plus these lifecycle/index
checks:

```zsh
rg -n -U '\.onDisappear \{\n\s*vm\.cancelScan\(\)' Sources/Geraldine/Features/SmartCare/SmartCareView.swift
rg -n '^\| 012 \| Cancel superseded Smart Care scans \| P2 \| M \| — \| DONE \|$' plans/README.md
```

Expected: the lifecycle search finds one block; focused/full tests, hygiene,
README check, and the scope allowlist all pass.

After proof is preserved in the task transcript, finalize only the registered
SwiftPM root and close out its owner:

```zsh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" \
  --state disposable \
  --reason 'Plan 012 tests passed and proof is preserved in the task transcript'
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" \
  --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" \
  --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

## Test plan

The focused suite uses a controlled injected scanner to prove direct
cancellation, predecessor draining, maximum concurrency of one, stale-result
rejection, latest-only publication, owner cancellation, and immediate restart
after cancellation. No test traverses the real home directory or waits on
production timing. The full suite protects existing finding, scoring, queue,
reveal, and routing behavior.

## Done criteria

- [ ] One stored detached worker owns scan traversal and receives cancellation.
- [ ] A replacement waits for its cancelled predecessor; controlled tests prove
      maximum scanner concurrency is one.
- [ ] Cancelled/stale results never publish; the latest result alone sets
      findings, score, date, `.results`, and clears its handle.
- [ ] Owner cancellation returns `.scanning` to `.idle`, retains the handle only
      through draining/replacement, and is wired to the proven `onDisappear`.
- [ ] Finding/scoring, queue, reveal, scan-on-appear, routing, and rescan behavior
      are otherwise unchanged.
- [ ] Focused and full tests pass with the explicit macOS 26.5 SDK; hygiene and
      the three-file allowlist pass.
- [ ] Only Plan 012's README status cell changes, and CLAYGO scratch ownership
      is fully finalized with exact absence verified.
- [ ] No real home traversal, sleeps, install, launch, commit, or push occurred.

## STOP conditions

Stop and report if:

- the Smart Care excerpts or lifecycle ownership no longer match current code;
- cancellation would require changing `DiskScan`, another view model,
  `RootView`, `AppState`, or app termination ownership;
- the scanner closure cannot be made directly cancellable without another
  unowned detached traversal;
- serialization would require a timeout, retry, scan cap, persistence, cache,
  cadence, or generic coordinator/framework;
- deterministic tests would touch the real home directory, depend on sleeps,
  or expose UI lifecycle internals;
- finding/scoring/queue/reveal behavior must change to implement cancellation;
- any verification fails twice after one reasonable scoped correction;
- CLAYGO cannot safely finalize the registered scratch root.

## Maintenance notes

Future Smart Care scan inputs must enter the injected scanner executed by the
single owned worker; do not reintroduce nested detached tasks. Reviewers should
scrutinize cancellation checks before and after the scanner, predecessor
awaiting, weak view-model capture, scan-ID publication, and exactly-once test
continuation resumption. Plan 017 is intentionally downstream of this ownership
work and must not be folded into Plan 012.
