# Plan 013: Harden Login Item plist reading

> **Executor instructions**: Follow this plan in the clean isolated worktree
> supplied by the dispatcher. Run every verification gate. On a STOP condition,
> report it; do not improvise or manage a Git worktree. When done, update only
> Plan 013's status cell in `plans/README.md`, unless the reviewer owns the index.
>
> **Dependency gate**: Plan 006 must be DONE and integrated before Plan 013
> starts. Both edit `LoginItemsViewModel.swift`; never execute them in parallel.
> Preserve Plan 006's toggle collision refusal, operator, and dependencies.
>
> **Mandatory authorization gate — run before any edit**: Vincent selected this
> finding but has not approved a byte ceiling. Require an explicit, exact positive
> byte count from Vincent or a dispatcher carrying his approval; otherwise STOP
> before editing. Never infer one, copy an adjacent value, or omit oversized-input
> handling. The Uninstaller's 1,048,576 bytes is an option, not authorization.
>
> **Drift check**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift Tests/GeraldineTests/LoginItemsScanSafetyTests.swift plans/README.md`
> Plan 006 changes in `LoginItemsViewModel.swift` and its README cell are expected.
> The `scan` implementation shown below must otherwise still match semantically,
> and the new test file must not have unrelated ownership. Any other mismatch is
> a STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/006-preserve-launch-agent-collisions.md`
- **Category**: security, bug, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Login Items parses user-writable `.plist` paths with `NSDictionary(contentsOf:)`,
which can follow links and is unsafe for FIFOs, devices, directories, or unbounded
input. The hardened path will validate the opened descriptor, apply an approved
bound, use `PropertyListSerialization`, diagnose rejects, and retain every scope.

## Current state

`Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift:251-278`
currently scans four directories and trusts each `.plist` URL:

```swift
private nonisolated static func scan(userDir: URL, disabledDir: URL) -> LoginItemsScanResult {
    var out: [LaunchItem] = []
    var diagnostics = ScanDiagnostics()
    let fm = FileManager.default
    func read(_ dir: URL, scope: LaunchItem.Scope, enabled: Bool) {
        guard fm.fileExists(atPath: dir.path) else { return }
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for url in files where url.pathExtension == "plist" {
                diagnostics.noteScanned()
                let dict = NSDictionary(contentsOf: url)
                let label = (dict?["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
                let program = (dict?["Program"] as? String)
                    ?? (dict?["ProgramArguments"] as? [String])?.first
                    ?? ""
                out.append(LaunchItem(label: label, program: program, plistURL: url,
                                      scope: scope, enabled: enabled))
            }
        } catch {
            diagnostics.noteSkipped(dir, error)
        }
    }
    read(userDir, scope: .user, enabled: true)
    read(disabledDir, scope: .user, enabled: false)
    read(URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .global, enabled: true)
    read(URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .daemon, enabled: true)
    diagnostics.finish()
    return LoginItemsScanResult(items: out, diagnostics: diagnostics)
}
```

The local hardened exemplar is
`Sources/Geraldine/Features/Uninstaller/UninstallerViewModel.swift:176-203`:

```swift
private nonisolated static let maximumLaunchAgentPlistBytes = 1_048_576
let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
guard descriptor >= 0 else { return nil }
defer { Darwin.close(descriptor) }
var info = stat()
guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size >= 0,
      info.st_size <= maximumLaunchAgentPlistBytes else { return nil }
let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
guard let data = try? handle.read(upToCount: maximumLaunchAgentPlistBytes + 1),
      data.count <= maximumLaunchAgentPlistBytes,
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
      ),
      let dictionary = propertyList as? [String: Any] else { return nil }
```

Match its descriptor ownership and flags, but do not copy its 1 MiB value unless
that exact value is explicitly approved for Login Items. Preserve these current
semantics for valid files:

- user LaunchAgents are `.user`, enabled; Geraldine's disabled directory is `.user`, disabled;
- `/Library/LaunchAgents` is `.global`, enabled; `/Library/LaunchDaemons` is `.daemon`, enabled;
- `Label` falls back to the filename stem; `Program` precedes the first `ProgramArguments`; missing program stays empty;
- each `.plist` still increments `scannedItems`; rejects also call `noteSkipped(url, error)` and are not appended.

`ScanDiagnostics.noteSkipped` already caps stored issue samples while retaining
`skippedTotal`; reuse it. Plan 006 may have converted the enabled/disabled URLs
to injected stored properties. Reuse those properties in the production source
list. Do not merge the read-only scan helper with Plan 006's mutation seam.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Plan 006 gate | `awk -F'|' '$2 ~ /^[[:space:]]*006[[:space:]]*$/ && $0 ~ /DONE/ { found=1 } END { exit !found }' plans/README.md` | exit 0 |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Focused tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter LoginItemsScanSafetyTests` | all Plan 013 tests pass |
| Login Items regression | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter 'LaunchItemIdentityTests|LoginItemsToggleTests|LoginItemsScanSafetyTests'` | all selected tests pass |
| Full tests | `/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build"` | exit 0; all tests pass |
| Old parser absent | `rg -n 'NSDictionary\(contentsOf:' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift` | exit 1; no output |
| Patch hygiene | `git diff --check` | exit 0; no output |

Do not run `./build.sh`, install, package, sign, launch Geraldine, touch
`/Applications`, push, or open a PR. Swift tests are the complete proof surface.

## Isolated-worktree and CLAYGO setup

The dispatcher supplies the isolated worktree. Before editing, run:

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$WORKTREE_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1)"
BASE_COMMIT="$(git rev-parse HEAD)"
awk -F'|' '$2 ~ /^[[:space:]]*006[[:space:]]*$/ && $0 ~ /DONE/ { found=1 } END { exit !found }' plans/README.md
: "${EXECUTOR_OWNER_ID:?Use the actual host-provided thread/session ID}"
: "${APPROVED_LOGIN_ITEM_PLIST_BYTES:?Use Vincent's exact approved byte count; do not choose one}"
case "$APPROVED_LOGIN_ITEM_PLIST_BYTES" in ''|*[!0-9]*) exit 1 ;; esac
test "$APPROVED_LOGIN_ITEM_PLIST_BYTES" -gt 0
RESOURCE_TOKEN="$(printf '%s' "$EXECUTOR_OWNER_ID" | shasum -a 256 | cut -c1-12)"
SWIFTPM_ROOT="/private/tmp/geraldine-plan-013-swiftpm-${RESOURCE_TOKEN}"
SWIFTPM_RECEIPT="/tmp/geraldine-plan-013-swiftpm-${RESOURCE_TOKEN}-receipt.json"
test ! -e "$SWIFTPM_ROOT"
test ! -e "$SWIFTPM_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$SWIFTPM_ROOT" --temp-root /private/tmp \
  --receipt "$SWIFTPM_RECEIPT" --owner "$EXECUTOR_OWNER_ID" \
  --purpose "Plan 013 SwiftPM verification" --profile swiftpm
```

The owner ID must be host-provided and the byte value copied verbatim from explicit
authorization. If Swift `Int` cannot represent it plus one, STOP; never clamp it.

Use this scope guard before every review waypoint and at closeout:

```sh
set -e
set -o pipefail
git cat-file -e "$BASE_COMMIT^{commit}"
test "$(git rev-parse HEAD)" = "$BASE_COMMIT"
unstaged="$(git diff --name-only "$BASE_COMMIT" -- .)"
staged="$(git diff --cached --name-only "$BASE_COMMIT" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift" && $0 != "Tests/GeraldineTests/LoginItemsScanSafetyTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

The primary checkout's Dock-preview work is user-owned. Never copy, edit, stage,
format, clean, or otherwise disturb it. Register only the SwiftPM scratch root;
do not register or finalize the dispatcher-owned worktree.

## Scope

**In scope** (the only files that may change):

- `Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift`
- `Tests/GeraldineTests/LoginItemsScanSafetyTests.swift` (create)
- `plans/README.md` (Plan 013 status cell only)

**Out of scope**:

- Plan 006's collision behavior, toggle operator, and toggle tests;
- `UninstallerViewModel.swift` and its 1 MiB constant;
- Login Items UI, removal, identity, actor/generation behavior, system-directory policy, `ScanDiagnostics`, and all other files;
- generic filesystem abstraction, recursion, link-target resolution, or omission of either system LaunchAgents directory;
- any byte ceiling not explicitly approved as an exact count.

## Git workflow

Work only in the clean isolated worktree supplied by the dispatcher. Do not run
`git worktree`, switch branches, commit, push, stage, stash, reset, clean, merge,
or open a PR. Leave the scoped diff for reviewer integration.

## Steps

### Step 1: Record the approved bound and add a narrow safe reader

After authorization, add one Login-Items-specific maximum using exactly
`$APPROVED_LOGIN_ITEM_PLIST_BYTES`, on one line for verification. Add a private
helper and small private metadata/error types; no reusable filesystem service.
Add the narrow `Darwin` import required by `open`, `fstat`, and `close`.

Open with `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK`, defer one close, use
descriptor `fstat`, require regular/nonnegative/within-bound size, and read at
most the bound plus one. Reject post-`fstat` growth. Require a dictionary from
`PropertyListSerialization`; return stable errors for every rejection category.

Do not use path preflight metadata as the authority, follow a symlink, retry
without `O_NOFOLLOW`, call `Data(contentsOf:)`, or fall back to
`NSDictionary(contentsOf:)`.

**Verify**:

```sh
declared="$(sed -nE 's/^[[:space:]]*.*maximumLoginItemPlistBytes = ([0-9_]+)$/\1/p' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift | tr -d '_')"
test "$declared" = "$APPROVED_LOGIN_ITEM_PLIST_BYTES"
rg -n 'O_NOFOLLOW.*O_NONBLOCK|fstat\(|S_IFREG|PropertyListSerialization' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift
git diff --check
```

All commands exit 0; the declaration equals the explicitly approved count.

### Step 2: Route all four scan sources through the safe reader

Add an internal `LoginItemsScanSource` with directory, scope, and enabled state,
plus a testable scan entry point. The production wrapper constructs exactly the
four current mappings, reusing Plan 006's user/disabled URLs.

For each case-sensitive `.plist` candidate, retain `noteScanned()` at its current
position. On helper success, preserve label/program fallback semantics and append
the item with that source's scope/enabled state. On helper failure, call
`noteSkipped(url, error)` and append nothing. Directory enumeration failure still
diagnoses the directory. Always call `diagnostics.finish()`.

Make only the source descriptor, test scan entry point, result fields, and
approved maximum as visible as `@testable import` requires. Keep the reader and
error implementation private.

**Verify**:

```sh
rg -n '"/Library/LaunchAgents"|"/Library/LaunchDaemons"' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift
rg -n 'NSDictionary\(contentsOf:' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift && exit 1 || true
```

The first command shows both production system sources; the second emits nothing.
Run the scope guard; it must exit 0 with no output.

### Step 3: Add deterministic scan-safety tests

Create `LoginItemsScanSafetyTests.swift` with XCTest, `@testable import Geraldine`,
and `Darwin`. Each test owns one UUID temporary root removed in `defer`. Invoke
only the internal scan entry point; never call `load()` or touch real directories.

Cover valid regular XML plists (including `Program` precedence and
`ProgramArguments` fallback), all four scope/enabled mappings, a symlink to a
valid plist, a `.plist` directory, a FIFO made with `Darwin.mkfifo`, malformed
regular data, and a non-plist file. Assert rejected paths appear in diagnostics,
`skippedTotal` is exact, candidates still count as scanned, and only valid files
become items. Run the FIFO scan off the test's main thread with an XCTest
expectation so a regression fails instead of hanging the suite; this is test
harness protection, not a production timeout.

For the oversized case, create a sparse regular file and truncate it to exactly
the approved maximum plus one; do not allocate a `Data` buffer of that size.
Assert rejection and diagnostics. If the approved count cannot be represented by
the sparse-file API or the environment cannot safely create the fixture, STOP;
do not substitute a smaller test ceiling or skip this case.

**Verify**:

```sh
test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter LoginItemsScanSafetyTests
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH="$SWIFTPM_ROOT/clang-module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_ROOT/swiftpm-module-cache" /usr/bin/xcrun --sdk macosx swift test --scratch-path "$SWIFTPM_ROOT/build" --filter 'LaunchItemIdentityTests|LoginItemsToggleTests|LoginItemsScanSafetyTests'
```

Both commands exit 0 and all selected tests pass.

### Step 4: Run full verification, review, and close scratch storage

Run the full suite, `git diff --check`, the old-parser absence check, and the
scope guard. Review every hunk for Plan 006 regressions, descriptor leaks,
path-based TOCTOU checks, missing diagnostics, altered source mappings, real
directory access in tests, and any unapproved ceiling. If review accepts a code
change, rerun focused and full tests.

Then update only Plan 013's README status cell. Finalize the scratch root:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark --receipt "$SWIFTPM_RECEIPT" --state disposable --reason "Plan 013 tests complete; proof retained in transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize --receipt "$SWIFTPM_RECEIPT" --check-open-files
test ! -e "$SWIFTPM_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout --owner "$EXECUTOR_OWNER_ID" --finalize-disposable
test ! -e "$SWIFTPM_RECEIPT"
```

All commands must exit 0. Report the approved byte count, test results, exact
finalized scratch path, scope-guard result, and that no install/push occurred.

## Test plan

The new focused suite covers valid metadata, both user states, global and daemon
scopes, no-follow symlinks, nonblocking FIFO handling, directory rejection,
malformed parsing, ignored extensions, the explicitly approved oversized
boundary, and diagnostics. Existing identity/toggle tests protect Plan 006 and
Login Item identity; the full suite protects the app-wide scan behavior.

## Done criteria

- [ ] An exact positive byte count was explicitly approved and the source
      declaration matches it; no default or inferred value was used.
- [ ] The reader uses `O_NOFOLLOW | O_NONBLOCK`, descriptor `fstat`, `S_IFREG`,
      one bounded read, and `PropertyListSerialization`.
- [ ] `rg -n 'NSDictionary\(contentsOf:' Sources/Geraldine/Features/LoginItems/LoginItemsViewModel.swift`
      exits 1 with no output.
- [ ] Symlink, FIFO, directory, malformed, and approved-limit-plus-one inputs are
      rejected and diagnosed; valid regular files retain existing metadata.
- [ ] All four production sources retain their scope/enabled mappings.
- [ ] Focused Login Items tests and the full Swift suite pass with SDK 26.5.
- [ ] The scope guard and `git diff --check` pass; only the three scoped paths
      changed and Plan 006 behavior is intact.
- [ ] SwiftPM scratch is finalized and owner closeout succeeds.
- [ ] No Git worktree management, commit, install, launch, package, push, or PR
      operation was performed.

## STOP conditions

Stop and report if the exact byte count or actual executor owner ID is absent;
Plan 006 is not integrated; the scan excerpt drifted beyond Plan 006; the test
file has unrelated ownership; the supplied worktree is primary or dirty; SDK
26.5 is unavailable; the approved count cannot safely support `+ 1` or a sparse
fixture; the implementation would omit a system source, follow links, accept a
non-regular file, suppress diagnostics, change valid metadata/scopes, touch real
LaunchAgents, alter Plan 006, add a generic filesystem layer, or edit another
file; a verification fails twice after one reasonable in-scope correction; the
scope guard fails; or CLAYGO cannot safely finalize the scratch root.

## Maintenance notes

Any future Login Item scan source must enter through the same safe reader and
carry an explicit scope/enabled mapping. Changing the plist byte ceiling is a
separate policy decision requiring Vincent's explicit approval and matching
boundary-test updates; do not synchronize it automatically with the Uninstaller.
Reviewers should scrutinize descriptor lifetime, the `fstat`/read race defense,
FIFO nonblocking behavior, per-file diagnostics, all four production sources,
and preservation of Plan 006's independent mutation boundary.
