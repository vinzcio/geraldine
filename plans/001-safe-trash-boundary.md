# Plan 001: Make Trash classification canonical and testable

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of improvising. When done,
> update Plan 001's status in `plans/README.md` unless your reviewer says it owns
> the index.
>
> **Drift check (run first)**:
> `git diff --stat c8aeca4 -- Sources/Geraldine/Services/TrashService.swift Tests/GeraldineTests/TrashServiceTests.swift`
> If `TrashService.swift` changed, compare the excerpts below with current code.
> Any semantic mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug, tests
- **Planned at**: commit `c8aeca4`, 2026-07-15

## Why this matters

`TrashService` is the common mutation boundary for Cleanup, Privacy, Large
Files, Login Items, and Uninstaller. It permanently deletes a selected item
when the item's path merely contains a component named `.Trash`; an ordinary
project or cache directory with that name is therefore treated as the real
macOS Trash. This plan replaces string matching with strict canonical ancestry
under an injected, testable set of Trash roots and characterizes the mutation
and result-accounting behavior before broader file-operation refactors.

## Current state

- `Sources/Geraldine/Services/TrashService.swift` owns reversible Trash moves,
  permanent deletion, failure reporting, and the faulty classification.
- `Sources/Geraldine/Models/ScanItem.swift:45-55` provides shared selection
  helpers. Do not change that model in this plan.
- Existing filesystem tests create UUID-scoped temporary roots and clean them
  with `defer`; match `Tests/GeraldineTests/LaunchItemIdentityTests.swift:5-48`.

Current behavior (`TrashService.swift:21-48`):

```swift
/// Moves items to the Trash (reversible). Items that already live in the
/// Trash are removed permanently — that's what "empty trash" means.
static func clean(_ items: [ScanItem]) -> Result {
    // ...
    if isInTrash(item.url) {
        try fm.removeItem(at: item.url)
    } else {
        try fm.trashItem(at: item.url, resultingItemURL: nil)
    }
}

static func isInTrash(_ url: URL) -> Bool {
    url.path.contains("/.Trash/") || url.path.hasSuffix("/.Trash")
}
```

The product invariant is: only a strict descendant of a supported real Trash
root may be permanently deleted. The Trash root itself must never be an
eligible cleanup item and must trigger neither filesystem operation. It is
reported as a refusal/failure so the caller cannot mistake it for success.
Every path that is neither a root nor a strict descendant takes the reversible
`trashItem` path.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `swift test --scratch-path /tmp/geraldine-plan-001-tests --filter TrashServiceTests` | exit 0; all new tests pass |
| Full tests | `swift test --scratch-path /tmp/geraldine-plan-001-full` | exit 0; existing and new tests pass |
| Patch hygiene | `git diff --check` | exit 0, no output |

**User-patch guard (run before and after implementation):**

```sh
test "$(git diff -- Sources/Geraldine/MenuBar/MetricWidgets.swift | shasum -a 256 | cut -d ' ' -f 1)" = da9ee6c4eafd807623c825613e33929a61f9966d00981be10ca9f8739c56c5c3
```

**Plan-base and scope guard:** before editing, run this in zsh. It records the
only valid comparison base and refuses unrelated tracked or untracked source
work. If the temp file is later missing, STOP rather than recreating it after
edits.

```sh
git rev-parse HEAD > /tmp/geraldine-plan-001-base
unexpected="$({ git diff --name-only HEAD -- Sources Tests; git diff --cached --name-only HEAD -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

At closeout, this gate includes committed, staged, unstaged, and untracked
paths created since that captured base:

```sh
test -s /tmp/geraldine-plan-001-base
unexpected="$({ git diff --name-only "$(</tmp/geraldine-plan-001-base)" -- Sources Tests; git diff --cached --name-only "$(</tmp/geraldine-plan-001-base)" -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/Services/TrashService\.swift$' -e '^Tests/GeraldineTests/TrashServiceTests\.swift$' -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/TrashService.swift`
- `Tests/GeraldineTests/TrashServiceTests.swift` (create)
- `plans/README.md` (Plan 001 status cell only)

**Out of scope**:

- Cleanup, Privacy, Large Files, Login Items, and Uninstaller UI/view models.
- `Sources/Geraldine/Services/PowerTools.swift`; its duplicate Empty Trash path
  is consolidated in Plan 004 after this boundary is tested.
- External-volume Trash discovery unless the current macOS API contract can be
  verified locally without guessing.
- The existing `MetricWidgets.swift` patch, build/sign/install scripts, and jj
  metadata.

## Git workflow

- Branch: `codex/001-safe-trash-boundary`.
- Use an imperative commit message matching the repository, for example
  `Harden Trash file operations`.
- Do not push or open a PR unless explicitly instructed.

## Steps

### Step 1: Introduce explicit file-operation and Trash-root dependencies

In `TrashService.swift`, add a narrow internal protocol or closure-backed
adapter for exactly the effects used here: `removeItem(at:)` and
`trashItem(at:)`. Provide a production adapter backed by `FileManager` and keep
the existing call sites source-compatible through default arguments or a
production facade.

Make Trash roots injectable into the classification/clean path. The production
resolver must first call
`FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
appropriateFor: nil, create: false)`. If that call throws, use
`FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash",
isDirectory: true)` only when `fileExists(atPath:isDirectory:)` confirms an
existing directory. If neither produces a directory, return no permanent-delete
roots and fail closed to the reversible `trashItem` path. Never create a Trash
directory and never invent external-volume roots. Keep this resolver separately
injectable so tests can cover success, fallback, and no-root behavior.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-001-tests --filter TrashServiceTests`
must compile; zero tests is acceptable only at this intermediate step.

### Step 2: Replace textual matching with strict canonical ancestry

Create one internal classifier with three outcomes: `root` (refuse),
`descendant` (permanent delete), and `outside` (reversible Trash). It checks
both standardized lexical ancestry and symlink-resolved ancestry for the
candidate and each root, compares path components rather than string prefixes,
and returns `descendant` only when both views satisfy:

1. the candidate has every root component as an exact prefix; and
2. the candidate has at least one additional component.

This must reject the Trash root itself, sibling prefixes such as `.Trash-old`,
ordinary nested directories named `.Trash`, a lexical child of Trash that
resolves outside it, and a lexical outsider that resolves into Trash. Keep
permanent deletion and reversible Trash movement in `clean` exactly as today
for the `descendant` and `outside` outcomes. For `root`, call neither adapter
method, leave all removed/freed counters unchanged, and append a deterministic
failure explaining that the Trash root cannot itself be cleaned.

**Verify**:
`rg -n 'contains\("/\.Trash/"\)|hasSuffix\("/\.Trash"\)' Sources/Geraldine/Services/TrashService.swift`
must return no matches.

### Step 3: Add characterization and regression tests

Create `TrashServiceTests.swift` using XCTest, `@testable import Geraldine`,
UUID-scoped temporary directories, and a fake file-operation adapter that
records calls and can inject failures.

Cover at least:

- a direct child and a deeper descendant of the injected real Trash root are
  classified as permanent-delete candidates;
- the root itself, `.Trash-old`, and `project/.Trash/file` are not;
- the root itself calls neither adapter method, increments no success/freed
  counter, and produces the deterministic refusal failure;
- a candidate lexically inside the Trash root but resolving outside it is not
  classified for permanent deletion;
- a candidate lexically outside the Trash root but resolving inside it is also
  not classified for permanent deletion;
- production resolver success, `~/.Trash` fallback, and no-root fail-closed
  behavior are deterministic through injected filesystem/resolver seams;
- non-Trash items call only the reversible adapter method;
- real-Trash descendants call only permanent removal;
- mixed success/failure preserves `removed`, `trashed`, `permanentlyDeleted`,
  `freed`, and `failures` accounting exactly;
- the first failing item does not prevent later items from being processed.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-001-tests --filter TrashServiceTests`
must pass all new tests.

### Step 4: Run the complete source-level gate

Run the full suite and patch checks. Do not install or launch Geraldine in this
plan; the behavior is exhaustively exercised through the injected boundary.

**Verify**:

- `swift test --scratch-path /tmp/geraldine-plan-001-full` exits 0.
- `git diff --check` exits 0.
- the scope allowlist emits no output, and the recorded `MetricWidgets.swift`
  diff hash is unchanged.

## Test plan

The required cases are listed in Step 3. Model filesystem setup and cleanup on
`LaunchItemIdentityTests`; model dependency injection and failure scripting on
`MonitorHistoryStoreTests.swift:202-296`. Do not touch the user's real Trash.

## Done criteria

- [ ] No production classification depends on a `/.Trash/` substring or suffix.
- [ ] Strict canonical path-component ancestry is tested, including root refusal,
      prefix sibling, nested fake Trash, and symlink cases.
- [ ] Reversible, permanent, and failure accounting tests pass.
- [ ] Full Swift tests and `git diff --check` pass.
- [ ] No source files outside the in-scope list changed.
- [ ] The pre-existing `MetricWidgets.swift` diff hash is unchanged.
- [ ] Plan 001's README status is updated.

## STOP conditions

Stop and report if:

- current callers require external-volume Trash semantics that cannot be
  established from an available platform API;
- a correct test would require touching the actual user Trash;
- canonicalization would require weakening the strict-descendant invariant;
- `TrashService` has drifted from the excerpt or a verification fails twice;
- any source file outside scope appears necessary.

## Maintenance notes

Any new destructive feature must route through this boundary instead of
reimplementing path checks. Reviewers should scrutinize root equality,
path-component comparisons, and symlink behavior. Plan 004 intentionally reuses
this service for Power Tools Empty Trash.
