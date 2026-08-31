# Plan 007: Make Dock action targeting exact and fail closed

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of improvising. When done,
> update Plan 007's status cell in `plans/README.md` unless your reviewer says it
> owns the index.
>
> **Do not execute this plan from the planning checkout shown below.** At plan
> time the Dock-window-preview lane is user-owned, modified/untracked work. The
> operator must first commit that complete lane or hand it off into the clean
> executor base. The prerequisite gate below must pass before any source edit.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/PowerTools.swift Tests/GeraldineTests/DockTargetResolutionTests.swift`
> `PowerTools.swift` is expected to differ from `7b6fa41` because the required
> Dock-preview lane must be in the executor base. If it does not differ, STOP:
> the prerequisite lane is missing. If the live `DockTarget`, event-handler, or
> shared-matcher shapes differ semantically from the excerpts below, STOP and
> report the drift rather than rebuilding a weaker resolver.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: the complete Dock-window-preview lane committed or handed off
  into the executor base (required; no numbered plan)
- **Category**: security, bug, tests
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

The current Dock action path converts an Accessibility title, description, or
help string into the first running application with a matching name. Two apps
can share that visible name, and a configured middle-click action can terminate
the wrongly selected app. The in-progress Dock-preview lane already establishes
the stronger product invariant: a Dock item URL is canonical identity; a label
is only a fallback when it identifies exactly one running candidate; stale or
ambiguous identity fails closed. This plan makes Dock click actions reuse that
exact policy and preserves the existing event pass-through whenever targeting
is unsupported or uncertain.

## Current state

- `Sources/Geraldine/Services/PowerTools.swift` owns the global Dock click event
  tap, all custom Dock effects, and the weaker `DockTarget` resolver.
- `Sources/Geraldine/Services/DockWindowPreviewModel.swift` is currently an
  untracked, user-owned file. Its `DockPreviewApplicationMatching` policy is the
  identity authority this plan must reuse after the complete lane is committed.
- `Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift` is currently
  an untracked, user-owned file. Its current `target(at:dockProcessIdentifier:
  candidates:)` implementation finds the containing `AXApplicationDockItem`,
  obtains its file URL, and invokes the shared matcher. Prefer direct reuse of
  that complete resolver; do not reimplement its ancestor traversal or matching
  in `PowerTools.swift`.
- `Tests/GeraldineTests/DockWindowPreviewTests.swift` is currently an untracked,
  user-owned file. It already characterizes exact URL, stale URL, unique label,
  and ambiguous-label behavior for the shared matcher.
- `Tests/GeraldineTests/DockActiveClickBehaviorTests.swift` is the committed
  pure-policy XCTest style exemplar. Match its direct inputs, explicit cases,
  and absence of live Accessibility/event-tap dependencies.

Current event ownership (`PowerTools.swift:523-538` in the planning tree):

```swift
private func handle(type: CGEventType, event: CGEvent) -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: PowerToolKeys.dockActionsEnabled),
          let target = DockTarget.target(at: event.location) else {
        return false
    }

    if type == .otherMouseDown, event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
        // ... resolve the configured behavior ...
        DispatchQueue.main.async {
            Self.performMiddleClick(behavior, app: target.app)
        }
        return true
    }
```

`false` is load-bearing: the event is returned to macOS unchanged. An unknown,
unsupported, stale, or ambiguous target must continue to take this path, must
queue no effect, and must never be swallowed.

The highest-impact effect (`PowerTools.swift:579-590`):

```swift
private static func performMiddleClick(_ behavior: DockMiddleClickBehavior,
                                       app: NSRunningApplication) {
    switch behavior {
    // ...
    case .quitApp:
        app.terminate()
    }
}
```

The weak resolver (`PowerTools.swift:595-630`):

```swift
private struct DockTarget {
    let app: NSRunningApplication

    static func target(at point: CGPoint) -> DockTarget? {
        guard let element = AXTools.element(at: point),
              let app = AXTools.runningApplication(for: element),
              app.bundleIdentifier == "com.apple.dock" else {
            return nil
        }

        let title = AXTools.string(element, kAXTitleAttribute) ??
            AXTools.string(element, kAXDescriptionAttribute) ??
            AXTools.string(element, kAXHelpAttribute)
        guard let title, !title.isEmpty else { return nil }

        if title == "Finder",
           let finder = NSRunningApplication.runningApplications(
               withBundleIdentifier: "com.apple.finder"
           ).first {
            return DockTarget(app: finder)
        }

        let cleanedTitle = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let target = NSWorkspace.shared.runningApplications.first(where: { running in
            guard running.activationPolicy == .regular ||
                    running.bundleIdentifier == "com.apple.finder" else { return false }
            if running.localizedName == cleanedTitle { return true }
            if running.bundleURL?.deletingPathExtension().lastPathComponent == cleanedTitle {
                return true
            }
            return false
        }) else {
            return nil
        }
        return DockTarget(app: target)
    }
}
```

The required shared policy from the user-owned Dock-preview lane
(`DockWindowPreviewModel.swift:70-90` in the planning tree):

```swift
enum DockPreviewApplicationMatching {
    /// A Dock URL is stronger evidence than its label. Never select a different
    /// app with the same name when the URL is present but no longer running.
    static func processIdentifier(
        itemURL: URL?, title: String, candidates: [DockPreviewApplicationCandidate]
    ) -> pid_t? {
        let matches: [DockPreviewApplicationCandidate]
        if let itemURL {
            let path = itemURL.standardizedFileURL.resolvingSymlinksInPath().path
            matches = candidates.filter {
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
            }
        } else {
            let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            matches = candidates.filter {
                $0.name == label ||
                    $0.bundleURL?.deletingPathExtension().lastPathComponent == label
            }
        }
        return matches.count == 1 ? matches.first?.processIdentifier : nil
    }
}
```

This policy deliberately does **not** fall back to a name when a Dock URL is
present but stale, and deliberately rejects two matches. Those are security
boundaries, not convenience behavior.

Pure-policy test style (`DockActiveClickBehaviorTests.swift:4-23`):

```swift
final class DockActiveClickInterceptionPolicyTests: XCTestCase {
    func testSystemBehaviorNeverIntercepts() {
        XCTAssertFalse(DockActiveClickInterceptionPolicy.shouldIntercept(
            behavior: .system,
            targetIsFrontmost: true,
            hasVisibleWindow: { true }
        ))
    }

    func testCustomBehaviorInterceptsVisibleFrontmostWindow() {
        for behavior in [
            DockActiveClickBehavior.hideApp,
            .minimizeWindows,
            .cycleWindows
        ] {
            XCTAssertTrue(DockActiveClickInterceptionPolicy.shouldIntercept(
                behavior: behavior,
                targetIsFrontmost: true,
                hasVisibleWindow: { true }
            ))
        }
    }
}
```

## Commands you will need

The selected Xcode toolchain currently exposes the macOS 26.5 SDK at the exact
path below. Use this explicit SDK for every Swift test in this plan; do not let
a shell-default SDK silently change the verification surface.

| Purpose | Command | Expected on success |
|---|---|---|
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5" && test -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk` | exit 0 |
| Required lane tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN007_ROOT/swiftpm" --filter DockPreviewApplicationMatchingTests` | exit 0; all shared matcher tests pass |
| Focused tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN007_ROOT/swiftpm" --filter DockTargetResolutionTests` | exit 0; all new tests pass |
| Existing Dock policy | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN007_ROOT/swiftpm" --filter DockActiveClickInterceptionPolicyTests` | exit 0; all existing tests pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN007_ROOT/swiftpm"` | exit 0; full suite passes |
| Patch hygiene | `git diff --check` | exit 0, no output |

### CLAYGO ownership and plan-base capture

Before any test or temporary output, replace the owner placeholder with the
current executor thread/session ID, then run this block. The guard intentionally
fails if the placeholder was not replaced. Do not register the repository or
the user's checkout as a disposable path.

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

PLAN007_OWNER='<current-thread-or-session-id>'
test "$PLAN007_OWNER" != '<current-thread-or-session-id>'
PLAN007_ROOT="/private/tmp/geraldine-plan-007-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN007_RECEIPT="/tmp/$(basename "$PLAN007_ROOT")-receipt.json"
test ! -e "$PLAN007_ROOT"
test ! -e "$PLAN007_RECEIPT"

/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN007_ROOT" \
  --temp-root /private/tmp \
  --receipt "$PLAN007_RECEIPT" \
  --owner "$PLAN007_OWNER" \
  --purpose "Geraldine Plan 007 focused and full SwiftPM tests" \
  --profile swiftpm
```

The dispatcher owns the isolated checkout and its lifecycle. The Plan 007
executor must not create, register, finalize, or remove that checkout. Never
adopt or reclassify a user-owned checkout or another worker's worktree.

### Required Dock-preview lane gate

Run this after CLAYGO initialization and before recording the executor base.
Every path must be tracked and clean in the executor checkout. This is the
mechanical proof that the user-owned lane was committed/handed off rather than
edited in place by this plan.

```sh
lane_paths=(
  Sources/Geraldine/Features/PowerTools/PowerToolsView.swift
  Sources/Geraldine/Services/Permissions.swift
  Sources/Geraldine/Services/PowerTools.swift
  build.sh
  Sources/Geraldine/Features/PowerTools/DockWindowPreviewView.swift
  Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift
  Sources/Geraldine/Services/DockWindowPreviewModel.swift
  Sources/Geraldine/Services/DockWindowPreviewService.swift
  Tests/GeraldineTests/DockWindowPreviewTests.swift
)
git ls-files --error-unmatch "${lane_paths[@]}"
test -z "$(git status --short -- "${lane_paths[@]}")"
rg -n 'enum DockPreviewApplicationMatching|static func processIdentifier' \
  Sources/Geraldine/Services/DockWindowPreviewModel.swift
rg -n 'static func target\(' \
  Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift
test "$(git rev-parse HEAD)" != "$(git rev-parse 7b6fa41)"
test -z "$(git status --short -- Sources Tests)"
git rev-parse HEAD > "$PLAN007_ROOT/executor-base"
```

Expected result: every command exits 0; the `rg` commands print the committed
shared matcher and shared target entry point; `Sources` and `Tests` are clean.
If any command fails, STOP without editing.

Then run the SDK gate and required-lane focused test from the command table.
Both must pass before Step 1.

### Closeout scope guard

Run before CLAYGO finalization. It covers committed, staged, unstaged, and
untracked changes since the captured executor base:

```sh
test -s "$PLAN007_ROOT/executor-base"
PLAN007_BASE="$(<"$PLAN007_ROOT/executor-base")"
set -e
set -o pipefail
git cat-file -e "$PLAN007_BASE^{commit}"
test "$(git rev-parse HEAD)" = "$PLAN007_BASE"
unstaged="$(git diff --name-only "$PLAN007_BASE" -- .)"
staged="$(git diff --cached --name-only "$PLAN007_BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "Sources/Geraldine/Services/PowerTools.swift" && $0 != "Tests/GeraldineTests/DockTargetResolutionTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

Expected result: exit 0 and `unexpected` is empty. Also inspect
`git diff "$PLAN007_BASE" -- plans/README.md`; only Plan 007's status cell may
change. If the row is absent, STOP and ask the index owner to add it rather than
rewriting the index.

## Scope

**In scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Tests/GeraldineTests/DockTargetResolutionTests.swift` (create)
- `plans/README.md` (Plan 007 status cell only, during execution)

**Out of scope**:

- Every current Dock-preview lane file, including
  `DockWindowPreviewModel.swift`, `DockWindowPreviewAccessibility.swift`,
  `DockWindowPreviewService.swift`, `DockWindowPreviewView.swift`, and
  `DockWindowPreviewTests.swift`. They are committed prerequisites and must not
  be changed by this plan.
- `PowerToolsView.swift`, `Permissions.swift`, and `build.sh`; preserve the
  handed-off lane byte-for-byte.
- Changes to Dock behavior choices, preference keys/defaults, event masks,
  Accessibility or Screen Recording permission flows, window previews, active
  click policy, middle-click effects, Finder behavior, or global keyboard
  policy.
- Plan 004's async Power Tools effects and Plan 005's keyboard reducer. They
  also edit `PowerTools.swift`; execute these plans serially and perform a fresh
  drift review instead of combining scopes.
- App installation, launching Geraldine, requesting permissions, creating a
  live event tap, synthetic input, interacting with the Dock, signing,
  notarization, pushing, or opening a PR.
- Repository cleanup, `.jj`, user data, installed applications, and any
  unrelated dirty/shared work.

No extra source file is justified: the committed Dock-preview lane already
contains the exact resolver and matcher this plan needs.

## Git workflow

- Work only in a clean executor checkout whose `HEAD` passes the complete
  Dock-preview lane gate above. Never edit the user's currently dirty planning
  checkout.
- Branch: `codex/007-fail-closed-dock-action-targeting`.
- Use one imperative commit such as `Harden Dock action targeting` if the
  operator requested a commit. Do not commit unrelated handed-off work.
- Do not push, open a PR, merge, install, or launch unless separately and
  explicitly instructed.

## Steps

### Step 1: Replace the name-first Dock resolver with the committed exact resolver

In `PowerTools.swift`, keep `DockTarget` as the action-layer wrapper that holds
an `NSRunningApplication`, but replace its current AX title extraction,
Finder-name special case, title cleanup, and `runningApplications.first(where:)`
lookup.

Delegate target resolution to the committed Dock-preview lane:

1. obtain the current Dock process identifier through
   `DockWindowPreviewAccessibility.dockProcessIdentifier()`;
2. obtain the current eligible running candidates through
   `DockWindowPreviewAccessibility.applicationCandidates()`;
3. call `DockWindowPreviewAccessibility.target(at:dockProcessIdentifier:
   candidates:)` with the `CGEvent` point; and
4. wrap only the exact live application returned by that shared resolver.

The shared resolver already finds the containing application Dock item, uses
its file URL when present, calls `DockPreviewApplicationMatching`, rejects a
stale URL instead of falling back to a label, and requires exactly one label
match when no URL exists. Do not copy those checks into `PowerTools.swift`, do
not retain the `title == "Finder"` shortcut, and do not add a secondary fallback
after the shared resolver returns `nil`.

Keep all calls synchronous in the existing event callback for this narrow
change. Async extraction belongs to Plan 004 and must not be mixed into this
security fix.

**Verify**:

```sh
dock_target_slice="$(sed -n '/private struct DockTarget/,/^}/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$dock_target_slice" | rg -c 'DockWindowPreviewAccessibility\.target')" -eq 1
test "$(printf '%s\n' "$dock_target_slice" | rg -c 'DockWindowPreviewAccessibility\.applicationCandidates')" -eq 1
test -z "$(printf '%s\n' "$dock_target_slice" | rg 'first\(where:|localizedName ==|title == "Finder"|deletingPathExtension\(\)\.lastPathComponent ==' || true)"
```

Expected result: exit 0; the wrapper calls the shared exact resolver once and
contains none of the old name-first matching paths.

### Step 2: Preserve fail-closed event ownership

Review only `DockInteractionService.handle(type:event:)` in `PowerTools.swift`.
The pre-effect guard must still return `false` whenever `DockTarget.target(at:)`
returns `nil`. Do not move any active-click or middle-click effect ahead of that
guard. Do not change the meaning of the handler's `Bool`: `true` still means
Geraldine performed an authorized custom action and consumes the event;
`false` still means macOS receives the original event unchanged.

Specifically preserve:

- disabled Dock actions pass through;
- unsupported Dock elements pass through;
- stale URL identity passes through;
- duplicate canonical-URL candidates pass through;
- duplicate name-only candidates pass through;
- unknown/empty identity passes through; and
- all existing exact-target effects and their dispatch timing remain unchanged.

Do not add user-facing warnings from the event callback; silent pass-through is
the safe fallback and matches existing behavior.

**Verify**:

```sh
handle_slice="$(sed -n '/private func handle(type: CGEventType, event: CGEvent)/,/^    }$/p' Sources/Geraldine/Services/PowerTools.swift)"
test "$(printf '%s\n' "$handle_slice" | rg -c 'let target = DockTarget\.target')" -eq 1
test "$(printf '%s\n' "$handle_slice" | rg -c 'return false')" -ge 3
test "$(printf '%s\n' "$handle_slice" | rg -c 'performMiddleClick')" -eq 1
test "$(printf '%s\n' "$handle_slice" | rg -c 'performActiveClick')" -eq 1
```

Expected result: exit 0; one target guard remains ahead of the unchanged active
and middle effects, with pass-through exits intact.

### Step 3: Add action-specific regression tests over the shared pure policy

Create `Tests/GeraldineTests/DockTargetResolutionTests.swift` with `XCTest` and
`@testable import Geraldine`. Use only value candidates and the committed
`DockPreviewApplicationMatching.processIdentifier` policy. Do not construct a
`CGEvent`, invoke Accessibility, inspect the real Dock, start Geraldine, or
create an event tap.

Name the test class `DockTargetResolutionTests` and cover at least:

- an exact canonical Dock URL selects the correct PID among two identically
  named running candidates;
- two candidates with the same canonical bundle URL return `nil`;
- a present but stale/non-running Dock URL returns `nil` even when its label
  matches another running app;
- no URL plus two matching labels returns `nil`;
- no URL plus one matching label returns that PID;
- an empty or whitespace-only label with no URL returns `nil`; and
- an unsupported candidate set returns `nil`.

Use obviously fake paths and PIDs. Assert returned PIDs or `nil`; do not inspect
or terminate any live application. These tests intentionally overlap the shared
matcher's general tests: their names preserve the action-layer safety contract
so a future resolver refactor cannot claim preview correctness while weakening
click behavior.

**Verify**: run the focused `DockTargetResolutionTests` command from the command
table. Expected result: exit 0 and all new tests pass.

### Step 4: Run the complete source-level gate and scoped local review

Run, in order, using the registered `PLAN007_ROOT`:

1. the required `DockPreviewApplicationMatchingTests` command;
2. the new `DockTargetResolutionTests` command;
3. the existing `DockActiveClickInterceptionPolicyTests` command;
4. the full Swift test command; and
5. `git diff --check`.

Then run the Step 1 and Step 2 static gates again and perform a scoped local
review:

```sh
PLAN007_BASE="$(<"$PLAN007_ROOT/executor-base")"
git diff --stat "$PLAN007_BASE" -- \
  Sources/Geraldine/Services/PowerTools.swift \
  Tests/GeraldineTests/DockTargetResolutionTests.swift \
  plans/README.md
git diff "$PLAN007_BASE" -- \
  Sources/Geraldine/Services/PowerTools.swift \
  Tests/GeraldineTests/DockTargetResolutionTests.swift \
  plans/README.md
```

The review must confirm every source hunk implements this plan, the shared
resolver is called rather than copied, ambiguous identity reaches `return
false`, no effect or dispatch semantics changed, the tests are pure, and only
Plan 007's README status cell changed. If a review-triggered correction changes
code, rerun all three focused filters, the full suite, static gates, patch
hygiene, and review.

Finally run the closeout scope guard. Do not substitute live Dock interaction
for the pure and source-level proof in this plan.

### Step 5: Finalize task-owned temporary resources

After every verification and review is complete and its proof is preserved in
the task transcript, finalize only the registered SwiftPM root:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN007_RECEIPT" \
  --state disposable \
  --reason "Plan 007 tests and scoped review completed; proof is in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN007_RECEIPT" \
  --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN007_OWNER" \
  --finalize-disposable
test ! -e "$PLAN007_ROOT"
test ! -e "$PLAN007_RECEIPT"
```

Expected result: each command exits 0, the exact `PLAN007_ROOT` is absent, and
no resource owned by `PLAN007_OWNER` remains unexplained as active, evidence, or
disposable. Do not use CLAYGO on source, the user's dirty checkout, installed
apps, credentials, logs, `.jj`, or another task's resources.

## Test plan

`DockTargetResolutionTests.swift` is the new regression file and contains the
seven action-sensitive matcher cases listed in Step 3. Match the concise
XCTest structure in `DockActiveClickBehaviorTests.swift`; use the existing
`DockPreviewApplicationMatchingTests` as the semantic oracle for URL precedence
and fail-closed ambiguity.

Verification layers are intentionally separate:

- new pure tests prove the Dock action identity contract without OS state;
- existing preview matcher tests prove the shared policy remains intact;
- existing active-click tests protect event interception policy;
- static gates prove `DockTarget` actually delegates to the shared resolver and
  no name-first fallback remains; and
- the full suite catches module-level regressions.

No test in this plan may request Accessibility or Screen Recording, inspect the
real Dock, start an event tap, synthesize input, launch Geraldine, terminate an
app, or alter `UserDefaults.standard`.

## Done criteria

- [ ] The complete Dock-preview lane is tracked, clean, and included in the
      executor base before any Plan 007 source edit.
- [ ] `DockTarget` delegates to the committed shared exact resolver and contains
      no first-match title lookup, Finder-name special case, or secondary
      fallback.
- [ ] Canonical URL identity outranks labels; stale URLs and all ambiguous or
      unsupported identities resolve to `nil`.
- [ ] A `nil` target still returns `false` from the event handler before any
      effect is queued, so macOS receives the original event.
- [ ] Active-click and middle-click choices, effects, dispatch timing,
      preferences, and event masks are unchanged.
- [ ] `DockTargetResolutionTests`, `DockPreviewApplicationMatchingTests`, and
      `DockActiveClickInterceptionPolicyTests` all pass under the explicit macOS
      26.5 SDK.
- [ ] The full Swift suite passes under the same SDK.
- [ ] Step 1 and Step 2 static gates and `git diff --check` exit 0.
- [ ] The closeout scope guard reports no out-of-scope source, test, or index
      path.
- [ ] Scoped local review finds no accepted/actionable issue; any correction is
      followed by the complete verification loop.
- [ ] Only Plan 007's status cell changes in `plans/README.md`.
- [ ] CLAYGO finalization verifies the exact task-owned test root is absent and
      owner closeout succeeds.
- [ ] No app was installed/launched, no live event tap or permission request was
      made, and nothing was pushed or published.

## STOP conditions

Stop and report instead of improvising if:

- any Dock-preview lane path in the prerequisite gate is untracked, modified,
  staged, missing, or absent from the executor base;
- `PowerTools.swift` is still the user-owned dirty planning copy rather than a
  clean committed/handoff base;
- the committed lane no longer contains
  `DockPreviewApplicationMatching.processIdentifier` with canonical URL
  precedence, unique-candidate matching, and stale/ambiguous fail-closed
  behavior;
- `DockWindowPreviewAccessibility.target(at:dockProcessIdentifier:candidates:)`
  is unavailable or does not use that exact shared policy;
- satisfying the fix appears to require editing any Dock-preview prerequisite
  file, permission flow, view, preference, event mask, effect, or plan other
  than Plan 007's README status cell;
- the resolver would need to fall back from a present but stale URL to a label,
  accept multiple candidates, or guess Finder by display text;
- ambiguous or unsupported identity cannot return `false` before effect
  dispatch without changing event semantics;
- the selected macOS SDK is not 26.5, or a focused/full verification fails
  twice after one reasonable in-scope correction;
- a correct test would require Accessibility, Screen Recording, a real Dock,
  a live event tap, synthetic input, app launch/termination, or mutation of
  global user preferences;
- `plans/README.md` has no Plan 007 row or updating status would touch more than
  its status cell;
- the scope guard finds an out-of-scope path, or CLAYGO reports an ownership,
  open-file, finalization, or closeout problem; or
- Plan 004, Plan 005, or concurrent work has semantically reshaped the same
  resolver/handler region beyond the excerpts in this plan.

## Maintenance notes

There must be one Dock application identity policy, even though preview and
action features consume it differently. Future changes must preserve URL-first
canonical identity, unique-candidate name fallback, and fail-closed behavior;
never add a convenience fallback only to Dock actions. Reviewers should reject
any return to `runningApplications.first(where:)` by display name because
middle-click can terminate the selected process.

Plans 004 and 005 also modify `PowerTools.swift`; keep them serial and rerun
this plan's focused tests after either lands. If the preview lane later renames
its types, migrate both consumers to a neutrally named shared resolver in one
explicitly scoped plan rather than keeping duplicate matchers. Live Dock
interaction remains deliberately deferred: this plan proves identity and event
ownership without disturbing the user's desktop or requesting privileged
access.
