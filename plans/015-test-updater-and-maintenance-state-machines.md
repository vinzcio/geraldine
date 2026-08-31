# Plan 015: Test Updater and Maintenance state machines

> **Executor instructions**: Work only in the dispatcher's clean isolated checkout.
> Follow every step and gate. On a STOP, report instead of improvising; do not
> manage a Git worktree. Update only Plan 015's `plans/README.md` status cell when
> complete, unless the reviewer owns the index.
>
> **Drift check**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Features/Updater/UpdaterViewModel.swift Sources/Geraldine/Features/Maintenance/MaintenanceViewModel.swift Tests/GeraldineTests/UpdaterViewModelTests.swift Tests/GeraldineTests/MaintenanceViewModelTests.swift plans/README.md`
> Both view models must still match the excerpts below semantically, and neither
> test file may have unrelated ownership. Any mismatch is a STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug, tests, tech-debt
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Updater and Maintenance launch real `Shell` commands from their state machines,
preventing safe deterministic outcome/order tests. Feature-local runners and
clocks make every transition testable without changing commands, privilege,
messages, UI, or the current duplicate-invocation semantics.

## Current state

`Sources/Geraldine/Features/Updater/UpdaterViewModel.swift:71-113` directly owns
load and per-app upgrade transitions:

```swift
func load() {
    loading = true
    checkState = .unchecked
    upgradeFeedback = [:]
    completed = []
    Task {
        let report = await Task.detached(priority: .userInitiated) { Self.checkForUpdates() }.value
        self.brewPath = report.brewPath
        self.outdated = report.outdated
        self.checkState = report.state
        self.loading = false
        self.checked = true
    }
}

func upgrade(_ app: OutdatedApp) {
    guard let brew = brewPath else { return }
    upgrading.insert(app.token)
    upgradeFeedback[app.token] = nil
    Task {
        let feedback = await Task.detached { () -> BrewCommandFeedback in
            let result = Shell.run(brew, ["upgrade", "--cask", app.token])
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = result.status == 0
            return BrewCommandFeedback(
                ok: ok,
                message: ok ? "Updated \(app.name)." : "Homebrew could not update \(app.name).",
                output: output,
                checkedAt: result.finishedAt
            )
        }.value
        self.upgrading.remove(app.token)
        self.upgradeFeedback[app.token] = feedback
        if feedback.ok {
            self.completed.removeAll { $0.token == app.token }
            self.completed.append(app)
            self.outdated.removeAll { $0.token == app.token }
            if self.outdated.isEmpty {
                self.checkState = .noUpdates(checkedAt: feedback.checkedAt)
            }
        }
    }
}
```

The same file's `checkForUpdates` mapping at lines 121-145 is coupled to discovery,
process execution, wall time, and JSON parsing:

```swift
guard let brew = Shell.which("brew") else {
    return UpdaterCheckReport(brewPath: nil,
                              outdated: [],
                              state: .unavailable(checkedAt: Date()))
}
let result = Shell.run(brew, ["outdated", "--cask", "--json=v2"])
guard let data = result.stdout.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let casks = root["casks"] as? [[String: Any]] else {
    let message = result.status == 0
        ? "Homebrew returned output Geraldine could not read."
        : "Homebrew outdated check failed with exit code \(result.status)."
    return UpdaterCheckReport(
        brewPath: brew,
        outdated: [],
        state: .failed(message: message,
                       output: result.output.trimmingCharacters(in: .whitespacesAndNewlines),
                       checkedAt: result.finishedAt)
    )
}
```

Valid JSON is intentionally authoritative even when Homebrew exits nonzero;
stdout alone is parsed, while human-facing failure output combines both streams.
Preserve that rule, fallback names, app lookup, sorting, and every current message.

`Sources/Geraldine/Features/Maintenance/MaintenanceViewModel.swift:43-64`
contains five fixed task definitions. Their `(id, needsAdmin, command)` values are:

```text
dns            true   dscacheutil -flushcache; killall -HUP mDNSResponder
purge          true   /usr/sbin/purge
periodic       true   periodic daily weekly monthly
spotlight      true   mdutil -E /
launchservices false  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user
```

Lines 69-99 dispatch admin and non-admin work and later reset success:

```swift
func run(_ task: MaintenanceTask) {
    status[task.id] = .running
    Task {
        let run = await Task.detached { () -> MaintenanceRun in
            if task.needsAdmin {
                let result = Shell.runAdmin(task.command)
                return MaintenanceRun(ok: result.ok, command: task.command,
                                      output: result.output, finishedAt: result.finishedAt)
            }
            let result = Shell.run("/bin/sh", ["-c", task.command])
            return MaintenanceRun(ok: result.status == 0, command: task.command,
                                  output: result.output, finishedAt: result.finishedAt)
        }.value
        self.lastRuns[task.id] = run
        self.status[task.id] = run.ok ? .done : .failed
        if run.ok { self.scheduleIdleRevert(task.id) }
    }
}

private func scheduleIdleRevert(_ id: String) {
    Task {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if self.status[id] == .done { self.status[id] = .idle }
    }
}
```

`Shell.swift` is the production boundary; `runAdmin` escapes backslashes/quotes
and invokes osascript. It is out of scope. Tests use XCTest, `@testable import
Geraldine`, and `@MainActor` for observable state; match that convention.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Updater tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter UpdaterViewModelTests` | all updater tests pass |
| Maintenance tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter MaintenanceViewModelTests` | all maintenance tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build"` | exit 0; all tests pass |
| Patch hygiene | `git diff --check` | exit 0; no output |

Do not run `./build.sh`, install, package, sign, launch Geraldine, touch
`/Applications`, commit, push, or open a PR.

## Isolated-checkout and CLAYGO setup

The dispatcher supplies the checkout. Before editing, require a non-primary,
clean root and register only a SwiftPM scratch directory:

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1)"
BASE_COMMIT="$(git rev-parse HEAD)"
: "${EXECUTOR_OWNER_ID:?Use the actual host-provided thread/session ID}"
RESOURCE_TOKEN="$(printf '%s' "$EXECUTOR_OWNER_ID" | shasum -a 256 | cut -c1-12)"
SWIFTPM_ROOT="/private/tmp/geraldine-plan-015-swiftpm-${RESOURCE_TOKEN}"
SWIFTPM_RECEIPT="/tmp/geraldine-plan-015-swiftpm-${RESOURCE_TOKEN}-receipt.json"
test ! -e "$SWIFTPM_ROOT"
test ! -e "$SWIFTPM_RECEIPT"
df -h /private/tmp
for process_name in swift swift-build swift-test xcodebuild; do
  pgrep -x "$process_name" || true
done
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$SWIFTPM_ROOT" --temp-root /private/tmp \
  --receipt "$SWIFTPM_RECEIPT" --owner "$EXECUTOR_OWNER_ID" \
  --purpose "Plan 015 SwiftPM verification" --profile swiftpm
```

If capacity is unsafe or another heavy test is active, pause tests; never interrupt it.

Use this scope guard at every review waypoint and closeout:

```sh
set -e
set -o pipefail
git cat-file -e "$BASE_COMMIT^{commit}"
test "$(git rev-parse HEAD)" = "$BASE_COMMIT"
unstaged="$(git diff --name-only "$BASE_COMMIT" -- .)"
staged="$(git diff --cached --name-only "$BASE_COMMIT" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Features/Updater/UpdaterViewModel.swift" && $0 != "Sources/Geraldine/Features/Maintenance/MaintenanceViewModel.swift" && $0 != "Tests/GeraldineTests/UpdaterViewModelTests.swift" && $0 != "Tests/GeraldineTests/MaintenanceViewModelTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

Never register/finalize the dispatcher-owned checkout or disturb the primary
checkout's user-owned Dock-preview work.

## Scope

**In scope** (the only files that may change):

- `Sources/Geraldine/Features/Updater/UpdaterViewModel.swift`
- `Sources/Geraldine/Features/Maintenance/MaintenanceViewModel.swift`
- `Tests/GeraldineTests/UpdaterViewModelTests.swift` (create)
- `Tests/GeraldineTests/MaintenanceViewModelTests.swift` (create)
- `plans/README.md` (Plan 015 status cell only)

**Out of scope**:

- `Shell.swift`, especially `Shell.runAdmin`, quoting, osascript, and results;
- either view, task copy/icons, fixed commands/admin flags, updater messages,
  Homebrew arguments, app resolution, or sorting;
- timeouts, cancellation or retry policies, task handles, process termination,
  new limits/defaults, a generic process architecture, or shared Shell refactors.

## Git workflow

Stay in the dispatcher checkout. Do not create/finalize worktrees, switch branches,
stage, stash, reset, clean, commit, merge, push, or open a PR. Leave a scoped diff.

## Steps

### Step 1: Add feature-local runners and only the clocks each model needs

Add one internal runner per view-model file. Updater exposes only async brew lookup
and non-admin run; Maintenance exposes only async non-admin and admin run. Live
adapters delegate to the exact current `Shell` calls off-main. Never share them.

Updater's clock exposes only no-brew `now()`; Maintenance's exposes only the
successful-state wait, retaining 2,500,000,000 nanoseconds and best-effort sleep.
Production-default initializers keep both views unchanged. Add no policy API.

**Verify**: `git diff --check` and the scope guard both exit 0; `git diff -- Sources/Geraldine/Services/Shell.swift` emits nothing.

### Step 2: Separate Homebrew result mapping without changing Updater policy

Extract pure stdout/result parsing into internal value records with no Shell,
clock, task, filesystem, or published state. Perform existing app enrichment and
sorting afterward. Preserve nonzero-valid JSON authority, exact errors/output,
versions, and fallback names.

Route `load()` and `upgrade(_:)` through injected dependencies. Preserve the
current public methods exactly: do not add an in-flight guard, cancellation,
generation ID, coalescing, or supersession policy. Two direct overlapping
`load()` calls still launch two checks and publish in completion order. Two
direct upgrades for the same token still launch two commands; their completion
updates retain today's completion-order/last-writer behavior. Different tokens
remain concurrent. Preserve every immediate reset, success/failure feedback,
completed/outdated update, date, and `.noUpdates` transition.

The ordinary UI already disables its `StatefulActionButton` while `loading` or
the token is in `upgrading`; that view-owned gate remains unchanged and is not
moved into the model by this plan. Characterizing direct duplicate calls is a
regression record, not approval of that policy. Any future suppression or
latest-wins behavior requires its own explicit authorization.

**Verify**:

```sh
rg -n 'Shell\.(which|run)' Sources/Geraldine/Features/Updater/UpdaterViewModel.swift
rg -n 'Homebrew returned output Geraldine could not read|Homebrew outdated check failed with exit code|Updated |Homebrew could not update' Sources/Geraldine/Features/Updater/UpdaterViewModel.swift
```

Shell references appear only in the production adapter; all messages remain.

### Step 3: Route Maintenance actions without changing their policy

Route execution through the Maintenance runner. Do not add a `.running` guard:
two direct calls for the same task ID still invoke the command twice, and their
completions retain today's completion-order/last-writer behavior. Different IDs
remain concurrent and may finish in either order; each completion updates only
its own `lastRuns` and status. Successful work waits on the injected clock before
returning `.done` to `.idle`; failure stays `.failed` and never waits. Preserve
raw output, exact finished time, and command in each run.

The ordinary Maintenance view already disables its `StatefulActionButton` while
status is `.running`; keep that UI-owned gate unchanged. Do not treat it as a
model-level concurrency guarantee.

Do not parse/requote commands, change admin routing, or coalesce different tasks.

**Verify**: `rg -n 'dscacheutil -flushcache; killall -HUP mDNSResponder|/usr/sbin/purge|periodic daily weekly monthly|mdutil -E /|lsregister -kill -r -domain local -domain system -domain user' Sources/Geraldine/Features/Maintenance/MaintenanceViewModel.swift` shows all five unchanged commands.

### Step 4: Add deterministic focused tests

Create both `@MainActor` XCTest suites. Actor-backed fake-runner continuations let
tests await and order commands; use fixed updater time and a manually resumed
maintenance clock. Never use real commands, sleeps, timeouts, cancellation,
polling, semaphores, or admin prompts.

Updater tests cover unavailable brew; malformed status-zero/nonzero output; valid
and empty JSON, including nonzero-valid JSON; exact arguments; upgrade success/
failure; two direct duplicate calls issuing two commands; completion-order
characterization; reordered distinct upgrades; and exact immediate/final
collections, phases, feedback, output, and times.

Maintenance tests snapshot all task tuples; prove exact admin/non-admin dispatch;
cover success/failure, two direct same-ID calls issuing two commands, reordered
same-ID and distinct-ID completion, exact run publication, clock-controlled
`.done` to `.idle`, and no failure reset.

**Verify**: run both focused commands from the table; each exits 0 with all tests passing.

### Step 5: Run full verification, review, and finalize scratch

Run the full suite, `git diff --check`, and scope guard. Review every hunk for
command/message drift, main-actor blocking, unstable fake synchronization, stale
cross-ID publication, and any forbidden process/time policy. If review accepts a
change, rerun both focused suites and full tests. Update only Plan 015's README cell.

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark --receipt "$SWIFTPM_RECEIPT" --state disposable --reason "Plan 015 tests complete; proof retained in transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize --receipt "$SWIFTPM_RECEIPT" --check-open-files
test ! -e "$SWIFTPM_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout --owner "$EXECUTOR_OWNER_ID" --finalize-disposable
test ! -e "$SWIFTPM_RECEIPT"
```

All commands exit 0. Report test results, scope guard, finalized scratch path, and
that no install, launch, commit, or push occurred.

## Test plan

The two focused suites prove command mapping, failure semantics, current direct
duplicate behavior, independent concurrent completion, timestamps, and
deterministic delayed reset. The full suite protects all existing UI-facing
contracts and Shell consumers.

## Done criteria

- [ ] Neither production state machine calls `Shell` outside its narrow live adapter.
- [ ] Homebrew unavailable, malformed, failed, empty-valid, and updates-valid mappings pass, including valid JSON with nonzero exit.
- [ ] Direct duplicate same-action calls still issue two commands and retain
      today's completion-order behavior; distinct actions complete independently.
- [ ] Published phases, sets, arrays, feedback/runs, messages, output, and timestamps match current semantics.
- [ ] All five Maintenance commands/admin flags and updater command arguments are byte-for-byte unchanged.
- [ ] Successful Maintenance state resets only after the controlled clock; failure does not reset.
- [ ] Both focused suites and the full suite pass with macOS SDK 26.5.
- [ ] `git diff --check` and scope guard pass; only five scoped paths changed.
- [ ] SwiftPM scratch is finalized and owner closeout succeeds.
- [ ] No timeout/cancellation/retry/limit/default/process policy, Shell/admin/UI change, worktree operation, install, launch, commit, or push occurred.

## STOP conditions

Stop if either excerpt drifted; a test file has unrelated ownership; the checkout
is primary or dirty; the actual owner ID or SDK 26.5 is unavailable; preserving
behavior requires editing `Shell`, a view, commands, quoting, admin behavior,
messages, app resolution, or another file; deterministic tests appear to require
a timeout, cancellation, sleep, real command/admin prompt, generic runner, new
limit/default, or process-lifecycle policy; direct duplicate invocation behavior
would change; a verification fails twice after one reasonable in-scope
correction; the scope guard fails; or CLAYGO cannot safely finalize scratch.

## Maintenance notes

Keep runners feature-local; they are state-machine seams, not a new `Shell`.
Future changes to duplicate behavior must be separately authorized and retain
per-ID publication.
Timeouts, cancellation, retries, commands, privilege, the 2.5-second display, or
defaults require separate authorization and tests; this plan changes none.
