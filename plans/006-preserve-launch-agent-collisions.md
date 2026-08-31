# Plan 006: Preserve colliding launch agents during toggles

> **Executor instructions**: Follow this plan in order and verify each step.
> Work in a clean isolated checkout supplied by the dispatcher, not the dirty
> primary checkout. Stop on any STOP condition instead of widening scope. When
> complete, update only Plan 006's status cell in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift Tests/GeraldineTests/LoginItemsToggleTests.swift`
> Compare the live toggle flow with the excerpt below. Semantic drift in
> destination construction, row mutation, or outcome publication is a STOP.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug, data safety, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Login Items can represent enabled and disabled launch agents with the same
basename as two distinct rows. Toggling either row currently deletes the other
destination plist before moving the selected source. That silently destroys a
valid configuration, and a subsequent move failure cannot restore it. A
collision must instead fail closed while preserving both files and both rows.

## Current state

- `Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift` owns launch
  item discovery, toggle/remove actions, row state, and outcomes.
- `Tests/GeraldineTests/LaunchItemIdentityTests.swift:28-49` already proves two
  same-basename plists have distinct stable identities. Keep it unchanged.
- `Tests/GeraldineTests/LoginItemsToggleTests.swift` does not exist and will be
  created for the mutation contract.

Current toggle behavior
(`LoginItemsViewModel.swift:186-213` at the planned commit):

```swift
private func performToggle(_ item: LaunchItem) {
    let fm = FileManager.default
    let dest = item.enabled
        ? disabledDir.appendingPathComponent(item.plistURL.lastPathComponent)
        : userAgentsDir.appendingPathComponent(item.plistURL.lastPathComponent)
    try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: item.plistURL, to: dest)
        // success state, row update, outcome, delayed clearing, and load()
    } catch {
        // existing failure state and outcome
    }
}
```

The required invariant is:

1. If the destination exists, refuse before creating, removing, moving, or
   rewriting either plist.
2. If it does not exist, create only the parent directory and request one move.
3. Directory or move failure leaves the selected row unchanged and publishes
   the existing failure state.
4. The toggle-specific dependency has no delete, replace, copy, or write API.
5. A destination created between the check and move makes the move fail; it is
   never deleted or overwritten.
6. Successful toggles retain today's messages, row update, outcome, delayed
   clearing, and rescan.

Use a narrow task-specific protocol and production `FileManager` adapter, in
the style of `Sources/Geraldine/Services/TrashService.swift:3-21`. Do not build
a generic filesystem layer. Tests must use UUID-scoped temporary directories
and must never touch the user's real LaunchAgents directories.

The primary checkout contains unrelated user-owned Dock-preview work. The
dispatcher must supply a clean isolated checkout; do not copy, stage, format,
or clean any of these primary-checkout paths:

- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
- `Sources/Geraldine/Services/Permissions.swift`
- `Sources/Geraldine/Services/PowerTools.swift`
- `build.sh`
- `Sources/Geraldine/Features/PowerTools/DockWindowPreviewView.swift`
- `Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift`
- `Sources/Geraldine/Services/DockWindowPreviewModel.swift`
- `Sources/Geraldine/Services/DockWindowPreviewService.swift`
- `Tests/GeraldineTests/DockWindowPreviewTests.swift`

## Commands you will need

Before tests, prove this is a clean non-primary checkout, replace the
placeholder with the executor's actual Codex thread/session ID, and register
only the test scratch root. Hash the raw owner ID before using it in paths:

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-006-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-006-$RESOURCE_TOKEN-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" \
  --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" \
  --owner "$PLAN_OWNER" \
  --purpose "Plan 006 focused and full Swift tests" \
  --profile swiftpm
git rev-parse HEAD > "$PLAN_TMP/base-commit"
```

Use the verified Xcode 26.5 SDK for every Swift command:

| Purpose | Command | Expected on success |
|---|---|---|
| Clean isolated start | `test -z "$(git status --porcelain=v1 --untracked-files=all)"` | exit 0; no output |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter LoginItemsToggleTests` | all Plan 006 tests pass |
| Identity regression | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build" --filter LaunchItemIdentityTests` | existing identity tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$PLAN_TMP/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PLAN_TMP/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN_TMP/swiftpm-build"` | full suite passes |
| Patch hygiene | `git diff --check` | exit 0; no output |

Record the clean base before edits. At closeout, this allowlist must emit no
paths:

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
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift" && $0 != "Tests/GeraldineTests/LoginItemsToggleTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

After proof is preserved in the task transcript:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" --state disposable \
  --reason "Plan 006 tests passed and proof is preserved in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

Do not run `build.sh`, sign, install, launch, or interact with the app. This
contract is fully testable at source level.

## Scope

**In scope**:

- `Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift`
- `Tests/GeraldineTests/LoginItemsToggleTests.swift` (create)
- `plans/README.md` (Plan 006 status cell only)

**Out of scope**:

- launch-item discovery, stable IDs, removal/Trash behavior, launchd commands,
  UI, and `LaunchItemIdentityTests.swift`;
- overwrite, rename, merge, backup/restore, auto-selection, or deletion as a
  collision policy;
- generic filesystem abstractions, defaults/schema changes, new limits, and
  every current Dock-preview file;
- installed apps, user data, `.git`, `.jj`, packaging, signing, and publishing.

## Git workflow

- Work only in the clean isolated checkout supplied by the dispatcher.
- Suggested branch: `codex/006-preserve-launch-agent-collisions`.
- If the dispatcher requests a commit, use an imperative message such as
  `Preserve launch agent toggle collisions`.
- Do not create or finalize a worktree, commit, merge, push, or open a PR unless
  the dispatcher explicitly assigns that operation.

## Steps

### Step 1: Add a toggle-only filesystem seam

Add one internal protocol and one production adapter in
`LoginItemsViewModel.swift`. Expose only:

- destination existence by URL;
- parent-directory creation by URL; and
- source-to-destination move by URL.

Inject that operator plus enabled/disabled directory URLs into
`LoginItemsViewModel` with production defaults so existing callers remain
source-compatible. Keep dependencies private. Do not change `load`, `remove`,
row identity, published-property visibility, or the public `toggle(_:)` API.

**Verify**: inspect the protocol and confirm it has no removal, replacement,
copy, arbitrary-write, or Trash capability. Run `git diff --check`.

### Step 2: Refuse collisions before mutation

Change only `performToggle(_:)` and a narrow task-specific error/helper:

1. Construct the destination exactly as today.
2. Check destination existence before parent creation or move.
3. On collision, route a deterministic message through the existing failure
   state/outcome and state that neither item was changed.
4. Otherwise create the parent and request exactly one move.
5. Preserve the full success path only after that move succeeds.
6. Leave in-memory URL/enabled state unchanged after every failure.

Delete the destination-removal branch. Do not replace it with another overwrite
mechanism or a generated alternate filename.

**Verify**:

```sh
rg -n 'removeItem\s*\(' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift
```

Expected result: exit 1 with no output. Also inspect the diff to confirm the
separate `performRemoval` path was not changed.

### Step 3: Add deterministic mutation tests

Create `LoginItemsToggleTests.swift` with XCTest and `@testable import
Geraldine`. Use an `@MainActor` test class, UUID-scoped temporary roots, and a
spy conforming to the new operator protocol. The spy may inject existence,
directory, and move results; it must not expose deletion.

Cover at least:

- enabled-to-disabled and disabled-to-enabled same-basename collisions;
- byte-for-byte preservation of both files and unchanged rows on collision;
- parent-creation failure requests no move and publishes failure;
- move failure leaves the source and row unchanged and publishes failure;
- a collision triggers neither success nor success-path rescan; and
- successful enable and disable each move once and preserve existing state,
  message, outcome, delayed-clear, and rescan behavior.

Use deterministic yielding or an injected completion seam; never arbitrary
sleeps or the user's real LaunchAgents directories.

**Verify**: run the focused and identity-regression commands.

### Step 4: Run the full gate and scoped review

Run the full suite, the no-deletion search, `git diff --check`, and the scope
allowlist. Review every hunk for collision preservation and confirm removal
behavior is unchanged. If a review fix changes code, repeat focused and full
tests. Update only Plan 006's README status cell, then finalize the registered
SwiftPM root and close out its owner.

## Test plan

The focused tests must prove both collision directions, file-content
preservation, exact operator call counts, directory/move failure, unchanged
in-memory state on failure, and successful enable/disable behavior. The
unchanged identity suite proves duplicate basenames remain representable; the
full suite guards adjacent Login Items and Power Tools behavior.

## Done criteria

- [ ] Both collision directions refuse before parent creation or move.
- [ ] Both plists and both rows remain unchanged on collision.
- [ ] The toggle seam has no deletion/overwrite capability and the toggle path
      contains no `removeItem` call.
- [ ] Directory and move failures publish failure without success/rescan.
- [ ] Successful toggles retain existing behavior.
- [ ] Focused, identity, and full tests pass under the explicit SDK.
- [ ] `git diff --check` and the scope allowlist pass.
- [ ] Only Plan 006's README status cell changes outside source/test scope.
- [ ] The SwiftPM scratch root is finalized and owner closeout passes.
- [ ] No build, install, launch, packaging, push, or live-user-data action ran.

## STOP conditions

Stop and report if:

- the isolated checkout is dirty or the executor owner ID is unavailable;
- live toggle semantics differ materially from the excerpt;
- the new test path has unrelated ownership;
- preserving collisions appears to require deletion, replacement, rename,
  merge, backup, a new policy/default, or a broader filesystem layer;
- deterministic tests would touch real LaunchAgents data;
- any out-of-scope file appears necessary; or
- a focused or full verification fails twice after one in-scope correction.

## Maintenance notes

Same-basename enabled and disabled plists are distinct configurations. Future
toggle changes must continue to fail closed on destination existence and keep
deletion absent from the toggle-specific seam. Removal remains a separate,
explicit user action through the existing Trash path.
