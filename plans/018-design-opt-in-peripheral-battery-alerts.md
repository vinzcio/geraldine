# Plan 018: Decide whether and how to offer opt-in peripheral battery alerts

> **Executor instructions**: This is a design/architecture spike, not an
> implementation plan. Follow each step, run every gate, and stop rather than
> inventing a product choice. When finished, update only Plan 018's status cell
> in `plans/README.md`, unless the dispatcher owns the index.
>
> **Required handoff**: The dispatcher supplies a clean isolated checkout with
> Plan 009 completed. Do not execute in the current dirty planning checkout.
> Do not create/manage a worktree or branch, commit, push, install, launch,
> deliver a notification, or request notification permission.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/ConnectedDevices.swift Tests/GeraldineTests/DeviceMonitorRefreshTests.swift docs/product/peripheral-battery-alerts-spike.md plans/README.md`
> `ConnectedDevices.swift` is expected to differ after Plan 009. Compare its
> live device model/result-publication semantics to the excerpts below. If the
> completed monitor no longer publishes `[ConnectedDevice]` snapshots or Plan
> 009 added a cadence/polling policy, STOP and report the drift.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/009-coalesce-device-refreshes.md`
- **Category**: direction, docs
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Peripheral battery alerts could be useful, but the current data is an
occasional device snapshot rather than an alert-grade event stream. Identity,
missing/stale values, reconnects, multi-cell batteries, notification permission,
and suppression rules all affect whether alerts help or become noisy/misleading.
This spike obtains Vincent's explicit product choices and records a GO/NO-GO
architecture without changing application behavior or scan cadence.

## Current state

`ConnectedDevice` exposes display-oriented identity and one optional battery
value (`ConnectedDevices.swift:29-39` at the planned commit):

```swift
let id: String
var name: String
var kind: Kind
var battery: Double?      // 0…1, nil if not reported
var detail: String
var volumeURL: URL?

var lowBattery: Bool {
    guard battery != nil else { return false }
    return MetricPresentationPolicy.batteryChargeState(level: battery) != .good
}
```

That `lowBattery` property is a current visual/sort classification, not an
approved interruption threshold. `MetricPresentationPolicy` marks `<= 20%` as
non-good, while its nearby architecture note says visual state does not
automatically justify interrupting the user. This spike must not inherit 20%
as an alert default.

`DeviceMonitor` publishes completed snapshots through one property
(`ConnectedDevices.swift:43-45`):

```swift
@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
```

At `7b6fa41`, refresh runs one combined Bluetooth/USB `system_profiler` call and
then assigns the sorted result to `devices` (`ConnectedDevices.swift:67-80,
157-165`). Plan 009 must first make overlapping refresh requests coalesce into
one follow-up without adding polling, a timer, freshness window, or another
profiler call. Any later alert evaluator may consume only those completed
`devices` publications; it must never initiate or accelerate discovery.

Current evidence that shapes, but does not settle, the design:

- Bluetooth IDs are currently `bt:<display name>`
  (`ConnectedDevices.swift:168-181`), so same-name devices can collide and a
  renamed device can look new.
- A Bluetooth report may omit battery entirely; a profiler/parsing failure
  currently yields no Bluetooth/USB results (`ConnectedDevices.swift:157-165`).
- Left/right/case battery reports are collapsed to the lowest component
  (`ConnectedDevices.swift:188-197`); the component identity is discarded.
- Drives and USB iOS devices currently report `battery: nil`; only data actually
  present in `DeviceMonitor.devices` is available to a future policy.
- `AppState` owns one process-lifetime `DeviceMonitor`, and there is currently
  no notification authorization/delivery subsystem in app source.

Any future alert state remains local-only on this Mac. Cloud sync, accounts,
telemetry, and cross-device alert history are fixed non-goals, not decision
options.

## Commands and prerequisite gates

There is no build/test command: the only repository artifact is a Markdown
decision record. Validate structure and scope with read-only shell gates.

Run before writing in the dispatcher-supplied checkout:

```sh
PLANNING_CHECKOUT='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PLANNING_CHECKOUT" && pwd -P)"
test -z "$(git status --short)"
git merge-base --is-ancestor 7b6fa41 HEAD
rg -n '^\| 009 \|.*\| DONE \|$' plans/README.md
rg -n '^\| 018 \|' plans/README.md
git ls-files --error-unmatch Sources/Geraldine/Services/ConnectedDevices.swift Tests/GeraldineTests/DeviceMonitorRefreshTests.swift
rg -n '@Published private\(set\) var devices: \[ConnectedDevice\]' Sources/Geraldine/Services/ConnectedDevices.swift
rg -n 'var lowBattery: Bool|batteryChargeState' Sources/Geraldine/Services/ConnectedDevices.swift
```

Expected: every command exits 0; checkout is isolated/clean, Plan 009 is `DONE`,
its test is tracked, Plan 018 exists, and the two evidence seams remain. STOP on
any failure.

Register only one scratch root. The dispatcher owns checkout lifecycle:

```sh
PLAN018_OWNER='<current-thread-or-session-id>'
test "$PLAN018_OWNER" != '<current-thread-or-session-id>'
PLAN018_ROOT="/private/tmp/geraldine-plan-018-$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
PLAN018_RECEIPT="/tmp/$(basename "$PLAN018_ROOT")-receipt.json"
test ! -e "$PLAN018_ROOT"
test ! -e "$PLAN018_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN018_ROOT" --temp-root /private/tmp --receipt "$PLAN018_RECEIPT" \
  --owner "$PLAN018_OWNER" --purpose "Plan 018 peripheral alert design spike" --profile generic
git rev-parse HEAD > "$PLAN018_ROOT/executor-base"
```

## Scope and Git workflow

**Only modify**:

- `docs/product/peripheral-battery-alerts-spike.md` (create)
- `plans/README.md` (Plan 018 status cell only)

Application source and tests are evidence only. Do not add notification code,
preferences, persistence, permissions, UI, dependencies, entitlements, timers,
background work, scans, tests, or fixtures. Do not select thresholds, cooldowns,
retention, actions, or any other default on Vincent's behalf. Do not mutate git
metadata, commit, push, install, launch, or exercise live system state.

## Steps

### Step 1: Build an evidence and threat-model brief

Create the missing directory, then create the document with `apply_patch`:

```sh
mkdir -p docs/product
test ! -e docs/product/peripheral-battery-alerts-spike.md
```

Create `docs/product/peripheral-battery-alerts-spike.md` with these sections:

1. `Status` — `Decision status: PENDING` and
   `Implementation status: Not shipped` while work is open.
2. `Evidence and fixed constraints` — cite the exact source facts above and
   state that alerts consume existing Plan 009 publications only; no new scan,
   timer, `system_profiler` call, or cadence change is allowed.
3. `Threat model` — a table covering stale battery values, missing battery
   values, profiler failure/empty results, duplicate/renamed identities,
   threshold flapping, disconnect/reconnect, multiple simultaneous low devices,
   alert storms, notification permission denial, and corrupt/incompatible local
   state if persistence is selected.
4. `Decision ledger`, `Policy/state model`, `GO or NO-GO`, `Implementation
   outline if GO`, and `Deferred/non-goals` as initially unselected sections.

For each threat, record current evidence, possible user harm, the decision that
controls it, and validation scenarios. Do not write a mitigation as selected.

**Verify**:

```sh
DOC='docs/product/peripheral-battery-alerts-spike.md'
for heading in 'Status' 'Evidence and fixed constraints' 'Threat model' 'Decision ledger' 'Policy/state model' 'GO or NO-GO' 'Implementation outline if GO' 'Deferred/non-goals'; do
  test "$(rg -Fxc "## $heading" "$DOC")" -eq 1 || exit 1
done
for threat in stale missing duplicate flapping reconnect storm permission; do
  rg -qi "$threat" "$DOC" || exit 1
done
rg -qi 'existing.*DeviceMonitor.*devices' "$DOC" || exit 1
rg -qi 'no new scan' "$DOC" || exit 1
rg -qi 'no.*cadence' "$DOC" || exit 1
rg -qi 'local-only.*no (cloud|sync)|no (cloud|sync).*local-only' "$DOC" || exit 1
```

Expected: every heading and threat prints; the fixed no-cadence boundary is
explicit.

### Step 2: Obtain every product decision from Vincent

Add exactly these decision-ledger rows, initially `PENDING`, with neutral
options/tradeoffs and no recommended/default choice:

1. Eligible device types.
2. Alert threshold and hysteresis/recovery threshold.
3. Cooldown, deduplication key, batching, and repeat behavior.
4. Reconnect/disconnect state cleanup and identity changes.
5. Notification permission timing and denial/recovery UX.
6. Notification content, privacy level, click behavior, and actions.
7. Persistence versus process/session scope for opt-in and suppression state.
8. Multi-battery semantics (current lowest-value composite versus components).
9. Missing/stale/profiler-failure behavior.
10. The opt-in surface and how a user disables alerts again.
11. Retention and deletion if any opt-in/suppression/history state persists.
12. Schema compatibility/evolution if any state persists.
13. Corrupt/incompatible-state recovery if any state persists.

Rows 11–13 remain mandatory ledger rows. If Vincent chooses process/session-only
state with no persistence, record his explicit `NOT APPLICABLE — no persistence`
decision in each; do not omit them or infer that outcome.

Pause and ask Vincent for an explicit decision and rationale for every row. Do
not infer from `lowBattery`, other apps, generic platform convention, or ease of
implementation. If Vincent is unavailable or leaves a row unanswered, set Plan
018 to `BLOCKED (awaiting Vincent decisions)` and stop; do not mark the spike
`DONE`.

**Verify**:

```sh
for label in 'Eligible device types' 'Alert threshold and hysteresis' 'Cooldown and deduplication' 'Reconnect and disconnect cleanup' 'Notification permission UX' 'Notification content and actions' 'Persistence or session scope' 'Multi-battery semantics' 'Missing stale and failure behavior' 'Opt-in surface' 'Retention and deletion' 'Schema compatibility and evolution' 'Corrupt and incompatible recovery'; do
  rg -qF "$label" "$DOC" || exit 1
done
```

Expected: thirteen distinct rows are present. Before a GO decision, none may remain
`PENDING`, blank, or attributed to an agent assumption.

### Step 3: Model the selected policy without touching app source

After Vincent answers, translate only those decisions into a state-transition
table in the document. Inputs are successive completed `[ConnectedDevice]`
snapshots; outputs are notification intents or no intent. Cover first
observation, downward crossing, recovery/hysteresis, repeated low readings,
missing readings, duplicate identity, disconnect, reconnect, simultaneous
devices, permission states, restart/session boundary, and delivery failure.

If the chosen rules are too complex to validate clearly in a table, create a
pure model and scenario traces only under `$PLAN018_ROOT`; record whether the
scratch model was used and its conclusions in the document before cleanup.
The model must have no AppKit/UserNotifications/Shell/timer/filesystem effects
and must not manufacture new observations. It is disposable design evidence,
not production code.

**Verify**:

```sh
for scenario in 'first observation' 'downward crossing' recovery 'repeated low' missing duplicate disconnect reconnect simultaneous permission restart 'delivery failure'; do
  rg -qi "$scenario" "$DOC" || exit 1
done
rg -i 'scratch model: (used|not used)' "$DOC"
```

Expected: every scenario and the scratch-model disposition prints.

### Step 4: Record the explicit GO/NO-GO outcome

Ask Vincent for exactly `GO` or `NO-GO` after reviewing the completed ledger,
threat model, and state table. `GO` authorizes a later implementation plan only;
it does not authorize source changes here. `NO-GO` records rationale and may
mark unneeded rows `NOT SELECTED — NO-GO` rather than inventing answers.

For GO, the implementation outline must name future ownership seams, pure tests,
permission UX tests, and live acceptance gates—without writing code or assigning
unresolved defaults. If any state persists, GO additionally requires explicit
retention/deletion, schema evolution, and corrupt/incompatible recovery decisions.
For NO-GO, state what evidence/decision would justify reopening.

Set `Decision status: GO` or `Decision status: NO-GO`, retain
`Implementation status: Not shipped`, and add `Final gate: GO` or
`Final gate: NO-GO`. Only then may Plan 018's README status become `DONE`.

**Verify**:

```sh
test "$(rg -c '^Final gate: (GO|NO-GO)$' "$DOC")" -eq 1
rg -F 'Implementation status: Not shipped' "$DOC"
test -z "$(rg -n '\| (PENDING|AGENT-ASSUMED) \|' "$DOC" || true)"
rg -n '^\| 018 \|.*\| DONE \|$' plans/README.md
git diff --check
```

Expected: one final gate, explicit not-shipped status, no unresolved/defaulted
decision, correct README status, and clean patch hygiene.

### Step 5: Prove docs-only scope and close scratch ownership

```sh
BASE="$(<"$PLAN018_ROOT/executor-base")"
set -e
set -o pipefail
git cat-file -e "$BASE^{commit}"
test "$(git rev-parse HEAD)" = "$BASE"
unstaged="$(git diff --name-only "$BASE" -- .)"
staged="$(git diff --cached --name-only "$BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "docs/product/peripheral-battery-alerts-spike.md" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
doc_diff_status=0
git diff --no-index -- /dev/null docs/product/peripheral-battery-alerts-spike.md || doc_diff_status=$?
test "$doc_diff_status" -eq 1
git diff "$BASE" -- plans/README.md
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark --receipt "$PLAN018_RECEIPT" --state disposable --reason "Plan 018 decision evidence is preserved in the product spike"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize --receipt "$PLAN018_RECEIPT" --check-open-files
test ! -e "$PLAN018_ROOT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout --owner "$PLAN018_OWNER" --finalize-disposable
test ! -e "$PLAN018_RECEIPT"
```

Expected: only the decision doc and status cell differ; scratch is absent and
owner closeout succeeds. The dispatcher-supplied checkout remains unmanaged.

## Test plan

This docs-only spike is verified by the evidence/threat/decision/scenario
structure gates, explicit GO/NO-GO and not-shipped markers, a no-source-change
allowlist, and local review for inferred thresholds or added scan cadence. Any
optional scratch model uses synthetic snapshots only and must be finalized.

## Done criteria

- [ ] Plan 009 is `DONE`; the spike consumes only completed existing device
      snapshots and proposes no added scan/cadence/system_profiler work.
- [ ] The document contains source evidence, all named threats, thirteen explicit
      Vincent-owned decision rows, and complete scenario transitions.
- [ ] No choice is selected by the executor; unanswered work blocks the plan.
- [ ] One explicit GO/NO-GO is recorded and `Implementation status` remains
      `Not shipped`; Plan 018 `DONE` means spike complete, never feature shipped.
- [ ] GO contains a later-plan outline only; NO-GO contains reopening criteria.
- [ ] Local-only/no-sync is fixed; persisted state cannot reach GO without
      explicit retention/deletion, schema, and corrupt-state recovery decisions.
- [ ] Docs-only allowlist and `git diff --check` pass; app source/tests unchanged.
- [ ] Scratch is finalized, CLAYGO closes out, and no live notification,
      permission, app, scan, install, launch, VCS, or publication action occurred.

## STOP conditions

STOP if Plan 009 is incomplete; the checkout is dirty/shared; device publication
or low-battery semantics drift; Vincent does not explicitly resolve every row
needed for GO and the final GO/NO-GO gate; safe behavior appears to require more
frequent scans, a new background profiler, guessed identity, or an unapproved
policy/default; any app source/test file changes; the document claims the
feature shipped; a gate fails twice after one docs-only correction; another
path/index row changes; or CLAYGO cannot finalize. Do not broaden the spike.

## Maintenance notes

The resulting document is the sole decision record for a later implementation
plan. Future work must distinguish presentation `lowBattery` from interruption
policy and preserve Plan 009's scan admission/cadence. Any new device identity,
timestamp/freshness, component-battery, persistence, or notification framework
must be separately authorized by the recorded GO decisions—not inferred here.
