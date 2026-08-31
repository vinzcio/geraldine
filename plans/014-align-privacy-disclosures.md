# Plan 014: Align Finder and speed-test privacy disclosures

> **Executor instructions**: Follow this plan step by step and run every gate.
> On any STOP condition, report instead of improvising. When complete, update
> only Plan 014's status cell in `plans/README.md`, unless the dispatcher owns
> the index.
>
> **Required handoff**: The dispatcher supplies a clean isolated checkout. Do
> not execute in the planning checkout: its Dock-preview lane, including
> `build.sh`, is user-owned dirty work. The entire lane must first be committed
> or handed off and must remain intact. This plan does not create/manage a
> worktree or branch and does not commit, push, install, or launch.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- build.sh Sources/Geraldine/Services/NetworkInfo.swift Sources/Geraldine/MenuBar/MetricWidgets.swift Tests/GeraldineTests/PrivacyDisclosureContractTests.swift plans/README.md`
> `build.sh` should differ from `7b6fa41` only because the required Dock lane
> added its Screen Recording usage string. Run the exact pre-edit hash gates
> below; if any fails or an excerpt differs semantically, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: the complete current Dock-preview lane committed/handed off
- **Category**: security, docs, tests
- **Planned at**: commit `7b6fa41` plus the exact `build.sh` working state below,
  2026-08-31

## Why this matters

macOS asks for Apple Events consent using a string that currently claims
“system maintenance,” while Geraldine actually automates Finder selection and
the front Finder folder. Separately, the speed-test control sends substantial
traffic to Cloudflare without adjacent or consistently discoverable disclosure.
Accurate, source-coupled text lets a user make an informed choice without
changing either feature's behavior, transfer sizes, destination, or defaults.

## Current state

Pre-edit file identities in the planning snapshot:

- `build.sh`: SHA-256
  `31b1c914e0c30315a4f7adc81d91f304751da299028859c54ae61262c626dee2`;
  differs from `7b6fa41` because the Dock lane added Screen Recording wording.
- `Sources/Geraldine/Services/NetworkInfo.swift`: SHA-256
  `19356fe713b8980743e379c4232b6f2ae19b994f914bcbc8cbaf856e0d807501`.
- `Sources/Geraldine/MenuBar/MetricWidgets.swift`: SHA-256
  `eed566d6766d2fb5d86c51c95925726122fa64375784e1c72ad2da05d658b3db`.

The generated Info.plist currently misstates Apple Events use while the next
line is user-owned Dock work that must survive unchanged (`build.sh:150-155`):

```sh
<key>NSRemovableVolumesUsageDescription</key><string>Geraldine can scan external volumes for files you can clean up.</string>
<key>NSAppleEventsUsageDescription</key><string>Geraldine uses authorized commands to run system maintenance tasks you request.</string>
<key>NSScreenCaptureUsageDescription</key><string>Geraldine shows window thumbnails when you hover over Dock apps. Previews stay on this Mac and are not saved.</string>
```

Actual automation opens the Finder selection (`PowerTools.swift:1039-1052`),
reads selected file/folder paths (`PowerTools.swift:1076-1091`), and reads the
front Finder window's folder, falling back to Desktop when no Finder window is
open (`PowerTools.swift:1104-1118`):

```swift
tell application "Finder"
    set selectedItems to selection as alias list
    // ... return each selected item's POSIX path ...
end tell

tell application "Finder"
    if (count of Finder windows) > 0 then
        set targetFolder to target of front Finder window as alias
    else
        set targetFolder to path to desktop folder
    end if
end tell
```

The speed test owns two fixed transfers to Cloudflare
(`NetworkInfo.swift:248-280`):

```swift
let bytes = 25_000_000
let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")
// ... URLSession.shared.data ...

let url = URL(string: "https://speed.cloudflare.com/__up")
let payload = Data(count: 10_000_000)
// ... URLSession.shared.upload ...
```

`MetricWidgets.swift:1211-1262` exposes three actionable speed-test states but
only the completed state has help, and it omits transfer/destination details:

```swift
case .idle:
    Button { network.runSpeedTest() } label: { Label("Test Speed", systemImage: "gauge.with.dots.needle.67percent") }
case .done(let down, let up):
    Button { network.runSpeedTest() } label: { /* result */ }
        .help("Run the speed test again")
case .failed:
    Button { network.runSpeedTest() } label: { Label("Retry Test", systemImage: "exclamationmark.arrow.circlepath") }
```

Follow the pure-value XCTest style in
`Tests/GeraldineTests/RateFormatterTests.swift:4-23`: use `XCTAssertEqual` and
string assertions directly against a source-owned value; do not start monitors,
perform requests, render UI, or inspect an installed Info.plist.

## Commands and prerequisite gates

| Purpose | Command | Expected |
|---|---|---|
| SDK | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5" && test -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk` | exit 0 |
| Focused tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN014_ROOT/swiftpm" --filter PrivacyDisclosureContractTests` | all pass |
| Full tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk /usr/bin/xcrun --sdk macosx swift test --scratch-path "$PLAN014_ROOT/swiftpm"` | all pass |
| Hygiene | `git diff --check` | exit 0, no output |

Run before editing in the dispatcher-supplied checkout:

```sh
PLANNING_CHECKOUT='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PLANNING_CHECKOUT" && pwd -P)"
test -z "$(git status --short)"
git merge-base --is-ancestor 7b6fa41 HEAD
lane_paths=(
  Sources/Geraldine/Features/PowerTools/PowerToolsView.swift
  Sources/Geraldine/Features/PowerTools/DockWindowPreviewView.swift
  Sources/Geraldine/Services/Permissions.swift
  Sources/Geraldine/Services/PowerTools.swift
  Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift
  Sources/Geraldine/Services/DockWindowPreviewModel.swift
  Sources/Geraldine/Services/DockWindowPreviewService.swift
  Tests/GeraldineTests/DockWindowPreviewTests.swift
  build.sh
)
git ls-files --error-unmatch "${lane_paths[@]}"
test "$(shasum -a 256 build.sh | awk '{print $1}')" = '31b1c914e0c30315a4f7adc81d91f304751da299028859c54ae61262c626dee2'
test "$(shasum -a 256 Sources/Geraldine/Services/NetworkInfo.swift | awk '{print $1}')" = '19356fe713b8980743e379c4232b6f2ae19b994f914bcbc8cbaf856e0d807501'
test "$(shasum -a 256 Sources/Geraldine/MenuBar/MetricWidgets.swift | awk '{print $1}')" = 'eed566d6766d2fb5d86c51c95925726122fa64375784e1c72ad2da05d658b3db'
rg -n '^\| 014 \|' plans/README.md
```

Expected: all exit 0; the checkout is isolated/clean, every Dock lane path is
tracked, all hashes match, and Plan 014 exists in the index. Otherwise STOP.

Register only a SwiftPM scratch root; the dispatcher owns checkout lifecycle:

```sh
PLAN014_OWNER='<current-thread-or-session-id>'
test "$PLAN014_OWNER" != '<current-thread-or-session-id>'
PLAN014_ROOT="/private/tmp/geraldine-plan-014-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN014_RECEIPT="/tmp/$(basename "$PLAN014_ROOT")-receipt.json"
test ! -e "$PLAN014_ROOT"
test ! -e "$PLAN014_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN014_ROOT" --temp-root /private/tmp --receipt "$PLAN014_RECEIPT" \
  --owner "$PLAN014_OWNER" --purpose "Geraldine Plan 014 SwiftPM tests" --profile swiftpm
git rev-parse HEAD > "$PLAN014_ROOT/executor-base"
```

## Scope and Git workflow

**Only modify** `build.sh`, `Sources/Geraldine/Services/NetworkInfo.swift`,
`Sources/Geraldine/MenuBar/MetricWidgets.swift`, new
`Tests/GeraldineTests/PrivacyDisclosureContractTests.swift`, and Plan 014's
status cell in `plans/README.md`.

Everything else is out of scope, especially Dock-preview files and behavior,
AppleScript behavior, transfer sizes/URLs/cadence/timeouts/cache policy,
permission prompting, first-run UI, persistence, telemetry, analytics, feature
defaults, layout/restyling, localization infrastructure, signing, and packaging.
Do not mutate git/worktree state, commit, push, install, launch, or use live
Finder automation, network transfers, consent prompts, or UI interaction.

## Steps

### Step 1: Correct only the Apple Events consent string

Replace only `NSAppleEventsUsageDescription` in `build.sh` with this exact text:

> Geraldine controls Finder when you run Finder tools, to read or open selected
> files and folders and use the folder shown in the front Finder window.

Do not change AppleScript or any other plist key/value. Preserve the adjacent
Screen Recording line byte-for-byte.

**Verify**:

```sh
rg -F '<key>NSAppleEventsUsageDescription</key><string>Geraldine controls Finder when you run Finder tools, to read or open selected files and folders and use the folder shown in the front Finder window.</string>' build.sh
test -z "$(rg 'NSAppleEventsUsageDescription.*system maintenance' build.sh || true)"
rg -F '<key>NSScreenCaptureUsageDescription</key><string>Geraldine shows window thumbnails when you hover over Dock apps. Previews stay on this Mac and are not saved.</string>' build.sh
BASE="$(<"$PLAN014_ROOT/executor-base")"
test "$(git diff --numstat "$BASE" -- build.sh | awk '{print $1 " " $2}')" = '1 1'
```

Expected: both exact disclosure lines print, the stale wording is absent, and
`build.sh` has exactly one added/one removed line.

### Step 2: Make transfer facts one immutable source-owned contract

In `NetworkInfo.swift`, add internal `NetworkSpeedTestDisclosure: Equatable,
Sendable` with immutable `let` destination/download/upload fields, one
`static let current`, and computed `text`. Keep the existing values exactly:
`Cloudflare`, `25_000_000` download bytes, and `10_000_000` upload bytes. Text
must say: “Runs a speed test with Cloudflare; each test transfers up to 25 MB
down and 10 MB up.” Derive `25` and `10` from byte fields using decimal MB; do
not duplicate them as separate disclosure literals.

Change `measureDownload()` and `measureUpload()` to consume `current` byte
fields. Do not change the endpoint strings, methods, cache policy, timeout,
error behavior, or state transitions.

**Verify**:

```sh
test "$(rg -c '25_000_000' Sources/Geraldine/Services/NetworkInfo.swift)" -eq 1
test "$(rg -c '10_000_000' Sources/Geraldine/Services/NetworkInfo.swift)" -eq 1
rg -n 'struct NetworkSpeedTestDisclosure|static let current|downloadByteCount|uploadByteCount' Sources/Geraldine/Services/NetworkInfo.swift
rg -F 'https://speed.cloudflare.com/__down?bytes=\(bytes)' Sources/Geraldine/Services/NetworkInfo.swift
rg -F 'https://speed.cloudflare.com/__up' Sources/Geraldine/Services/NetworkInfo.swift
```

Expected: each transfer literal has one authority, both measurement paths use
the contract, and both original endpoints remain.

### Step 3: Disclose the contract on every actionable speed-test state

In `MetricWidgets.swift`, add one private computed string property that returns
`NetworkSpeedTestDisclosure.current.text`. Apply that same value as `.help` and
`.accessibilityHint` to the `.idle`, `.done`, and `.failed` buttons. Replace the
done button's weaker “Run the speed test again” help. Do not alter labels,
button actions/styles, the running/offline states, layout, animation, or phases.

**Verify**:

```sh
speed_slice="$(sed -n '/@ViewBuilder private var speedControl:/,/private var speedPhaseKey:/p' Sources/Geraldine/MenuBar/MetricWidgets.swift)"
test "$(printf '%s\n' "$speed_slice" | rg -c '\.help\(speedTestDisclosureText\)')" -eq 3
test "$(printf '%s\n' "$speed_slice" | rg -c '\.accessibilityHint\(speedTestDisclosureText\)')" -eq 3
test -z "$(printf '%s\n' "$speed_slice" | rg 'Run the speed test again' || true)"
rg -n 'speedTestDisclosureText.*NetworkSpeedTestDisclosure\.current\.text|NetworkSpeedTestDisclosure\.current\.text' Sources/Geraldine/MenuBar/MetricWidgets.swift
```

Expected: one source property and exactly three consistent help/hint consumers.

### Step 4: Add contract tests and run closeout gates

Create `PrivacyDisclosureContractTests.swift` using XCTest and
`@testable import Geraldine`. Test that `current` owns destination `Cloudflare`,
exact byte counts `25_000_000`/`10_000_000`, and text containing `Cloudflare`,
`25 MB`, `10 MB`, and `each test`. No requests, monitor construction, UI, or
filesystem reads. Run focused tests, full tests, hygiene, and Steps 1-3 gates.

Review the allowlisted diff; confirm only the consent line changed in
`build.sh`, endpoints/transfer behavior remain, all three buttons reference the
same contract, and no broader privacy flow appeared. If a review fix changes
code, rerun the complete loop. Then update only Plan 014's status to `DONE`.

```sh
BASE="$(<"$PLAN014_ROOT/executor-base")"
set -e
set -o pipefail
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "build.sh" && $0 != "Sources/Geraldine/Services/NetworkInfo.swift" && $0 != "Sources/Geraldine/MenuBar/MetricWidgets.swift" && $0 != "Tests/GeraldineTests/PrivacyDisclosureContractTests.swift" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
rg -n '^\| 014 \|.*\| DONE \|$' plans/README.md
git diff "$BASE" -- build.sh Sources/Geraldine/Services/NetworkInfo.swift Sources/Geraldine/MenuBar/MetricWidgets.swift Tests/GeraldineTests/PrivacyDisclosureContractTests.swift plans/README.md
```

Finally mark/finalize only `$PLAN014_ROOT`, verify exact absence, and close out:

```sh
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark --receipt "$PLAN014_RECEIPT" --state disposable --reason "Plan 014 tests/review complete; proof is in the transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize --receipt "$PLAN014_RECEIPT" --check-open-files
test ! -e "$PLAN014_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout --owner "$PLAN014_OWNER" --finalize-disposable
test ! -e "$PLAN014_RECEIPT"
```

## Test plan

The focused contract tests prove the provider, payload counts, and derived
disclosure text without network or UI effects. Static gates prove all three
actionable controls consume that contract and only the Apple Events consent
line changed; the full Swift suite protects existing NetworkMonitor state and
menu-bar rendering.

## Done criteria

- [ ] Clean isolated-checkout, exact hashes, complete Dock lane, SDK, and index
      gates pass before editing.
- [ ] Apple Events text accurately names Finder, selected files/folders, and
      the front Finder window folder; only that `build.sh` line changes.
- [ ] One immutable contract owns unchanged provider/byte values; both original
      Cloudflare URLs and all request/state behavior remain unchanged.
- [ ] Idle, done, and failed controls each expose the same help and AX hint.
- [ ] Focused/new tests and the full suite pass under the macOS 26.5 SDK; static,
      hygiene, scoped-review, and allowlist gates pass.
- [ ] Only four implementation/test files and Plan 014's status cell differ;
      CLAYGO scratch is absent and owner closeout succeeds.
- [ ] No first-run/persistence/telemetry/policy/permission flow, live Finder or
      network action, installation, launch, commit, or push occurred.

## STOP conditions

STOP if the Dock lane is not committed/tracked/clean; any hash/excerpt differs;
the checkout is not isolated; the README row is absent; fixing disclosure would
change transfer values, URLs, timeouts, cadence, policy, AppleScript, permission
prompting, persistence, telemetry, layout, or another file; a test needs live
network/Finder/UI/app state; SDK 26.5 is unavailable; a gate fails twice after
one reasonable in-scope correction; another path/index row changes; or CLAYGO
cannot finalize/close out. Do not create/manage a worktree, clean/revert shared
work, commit, push, install, launch, or broaden scope.

## Maintenance notes

Future transfer-size/provider changes must update the immutable contract first;
measurement and disclosure must continue consuming that one source. Reviewers
should reject hard-coded UI copies or generic TCC wording. This plan deliberately
adds no first-run disclosure: `.help` plus accessibility hints are the chosen
consistently discoverable surface for every actionable speed-test state.
