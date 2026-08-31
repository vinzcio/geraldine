# Plan 016: Add deterministic source verification and current documentation

> **Executor instructions**: Follow this plan step by step in the clean isolated
> worktree supplied by the dispatcher. Run every verification command and
> confirm its expected result before continuing. If a STOP condition occurs,
> stop and report it instead of improvising. Update only Plan 016's status cell
> in `plans/README.md` after every gate passes. Do not create or finalize a Git
> worktree, modify `build.sh`, commit, push, sign, bundle, install, or launch
> Geraldine.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Package.swift Sources Tests build.sh HANDOFF.md design-qa.md plans/README.md`
> Plans 006-015 are expected to have changed their declared source/test paths
> and status cells before this documentation plan runs. Reconcile those changes
> into the current docs. Plan 014 is also expected to have produced the exact
> integrated `build.sh` disclosure hash and strings gated below. Any other
> `build.sh` state, verifier-input drift, or proof-boundary drift is a STOP;
> this plan still never edits `build.sh`.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: Plans 006-015 (run after the selected code queue) and an
  explicitly approved exact free-space gate
- **Category**: dx, tooling, docs, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Geraldine has no root README or deterministic source-level entry point.
`build.sh` stages outside OneDrive but continues through bundle/signing work and
can install and launch. `HANDOFF.md` mixes current context with old session
directives; `design-qa.md` treats ephemeral `/tmp` captures as still available.

## Current state

- `Package.swift:1-33` declares macOS 14 targets `CThermal`, `Geraldine`, and `GeraldineTests`; it has no third-party package dependencies.
- `build.sh:64-83` demonstrates staging outside OneDrive, but lines 76 onward
  assemble/sign/package. The verifier must not call, source, or modify it.
- After the committed Dock-preview lane and Plan 014, `build.sh` must have
  SHA-256 `eabd3056838f5706127dd70056cf2ad3f7397ec63cb62a79a1cce80a39787ee4`,
  the exact Finder Apple Events disclosure, and the exact local-only Dock
  preview Screen Recording disclosure. This is a prerequisite identity gate,
  not an in-scope edit. Any other hash is a STOP for fresh reconciliation.
- `HANDOFF.md:8-208` contains three old closeout snapshots, historical feature
  narratives, a stale menu-bar blocker, logout/reboot guidance, a speculative
  `MenuBarExtra` rewrite, foreground/live-app steps, and process advice. None is
  a current reproducible blocker at the planning commit.
- `design-qa.md:8-18` points to captures under `/tmp`; those files are ephemeral
  session artifacts, not durable repository evidence. The recorded comparison
  can remain historical, but its paths and `final result: passed` must not imply
  present availability or current re-verification.
- At planning time Xcode is 26.6 build 17F113, xcrun selects the explicit
  `MacOSX26.5.sdk`, and Swift is Apple Swift 6.3.3. Print actual values, fail if
  that SDK is unavailable, and do not relabel the Xcode version as 26.5.

The source-verification contract is:

1. Accept an explicit CLAYGO owner and an exact positive minimum-free-space
   value copied from Vincent's or the dispatcher's explicit approval; reject
   missing/unknown arguments. The verifier has no built-in numeric default.
2. Before allocating scratch, report `/private/tmp` capacity and fail safely
   when available 1 KiB blocks are below that supplied value or an exact-name
   heavy compiler/build process is active. This is an execution safety gate,
   not a Geraldine product limit or a newly selected ceiling.
3. Register one unique `/private/tmp` root with the absolute CLAYGO script,
   a receipt outside that root, the supplied owner, and profile `swiftpm`.
4. Stage only `Package.swift`, `Sources`, and `Tests` into that root. Never
   build from or write generated artifacts into the OneDrive checkout.
5. Bind the staged bytes to the checkout: capture full/short Git revision,
   clean/dirty state, and a deterministic SHA-256 manifest of `Package.swift`,
   `Sources`, and `Tests`; require the staged manifest and post-copy/final source
   manifests to match exactly. Print the source/stage digest plus Xcode
   version/build, Swift version, developer directory, and exact SDK path.
6. Run the complete Swift test suite and a separately clean release build with
   distinct scratch and module-cache roots, the explicit macOS 26.5 SDK, and
   no reuse of test build products for release proof.
7. Never assemble/sign/install/launch an app, access credentials, call
   `build.sh`, foreground UI, or kill a process.
8. On every exit, mark/finalize the scratch, close out its owner, and verify
   absence; cleanup failure makes verification fail with exact owned paths.

## Commands and supplied-worktree guard

Run in one zsh session with the real executor thread/session ID. The verifier
owns its only scratch root; do not pre-create another.

```zsh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
: "${APPROVED_VERIFY_MIN_FREE_KIB:?Use the exact positive value explicitly approved for this execution}"
case "$APPROVED_VERIFY_MIN_FREE_KIB" in ''|*[!0-9]*) exit 1 ;; esac
test "$APPROVED_VERIFY_MIN_FREE_KIB" -gt 0
PLAN_BASE="$(git rev-parse HEAD)"
test -n "$PLAN_BASE"

DEVELOPER_DIR_26='/Applications/Xcode.app/Contents/Developer'
SDKROOT_26_5="$DEVELOPER_DIR_26/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
test -d "$SDKROOT_26_5"
test "$(/usr/bin/env DEVELOPER_DIR="$DEVELOPER_DIR_26" /usr/bin/xcrun --sdk macosx --show-sdk-path)" = "$SDKROOT_26_5"
printf 'SDK path: %s\n' "$SDKROOT_26_5"

test "$(/usr/bin/shasum -a 256 build.sh | /usr/bin/awk '{print $1}')" = \
  'eabd3056838f5706127dd70056cf2ad3f7397ec63cb62a79a1cce80a39787ee4'
rg -Fx '    <key>NSAppleEventsUsageDescription</key><string>Geraldine controls Finder when you run Finder tools, to read or open selected files and folders and use the folder shown in the front Finder window.</string>' build.sh
rg -Fx '    <key>NSScreenCaptureUsageDescription</key><string>Geraldine shows window thumbnails when you hover over Dock apps. Previews stay on this Mac and are not saved.</string>' build.sh
! rg -n 'NSAppleEventsUsageDescription.*system maintenance' build.sh
```

The SDK equality assertion and all three Plan 014 identity checks must pass.
Keep `PLAN_OWNER` and `PLAN_BASE` in this shell; if either is lost, STOP and
restart from the clean checkout rather than reconstructing a base after edits.

| Purpose | Command | Expected on success |
|---|---|---|
| Shell syntax | `/bin/bash -n verify.sh` | exit 0, no output |
| Owner refusal | `! ./verify.sh` | usage on stderr; no scratch root is created |
| Failure cleanup | Run the `failure` self-test block in Step 5 | nonzero verifier status; printed root and receipt are absent; owner closeout passes |
| TERM cleanup | Run the `term` self-test block in Step 5 | TERM reaches the EXIT trap; printed root and receipt are absent; owner closeout passes |
| Source verification | `./verify.sh --owner "$PLAN_OWNER" --minimum-free-kib "$APPROVED_VERIFY_MIN_FREE_KIB"` | full tests and clean release build pass; provenance and cleanup are reported |
| Patch hygiene | `git diff --check "$PLAN_BASE"` | exit 0, no output |
| CLAYGO closeout | `/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout --owner "$PLAN_OWNER" --finalize-disposable` | exit 0; no unexplained owner resources remain |

At closeout, this allowlist must emit no paths:

```zsh
set -e
set -o pipefail
git cat-file -e "$PLAN_BASE^{commit}"
test "$(git rev-parse HEAD)" = "$PLAN_BASE"
unstaged="$(git diff --name-only "$PLAN_BASE" -- .)"
staged="$(git diff --cached --name-only "$PLAN_BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "verify.sh" && $0 != "README.md" && $0 != "HANDOFF.md" && $0 != "design-qa.md" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

## Scope

**In scope**:

- `verify.sh` (create and make executable)
- `README.md` (create)
- `HANDOFF.md` (replace stale narrative with current open-work handoff)
- `design-qa.md` (qualify existing record as historical/unavailable evidence)
- `plans/README.md` (Plan 016 status cell only, after all gates pass)

**Out of scope**:

- `build.sh`, `Package.swift`, `Sources`, `Tests`, resources, entitlements,
  package versions, compiler settings, and app/runtime behavior.
- Signing/notarization/bundling, installation, launch, foreground UI, manual
  acceptance, CI, dependency migration, or another verifier/framework.
- New accounts, backend, sync, clipboard history, retention, caches, quotas,
  timeouts, scan ceilings, release policy, or other product constraints.
- Dirty primary-checkout work, `.git`/`.jj`, worktree management, commit, push,
  or any file not listed above.

## Steps

### Step 1: Create a fail-closed verifier preflight and provenance report

Create executable `verify.sh` with `#!/bin/bash` and `set -euo pipefail`.
Normal verification supports `--owner <non-empty-value>` and
`--minimum-free-kib <positive integer>`. It also supports one explicit
test-only option, `--self-test-after-register failure|term`, used solely by the
cleanup gates in Step 5; it must exit before staging or Swift work. Missing
values, extra arguments, option-like owner values, zero, nonnumeric space
values, and any other self-test value fail before scratch allocation. Do not
provide or infer a numeric default. Resolve the repository from the script's
own directory and require readable `Package.swift`, `Sources`, and `Tests` plus
a valid Git worktree.

Before CLAYGO initialization:

- obtain available 1 KiB blocks from `/bin/df -Pk /private/tmp`, print the
  available and explicitly supplied values, and refuse below the supplied
  value with a concise disk-space message;
- query only exact process names with `/usr/bin/pgrep -x` for
  `swift-frontend`, `swiftc`, `clang`, and `xcodebuild`; print only the blocking
  names, never PIDs or command lines, and refuse while any are active;
- require the explicit developer directory and `MacOSX26.5.sdk` path above;
- require `xcrun --sdk macosx --show-sdk-path` to resolve to that same path.

Print full and 12-character Git revision, dirty state including untracked files,
`xcodebuild -version`, `xcrun --sdk macosx swift --version`, developer directory,
and SDK path. Dirty source may run, but label it as not commit-reproducible and
bind the run to the exact input digest described in Step 2. Never dump the
environment or print unrelated values.

**Verify**: `/bin/bash -n verify.sh` exits 0, and `! ./verify.sh` refuses before
any `/private/tmp/geraldine-verify-*` path is created.

### Step 2: Stage exact inputs, run isolated proof, and own cleanup

Derive a 12-character SHA-256 key from the raw owner and combine it with `$$`
so slash-containing IDs cannot nest paths and each invocation owns a unique root such as
`/private/tmp/geraldine-verify-<key>-<pid>`. Put its receipt at the matching
`/tmp/geraldine-verify-<key>-<pid>-receipt.json`. Assert both paths are absent,
then initialize with:

```zsh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$VERIFY_ROOT" \
  --temp-root /private/tmp \
  --receipt "$VERIFY_RECEIPT" \
  --owner "$VERIFY_OWNER" \
  --purpose 'Geraldine staged source tests and clean release build' \
  --profile swiftpm
```

Install an EXIT trap only after successful registration. It must retain the
original command status, mark this receipt `disposable` with a factual reason,
run `finalize --receipt ... --check-open-files`, run `closeout --owner ...
--finalize-disposable`, and assert both root and receipt are absent. Cleanup
failure forces nonzero. INT/TERM must reach the same EXIT trap exactly once.
Never delete the root directly or weaken CLAYGO checks. Immediately after the
trap is active, print exact `VERIFY_ROOT=<path>` and
`VERIFY_RECEIPT=<path>` lines. In cleanup self-test mode, trigger `false` for
`failure` or `/bin/kill -TERM "$$"` for `term`; explicit signal handlers must
preserve status 130 for INT and 143 for TERM before reaching EXIT, and neither
self-test mode may stage or run Swift. Only after its own mark, finalize,
owner-closeout, and exact root/receipt absence succeed may the EXIT trap print
`VERIFY_INTERNAL_CLOSEOUT=OK mode=<normal|failure|term> original_status=<status>`.
It then returns the preserved original
status: 1 for the controlled failure and 143 for TERM. On the normal path, set
an internal completion flag only after every source and Swift gate passes; the
EXIT trap prints `SOURCE VERIFICATION PASSED` only after its cleanup succeeds
and the original status plus completion flag both indicate success.

Before copying, capture the full HEAD in `$VERIFY_ROOT/source-head-before`, the
complete porcelain status in `$VERIFY_ROOT/source-status-before`, and a binary,
deterministic input manifest. Implement one `write_input_manifest <base> <out>`
helper that visits only `Package.swift`, `Sources`, and `Tests` in stable
`LC_ALL=C /usr/bin/find -s ... -print0` order. Materialize each find result to a
task-owned list file and require find itself to exit 0 before reading it; never
use process substitution or a pipeline that can discard traversal status. For
every regular file or directory, write NUL-delimited relative path, entry type,
POSIX mode, and either the file SHA-256 or `-` for a directory. Reject every
symlink and every other entry type; the planning inputs contain no symlinks, and
allowing one could escape the staged-input boundary. The manifest and find lists
stay outside `stage/`.

Use this exact helper shape; do not substitute timestamps, inode numbers, or
absolute checkout paths into the digest:

```bash
write_input_manifest() {
  local base="$1"
  local output="$2"
  local input entry rel type mode digest find_list
  : > "$output"
  for input in Package.swift Sources Tests; do
    find_list="${output}.find.${input}"
    LC_ALL=C /usr/bin/find -s "$base/$input" -print0 > "$find_list" || return 1
    while IFS= read -r -d '' entry; do
      rel="${entry#"$base"/}"
      mode="$(/usr/bin/stat -f '%Lp' "$entry")"
      if [ -L "$entry" ]; then
        return 1
      elif [ -f "$entry" ]; then
        type='file'
        digest="$(/usr/bin/shasum -a 256 "$entry" | /usr/bin/awk '{print $1}')"
      elif [ -d "$entry" ]; then
        type='directory'
        digest='-'
      else
        return 1
      fi
      /usr/bin/printf '%s\0%s\0%s\0%s\0' \
        "$rel" "$type" "$mode" "$digest" >> "$output"
    done < "$find_list"
  done
}
```

The invariant is byte-for-byte manifest equality, not a filename count:

```zsh
git -C "$REPO_ROOT" rev-parse HEAD > "$VERIFY_ROOT/source-head-before"
git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > \
  "$VERIFY_ROOT/source-status-before"
write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-before.manifest"
SOURCE_INPUT_SHA256="$(/usr/bin/shasum -a 256 "$VERIFY_ROOT/source-before.manifest" | /usr/bin/awk '{print $1}')"
printf 'Source input SHA-256: %s\n' "$SOURCE_INPUT_SHA256"
```

Stage exact content using absolute `/usr/bin/rsync -a` calls with trailing-slash
semantics:

- source `Package.swift` to `<root>/stage/Package.swift`;
- contents of `Sources/` to `<root>/stage/Sources/` with `--delete`;
- contents of `Tests/` to `<root>/stage/Tests/` with `--delete`.

```zsh
/bin/mkdir -p "$VERIFY_ROOT/stage/Sources" "$VERIFY_ROOT/stage/Tests"
/usr/bin/rsync -a "$REPO_ROOT/Package.swift" "$VERIFY_ROOT/stage/Package.swift"
/usr/bin/rsync -a --delete "$REPO_ROOT/Sources/" "$VERIFY_ROOT/stage/Sources/"
/usr/bin/rsync -a --delete "$REPO_ROOT/Tests/" "$VERIFY_ROOT/stage/Tests/"
```

Do not stage `.git`, `.jj`, `build.sh`, resources, entitlements, README files,
or generated directories. Confirm the stage contains those three inputs and no
`.git`, `.jj`, or `.build` before invoking Swift. Then generate
`stage.manifest` and `source-after-copy.manifest`, recapture HEAD and porcelain
status, and require all of the following before invoking Swift:

```zsh
write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage.manifest"
write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-after-copy.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/stage.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/source-after-copy.manifest"
test "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(<"$VERIFY_ROOT/source-head-before")"
git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > "$VERIFY_ROOT/source-status-after-copy"
/usr/bin/cmp -s "$VERIFY_ROOT/source-status-before" "$VERIFY_ROOT/source-status-after-copy"
STAGED_INPUT_SHA256="$(/usr/bin/shasum -a 256 "$VERIFY_ROOT/stage.manifest" | /usr/bin/awk '{print $1}')"
test "$STAGED_INPUT_SHA256" = "$SOURCE_INPUT_SHA256"
printf 'Staged input SHA-256: %s\n' "$STAGED_INPUT_SHA256"
```

After both Swift commands, generate a final source manifest and recapture HEAD
and status. Require them to match the same before-files again before printing a
success result. This both rejects a mixed OneDrive copy and binds the reported
Git/dirty provenance to the exact staged bytes that were tested and built.

Run the full suite first with this exact toolchain shape:

```zsh
/usr/bin/env \
  DEVELOPER_DIR="$DEVELOPER_DIR_26" \
  SDKROOT="$SDKROOT_26_5" \
  CLANG_MODULE_CACHE_PATH="$VERIFY_ROOT/test-clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$VERIFY_ROOT/test-swiftpm-module-cache" \
  /usr/bin/xcrun --sdk macosx swift test \
    --package-path "$VERIFY_ROOT/stage" \
    --scratch-path "$VERIFY_ROOT/test-build"
```

Immediately after tests and before release, prove that executing the tests did
not mutate any staged input:

```zsh
write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage-after-tests.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/stage.manifest" "$VERIFY_ROOT/stage-after-tests.manifest"
```

Then run this exact clean release command:

```zsh
test ! -e "$VERIFY_ROOT/release-build"
test ! -e "$VERIFY_ROOT/release-clang-module-cache"
test ! -e "$VERIFY_ROOT/release-swiftpm-module-cache"
/usr/bin/env \
  DEVELOPER_DIR="$DEVELOPER_DIR_26" \
  SDKROOT="$SDKROOT_26_5" \
  CLANG_MODULE_CACHE_PATH="$VERIFY_ROOT/release-clang-module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$VERIFY_ROOT/release-swiftpm-module-cache" \
  /usr/bin/xcrun --sdk macosx swift build -c release \
    --package-path "$VERIFY_ROOT/stage" \
    --scratch-path "$VERIFY_ROOT/release-build"
```

Immediately after release compilation, re-manifest the staged package again:

```zsh
write_input_manifest "$VERIFY_ROOT/stage" "$VERIFY_ROOT/stage-after-release.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/stage.manifest" "$VERIFY_ROOT/stage-after-release.manifest"
```

Do not use `--skip-build`, reuse the test scratch, or call `build.sh`. The
normal path must then run:

```zsh
write_input_manifest "$REPO_ROOT" "$VERIFY_ROOT/source-final.manifest"
/usr/bin/cmp -s "$VERIFY_ROOT/source-before.manifest" "$VERIFY_ROOT/source-final.manifest"
test "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(<"$VERIFY_ROOT/source-head-before")"
git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all > \
  "$VERIFY_ROOT/source-status-final"
/usr/bin/cmp -s "$VERIFY_ROOT/source-status-before" "$VERIFY_ROOT/source-status-final"
```

It prints `SOURCE VERIFICATION PASSED` only after both Swift commands, these
final comparisons, and CLAYGO cleanup succeed.

### Step 3: Add a root README with an explicit evidence ladder

Create a concise `README.md` that covers:

- Native macOS 14+ local-only freeware: no accounts/backend/sync; clipboard
  history remains removed; settings live in `UserDefaults`/Application Support.
- Architecture: SwiftUI application and feature surfaces, AppKit app/menu-bar
  integration, `AppState` plus services, the semantic design system, and the C
  `CThermal` target. State that `Package.swift` has no third-party packages.
- Canonical `./verify.sh --owner <thread/session-id> --minimum-free-kib
  <explicitly-approved-positive-value>` plus a direct
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
  /usr/bin/xcrun --sdk macosx swift test --scratch-path <owned path outside
  OneDrive> --filter <test-name>` focused-test path.
  Show the verifier's minimum-free-space argument as an explicit operator-owned
  value and state that Geraldine supplies no default.
  `build.sh` is packaging-oriented, not the source verifier.
- Four separate levels: source proof; explicitly authorized packaged-bundle
  proof; installed-path/provenance proof; and running-app interaction,
  performance, and accessibility proof. Each says it does not imply the next.
- Links to `HANDOFF.md`, `design-qa.md`, and `plans/README.md` with their narrow
  roles. Do not claim CI, installation, a current signed bundle, or live QA.

### Step 4: Make the handoff current and the design record honest

Replace `HANDOFF.md` with a short open-work-only document dated at execution.
It should contain current product invariants, the architecture/proof links a
new executor needs, and only work still open in `plans/README.md` after Plans
006-015. Link to the plan index rather than duplicating completed session
history. Preserve the local-only/no-clipboard boundary and the settled rule to
extend `Theme`, `Components`, `Motion`, `GeraldineMark`, and `EyeView`; do not
propose a generic system-monitor/AI-dashboard redesign before Geraldine's
personal identity brief exists.

Delete old snapshots/waves/bug claims, reboot/logout directions, process or
foreground checklists, and the speculative `MenuBarExtra` rewrite. A manual
`NSStatusItem` rewrite remains rejected absent a fresh installed reproduction.
Do not claim the primary checkout's uncommitted Dock-preview work exists in the
isolated branch; if it is still external, note only that shared user work must
not be overwritten.

Edit `design-qa.md` without recreating its test. Add a prominent statement that
it is a historical QA record, every listed `/tmp` capture was ephemeral and is
not available as durable/current evidence, and the recorded pass applies only
to that past comparison. Retain useful dimensions, states, and conclusions in
past tense, but change the final result to a clearly historical result with
current status unverified. Do not open Figma, fabricate screenshots, move a
missing file, or cite an ephemeral path as a current artifact.

### Step 5: Run deterministic gates and update only the plan status

Run the syntax/refusal checks, then exercise both post-registration cleanup
paths without staging or Swift work:

```zsh
run_cleanup_self_test() {
  mode="$1"
  case "$mode" in
    failure) expected_status=1 ;;
    term) expected_status=143 ;;
    *) return 1 ;;
  esac
  set +e
  output="$(./verify.sh --owner "$PLAN_OWNER" \
    --minimum-free-kib "$APPROVED_VERIFY_MIN_FREE_KIB" \
    --self-test-after-register "$mode" 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"
  test "$status" -eq "$expected_status"
  test "$(printf '%s\n' "$output" | /usr/bin/grep -Fxc "VERIFY_INTERNAL_CLOSEOUT=OK mode=$mode original_status=$expected_status")" -eq 1
  test "$(printf '%s\n' "$output" | /usr/bin/grep -c '^VERIFY_ROOT=')" -eq 1
  test "$(printf '%s\n' "$output" | /usr/bin/grep -c '^VERIFY_RECEIPT=')" -eq 1
  root="$(printf '%s\n' "$output" | /usr/bin/sed -n 's/^VERIFY_ROOT=//p')"
  receipt="$(printf '%s\n' "$output" | /usr/bin/sed -n 's/^VERIFY_RECEIPT=//p')"
  case "$root" in /private/tmp/geraldine-verify-*) ;; *) return 1 ;; esac
  case "$receipt" in /tmp/geraldine-verify-*-receipt.json) ;; *) return 1 ;; esac
  test ! -e "$root"
  test ! -e "$receipt"
  # Independent registry guard; this must not substitute for the internal marker.
  /Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
    --owner "$PLAN_OWNER" --finalize-disposable
}
run_cleanup_self_test failure
run_cleanup_self_test term
```

The failure call must return 1 and the TERM call 143 while each emits its exact
internal-closeout marker; the wrapper itself exits 0 only after proving exact
absence and an independent owner closeout. Then run `./verify.sh --owner
"$PLAN_OWNER" --minimum-free-kib "$APPROVED_VERIFY_MIN_FREE_KIB"` once.
Do not bypass its disk/concurrency gate. If another exact-name heavy build is
active, wait for the dispatcher to serialize this heavy command; do not inspect
broad command lines or stop another worker. After source verification, run:

```zsh
test -x verify.sh
! rg -n 'build\.sh|codesign|notarytool|stapler|/Applications/Geraldine\.app|osascript|killall|pkill|pgrep[[:space:]]+-a' verify.sh
for phrase in 'local-only' 'no accounts' 'source proof' 'packaged.*proof' 'installed.*proof' 'live.*proof'; do rg -qi "$phrase" README.md; done
for phrase in 'historical' 'ephemeral' 'not available' 'current.*unverified'; do rg -qi "$phrase" design-qa.md; done
! rg -n 'reboot|log out|MenuBarExtra|killall|pkill|sample <|pgrep -a' HANDOFF.md
git diff --check "$PLAN_BASE"
```

Expected: executable/static checks pass, README names all four proof levels,
the design record names its evidence limits, the stale handoff directives are
absent, and patch hygiene emits nothing. Inspect `git diff -- build.sh
Package.swift Sources Tests` and require no output.

Only then change Plan 016's status cell from its current `BLOCKED (...)` value
to `DONE`. Run the final scope allowlist and CLAYGO closeout command. No owned
scratch or receipt may remain. Do not install or launch for a
documentation/tooling plan.

```zsh
git diff "$PLAN_BASE" -- plans/README.md
test "$(git diff --numstat "$PLAN_BASE" -- plans/README.md | /usr/bin/awk '{print $1 " " $2}')" = '1 1'
test "$(rg -Fxc '| 016 | Add deterministic source verification and current documentation | P2 | M | 006-015, approved free-space gate | DONE |' plans/README.md)" -eq 1
```

## Test plan

Verification covers shell syntax and missing-argument refusal before allocation,
one complete staged source run with an explicitly approved free-space gate, the
full Swift suite, a separate clean release build, provenance output, cleanup on
normal/failure/interruption paths, documentation content gates, source/build
immutability, and the exact path allowlist. No installed or live surface is part
of this plan.

## Done criteria

- [ ] `verify.sh` stages only `Package.swift`, `Sources`, and `Tests` into one
      CLAYGO-owned root outside OneDrive, rejects symlinks, and preserves the
      same manifest before tests, before release, and after release.
- [ ] It reports Git/Xcode/Swift/SDK provenance, runs full tests and a separately
      clean release build with the explicit macOS 26.5 SDK, and exits 0.
- [ ] Its safe-space/exact-process preflight is fail closed without broad
      command-line inspection or a built-in/unapproved numeric limit.
- [ ] Success, controlled failure (status 1), and TERM (status 143) paths emit
      their internal-closeout marker, finalize the exact scratch root, and pass
      independent CLAYGO closeout plus exact absence.
- [ ] The verifier never signs, bundles, installs, launches, kills, foregrounds,
      calls `build.sh`, or writes generated files into the repository.
- [ ] Root README accurately describes product scope, architecture, commands,
      and the four non-interchangeable proof levels.
- [ ] `HANDOFF.md` contains current open work only, without stale reboot,
      process, `MenuBarExtra`, or historical session directives.
- [ ] `design-qa.md` labels missing `/tmp` captures and its pass result as
      historical; no evidence was fabricated, moved, or claimed current.
- [ ] The five-path allowlist passes, Plan 016 alone is `DONE`, and no install,
      launch, commit, or push ran.

## STOP conditions

Stop and report if:

- the package no longer consists of the manifest plus `Sources` and `Tests`, or
  verification requires resources not declared by `Package.swift`;
- an exact positive minimum-free-space value was not explicitly approved for
  this execution; never choose or infer one;
- the selected Xcode installation no longer contains `MacOSX26.5.sdk`, or xcrun
  resolves a different SDK and the change was not explicitly approved;
- deterministic proof requires changing `build.sh`, package/compiler settings,
  source, tests, signing, installation, app lifecycle, or product behavior;
- available disk is below the verifier gate or another exact-name heavy build
  remains active; do not clean or interrupt another owner's resources;
- CLAYGO cannot register, mark, finalize, close out, or prove absence of the
  verifier-owned root without weakening a safety check;
- current docs cannot distinguish source, packaged, installed, and live proof
  without claiming evidence that was not produced;
- any `/tmp` design capture is missing (expected historical state) and a caller
  asks this plan to recreate, move, or treat it as current evidence;
- `HANDOFF.md` drift reveals a fresh installed reproduction that materially
  changes the settled menu-bar decision;
- any verification fails twice after one reasonable, scoped correction, or a
  file outside scope appears necessary.

## Maintenance notes

Keep `verify.sh` source-only and non-installing. New SwiftPM inputs must be added
to its explicit stage list only when `Package.swift` declares them; do not turn
it into a packaging framework. Update README proof wording when a proof command
changes, and keep `HANDOFF.md` limited to unfinished work—Git history and plans
hold completed implementation history. Durable design evidence belongs in an
explicitly approved repository/evidence location; an ephemeral `/tmp` pathname
is never, by itself, a current artifact.
