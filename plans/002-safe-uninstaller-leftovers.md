# Plan 002: Contain and qualify Uninstaller leftover paths

> **Executor instructions**: Follow each step and verification gate. Stop and
> report any STOP condition; do not broaden matching to make tests pass. Update
> Plan 002's status in `plans/README.md` when complete unless a reviewer owns
> the index.
>
> **Drift check (run first)**:
> `git diff --stat c8aeca4 -- Sources/Geraldine/Features/Uninstaller/UninstallerViewModel.swift Tests/GeraldineTests/UninstallerLeftoverDiscoveryTests.swift`
> If the source file changed, compare live discovery and preselection code with
> the excerpts below. A semantic mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-safe-trash-boundary.md`
- **Category**: security, bug, tests
- **Planned at**: commit `c8aeca4`, 2026-07-15

## Why this matters

Uninstaller accepts raw bundle metadata from any `.app` in system or user
Applications folders, appends the bundle identifier and display name as path
components, substring-matches LaunchAgent filenames, and preselects every
result. A malformed identifier can escape an intended Library subdirectory;
a generic app name can claim unrelated support files. The fix must make bundle
identity validation, canonical containment, match confidence, and default
selection explicit while preserving review-first uninstall behavior.

## Current state

- `UninstallerViewModel` discovers app metadata and protects Apple/system apps.
- `LeftoversModel.findLeftovers` builds Library candidates and returns
  `ScanGroup`s consumed by the existing review sheet.
- `ScanGroup.safeByDefault` already distinguishes default-selected and
  review-only groups; use it instead of adding a second selection model.
- Existing pure identity tests live in
  `Tests/GeraldineTests/LaunchItemIdentityTests.swift`.

Current discovery (`UninstallerViewModel.swift:103-169`):

```swift
self.selection = report.groups.allItemIDs

let ids = [app.bundleID, app.name].filter { !$0.isEmpty }
for key in ids {
    add("Application Support", key)
    add("Caches", key)
    // ...
}
for a in agents where ids.contains(where: { a.lastPathComponent.contains($0) }) {
    candidates.append(a)
}
```

The app bundle itself remains selected by default. Exact, validated bundle-ID
matches may be selected by default. Display-name-only matches are lower
confidence and must be presented unselected in a separate review group.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Prerequisite | `git ls-files --error-unmatch Tests/GeraldineTests/TrashServiceTests.swift && git diff --quiet HEAD -- Sources/Geraldine/Services/TrashService.swift Tests/GeraldineTests/TrashServiceTests.swift && git diff --cached --quiet HEAD -- Sources/Geraldine/Services/TrashService.swift Tests/GeraldineTests/TrashServiceTests.swift && swift test --scratch-path /tmp/geraldine-plan-002-prerequisite --filter TrashServiceTests` | exit 0; committed base contains completed Plan 001 |
| Focused tests | `swift test --scratch-path /tmp/geraldine-plan-002-tests --filter UninstallerLeftoverDiscoveryTests` | exit 0; all new tests pass |
| Full tests | `swift test --scratch-path /tmp/geraldine-plan-002-full` | exit 0 |
| Hygiene | `git diff --check` | exit 0, no output |

**User-patch guard (run before and after implementation):**

```sh
test "$(git diff -- Sources/Geraldine/MenuBar/MetricWidgets.swift | shasum -a 256 | cut -d ' ' -f 1)" = da9ee6c4eafd807623c825613e33929a61f9966d00981be10ca9f8739c56c5c3
```

**Plan-base and scope guard:** after the prerequisite command and before any
edit, run:

```sh
git rev-parse HEAD > /tmp/geraldine-plan-002-base
unexpected="$({ git diff --name-only HEAD -- Sources Tests; git diff --cached --name-only HEAD -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

If the base file goes missing after edits, STOP. At closeout run:

```sh
test -s /tmp/geraldine-plan-002-base
unexpected="$({ git diff --name-only "$(</tmp/geraldine-plan-002-base)" -- Sources Tests; git diff --cached --name-only "$(</tmp/geraldine-plan-002-base)" -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/Features/Uninstaller/UninstallerViewModel\.swift$' -e '^Tests/GeraldineTests/UninstallerLeftoverDiscoveryTests\.swift$' -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Features/Uninstaller/UninstallerViewModel.swift`
- `Tests/GeraldineTests/UninstallerLeftoverDiscoveryTests.swift` (create)
- `plans/README.md` (Plan 002 status cell only)

**Out of scope**:

- `UninstallerView.swift` layout, confirmation wording, and result UI.
- Broader cleanup scanning or Trash behavior; Plan 001 owns that boundary.
- Searching the whole disk, parsing arbitrary vendor receipts, or adding an
  online application-signature database.
- Automatically deleting low-confidence display-name matches.
- The user-owned `MetricWidgets.swift` patch and jj metadata.

## Git workflow

- Start only from a commit where Plan 001 is complete and its focused tests
  pass; do not carry uncommitted Plan 001 source edits into this plan.
- Branch: `codex/002-safe-uninstaller-leftovers`, created from that verified
  prerequisite commit.
- Use an imperative commit such as `Contain Uninstaller leftover discovery`.
- Do not push or open a PR unless explicitly instructed.

## Steps

### Step 1: Extract a pure, testable leftover locator

Inside `UninstallerViewModel.swift`, introduce an internal value describing a
candidate URL and its match confidence (`bundleIdentifier` or `displayName`),
plus `LaunchAgentEntry { url: URL, label: String? }`. Extract an internal pure
locator that accepts explicit app identity, Library root, and already-parsed
`LaunchAgentEntry` values. The filesystem wrapper in `findLeftovers` enumerates
plist URLs and parses a string `Label` before invoking the locator; malformed,
unreadable, or non-string labels become `nil`, but exact-basename matching may
still apply. Size measurement also remains outside the pure locator.

Extract a second internal pure report builder that accepts the application
`ScanItem` plus located candidates with confidence and returns the exact
production `ScanGroup` array (or `ScanReport`) consumed by `scan()`. Production
`findLeftovers` must call this builder after size measurement. Tests must call
the same internal builder directly to assert grouping and `defaultSelection`;
they must not invoke private `scan()` or touch the real `~/Library`.

Bundle identifiers are eligible only when they contain at least two nonempty
dot-separated components and every character is ASCII alphanumeric, `-`, or
`.`. Reject separators, empty components, `.`/`..`, leading/trailing dots, and
all other characters. A display name used as a leaf must be nonempty, must not
equal `.` or `..`, and must contain no `/`, `:`, or NUL scalar. Unicode and
leading/trailing whitespace are allowed and preserved exactly. Canonical
containment remains mandatory even after this validation.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-002-tests --filter UninstallerLeftoverDiscoveryTests`
must compile.

### Step 2: Enforce canonical containment per intended root

For each supported relative root (`Application Support`, `Caches`,
`Containers`, `HTTPStorages`, `LaunchAgents`, `Logs`, `Preferences`,
`Saved Application State`, `WebKit`, and `Group Containers`), canonicalize the
root and proposed child and require strict path-component ancestry. Do not use
a raw path-string prefix. Reject a candidate that resolves to the root itself
or outside it.

For LaunchAgents, match a validated bundle identifier by exact plist basename
without `.plist` and/or by an exactly equal plist `Label`. Remove substring
matching and never use the display name to wildcard LaunchAgents.

**Verify**:
`rg -n 'lastPathComponent\.contains|contains\(\$0\)' Sources/Geraldine/Features/Uninstaller/UninstallerViewModel.swift`
returns no discovery-match occurrence.

### Step 3: Separate confidence groups and safe defaults

Keep the application bundle in an `Application` group with
`safeByDefault: true`. Put exact validated bundle-ID leftovers in a safe-default
group. Put display-name-only candidates in a clearly named possible-leftovers
group with `safeByDefault: false` so the user may opt in after review.

Set initial selection to `report.groups.defaultSelection`, not `allItemIDs`.
Preserve deduplication so a path matched by both mechanisms appears once at the
higher confidence.

**Verify**:
`rg -n 'selection = report\.groups\.allItemIDs' Sources/Geraldine/Features/Uninstaller/UninstallerViewModel.swift`
returns no matches.

### Step 4: Add focused discovery tests

Create `UninstallerLeftoverDiscoveryTests.swift` and cover:

- a normal reverse-DNS bundle ID yields contained exact candidates;
- identifiers containing `/`, `..`, empty segments, or a single generic token
  yield no bundle-ID candidates;
- display names that are empty, `.`, `..`, or contain `/`, `:`, or NUL yield no
  name candidates, while safe Unicode and edge whitespace remain exact;
- a crafted identifier cannot escape any supplied root after canonicalization;
- a broad app display name does not match unrelated LaunchAgents;
- exact LaunchAgent basename and exact plist Label matches are accepted;
- a basename/Label-matched LaunchAgent URL that lexically or symlink-resolves
  outside the supplied `LaunchAgents` root is rejected;
- display-name-only candidates are low confidence and not selected by default;
- an app bundle plus exact bundle-ID leftovers remain selected by default;
- a path matched twice is emitted once with the stronger confidence.

Use temporary roots only. Make locator inputs deterministic; do not scan the
developer's real `~/Library` in tests.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-002-tests --filter UninstallerLeftoverDiscoveryTests`
passes all cases.

### Step 5: Run the full gate

**Verify**:

- `swift test --scratch-path /tmp/geraldine-plan-002-full` exits 0.
- `git diff --check` exits 0.
- the scope allowlist emits no output, and the recorded `MetricWidgets.swift`
  diff hash is unchanged.

## Test plan

The mandatory cases appear in Step 4. Follow the compact XCTest style in
`LaunchItemIdentityTests`; use helper factories rather than real installed app
bundles. Assert URLs, confidence, grouping, and default selection separately so
a later regression points to the failed invariant.

## Done criteria

- [ ] Untrusted bundle metadata never escapes an intended canonical root.
- [ ] LaunchAgent matching is exact and bundle-ID based, never a broad substring.
- [ ] Display-name-only candidates are reviewable but unselected.
- [ ] Crafted identity, containment, match-confidence, deduplication, and
      default-selection tests pass.
- [ ] Full Swift tests and `git diff --check` pass.
- [ ] Only in-scope source/test files changed.
- [ ] The pre-existing `MetricWidgets.swift` diff hash is unchanged.
- [ ] Plan 002's README status is updated.

## STOP conditions

Stop and report if:

- a shipping app requires an invalid bundle identifier and preserving its
  behavior would weaken containment;
- distinguishing exact and possible leftovers requires changing public UI or
  data models outside scope;
- current code has drifted from the excerpts;
- Plan 001 is not complete;
- a verification fails twice or an out-of-scope file appears necessary.

## Maintenance notes

New leftover locations must declare their intended root and confidence. Never
restore display-name substring matching for convenience. Reviewers should try
malformed Info.plist values, generic app names, and symlinked Library paths.
