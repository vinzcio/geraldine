# Plan 003: Preserve Finder selections as structured URLs

> **Executor instructions**: Follow this plan exactly and run each verification
> gate. Stop rather than substituting another delimiter. Update Plan 003's row
> in `plans/README.md` when complete unless a reviewer owns the index.
>
> **Drift check (run first)**:
> `git diff --stat c8aeca4 -- Sources/Geraldine/Services/PowerTools.swift Tests/GeraldineTests/FinderSelectionDescriptorTests.swift`
> Compare any changed Finder selection code with the excerpt below; mismatch is
> a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug, tests
- **Planned at**: commit `c8aeca4`, 2026-07-15

## Why this matters

Finder selections currently cross the AppleScript boundary as newline-delimited
text. Newlines are valid in macOS filenames, so one selected item can become
multiple bogus URLs that later drive checksum, copy, move, cut, and paste
operations. AppleScript already returns structured Apple-event descriptors;
this plan preserves the list structure to the `[URL]` boundary and tests the
edge case directly.

## Current state

- `FinderPowerToolsService.selectedFileURLs()` is the single selection source
  for path copy, checksums, destination transfer, and cut sessions.
- `PowerToolsController` and keyboard callbacks already invoke Finder work on
  the main actor/main queue. Keep AppleScript execution there.
- The text copied by “Copy Paths” may remain newline-separated for human use;
  the bug is reparsing Finder selection text into operation targets.

Current transport (`PowerTools.swift:793-808`):

```swift
set output to ""
repeat with selectedItem in selectedItems
    set output to output & POSIX path of selectedItem & linefeed
end repeat
return output
// ...
return result.output
    .split(separator: "\n")
    .map { URL(fileURLWithPath: String($0)) }
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Focused tests | `swift test --scratch-path /tmp/geraldine-plan-003-tests --filter FinderSelectionDescriptorTests` | exit 0 |
| Full tests | `swift test --scratch-path /tmp/geraldine-plan-003-full` | exit 0 |
| Old transport | `rg -n -F '.split(separator: "\n")' Sources/Geraldine/Services/PowerTools.swift` | exit 1, no output |
| Hygiene | `git diff --check` | exit 0 |

**User-patch guard (run before and after implementation):**

```sh
test "$(git diff -- Sources/Geraldine/MenuBar/MetricWidgets.swift | shasum -a 256 | cut -d ' ' -f 1)" = da9ee6c4eafd807623c825613e33929a61f9966d00981be10ca9f8739c56c5c3
```

**Plan-base and scope guard:** before editing, run:

```sh
git rev-parse HEAD > /tmp/geraldine-plan-003-base
unexpected="$({ git diff --name-only HEAD -- Sources Tests; git diff --cached --name-only HEAD -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

If the base file goes missing after edits, STOP. At closeout run:

```sh
test -s /tmp/geraldine-plan-003-base
unexpected="$({ git diff --name-only "$(</tmp/geraldine-plan-003-base)" -- Sources Tests; git diff --cached --name-only "$(</tmp/geraldine-plan-003-base)" -- Sources Tests; git ls-files --others --exclude-standard -- Sources Tests; } | sort -u | rg -v -e '^Sources/Geraldine/Services/PowerTools\.swift$' -e '^Tests/GeraldineTests/FinderSelectionDescriptorTests\.swift$' -e '^Sources/Geraldine/MenuBar/MetricWidgets\.swift$' || true)"
test -z "$unexpected"
```

## Scope

**In scope**:

- `Sources/Geraldine/Services/PowerTools.swift`
- `Tests/GeraldineTests/FinderSelectionDescriptorTests.swift` (create)
- `plans/README.md` (Plan 003 status cell only)

**Out of scope**:

- Changing checksum, copy/move, or cut/paste behavior beyond selection transport.
- Background execution; Plan 004 owns actor/execution changes.
- Finder window targeting, `openFinderSelection`, global keyboard policy, or UI.
- Shell escaping, NUL-delimited strings, JSON, or another textual encoding.
- `MetricWidgets.swift` and jj metadata.

## Git workflow

- Branch: `codex/003-structured-finder-selection`.
- Suggested commit: `Preserve structured Finder selections`.
- Do not push or open a PR unless instructed.

## Steps

### Step 1: Return a list descriptor from AppleScript

Replace the accumulator string with an AppleScript list. Iterate the Finder
alias selection, append each `POSIX path` string to that list, and return the
list. Execute it with `NSAppleScript.executeAndReturnError` so the production
code receives `NSAppleEventDescriptor` rather than `osascript` stdout.

Keep this adapter main-actor isolated. On AppleScript failure, return an empty
selection as today; do not expose raw script errors or retry via text.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-003-tests --filter FinderSelectionDescriptorTests`
compiles.

### Step 2: Decode the Apple-event list without normalization loss

Add an internal decoder that requires an Apple-event list, iterates descriptor
indices `1...numberOfItems`, reads each item's `stringValue`, and constructs one
file URL per descriptor item. Preserve embedded newlines, leading/trailing
spaces, Unicode, and multiple adjacent items exactly. Ignore only descriptor
items that are not strings.

Route `FinderPowerToolsService.selectedFileURLs()` through this adapter. Keep
the returned type `[URL]`; callers must not know about Apple-event descriptors.

**Verify**:
the old `result.output.split` path is absent from `selectedFileURLs`.

### Step 3: Test the structured boundary

Create an `NSAppleEventDescriptor` list in tests and insert string descriptors
for:

- a normal path;
- a filename containing an embedded newline;
- a filename with leading/trailing spaces;
- a Unicode filename;
- two adjacent selections that must stay two URLs.

Also test an empty list and a non-list descriptor. Assert exact URL paths and
item counts.

**Verify**:
`swift test --scratch-path /tmp/geraldine-plan-003-tests --filter FinderSelectionDescriptorTests`
passes.

### Step 4: Run the full source gate

**Verify**:

- `swift test --scratch-path /tmp/geraldine-plan-003-full` exits 0.
- `git diff --check` exits 0.
- the scope allowlist emits no output, and the recorded `MetricWidgets.swift`
  diff hash is unchanged.

## Test plan

All cases are enumerated in Step 3. Tests exercise descriptor decoding, not the
live Finder UI; live Finder automation belongs to installed-app verification
after implementation and explicit authorization.

## Done criteria

- [ ] Finder selection is transported as an Apple-event list, not delimited text.
- [ ] Newline, whitespace, Unicode, empty, invalid, and multiple-item cases pass.
- [ ] Operation callers still receive `[URL]` without parsing text.
- [ ] Full tests and `git diff --check` pass.
- [ ] Only in-scope files changed.
- [ ] The pre-existing `MetricWidgets.swift` diff hash is unchanged.
- [ ] Plan 003's README status is updated.

## STOP conditions

Stop and report if:

- the local SDK's `NSAppleScript` result cannot expose list descriptors as
  documented;
- preserving list structure would require a textual delimiter or shell escape;
- AppleScript must run off-main to make progress;
- source drift, repeated test failure, or out-of-scope changes occur.

## Maintenance notes

Any future Finder automation returning multiple values should retain descriptor
structure to the typed boundary. Reviewers should reject delimiter changes,
even NUL, because Apple events already provide a native list.
