# Plan 019: Decide a safe known-network Wi-Fi failover contract

> **Executor instructions**: This is a design-and-feasibility spike, not a
> production implementation. Work in a clean isolated checkout supplied by the
> dispatcher. Produce the decision document and compile-only proof described
> below; do not change Wi-Fi configuration, request authorization, or edit app
> source. Stop on any STOP condition rather than choosing product defaults.
>
> **Drift check (run first)**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Services/NetworkInfo.swift Package.swift HANDOFF.md docs/product/wifi-failover-spike.md plans/README.md`
> `NetworkInfo.swift` and `Package.swift` may contain other completed plan work,
> but their CoreWLAN ownership and framework linkage must still match the
> excerpts below. The output document must not already have unrelated ownership.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: HIGH
- **Depends on**: none; Step 3 decisions are this spike's internal terminal gate
- **Category**: direction, feasibility, privacy, reliability
- **Planned at**: commit `7b6fa41`, 2026-08-31

## Why this matters

Geraldine already observes the Mac's current Wi-Fi connection. A parked product
direction proposes moving a known secondary network ahead of a degraded primary
network without reading or storing credentials. That can affect connectivity,
require privileged authorization, and produce loops or outages if signal,
candidate, rollback, and consent rules are vague. Before code exists, this plan
must establish what the installed SDK supports and turn every behavioral choice
into an explicit decision owned by Vincent.

## Current state

`Sources/Geraldine/Services/NetworkInfo.swift:70-130` owns observation only:

```swift
private let pathMonitor = NWPathMonitor()
private let wifiClient = CWWiFiClient.shared()

func start(interval: TimeInterval = 3) {
    timer?.invalidate()
    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshWiFi() }
    }
    t.tolerance = 1
    timer = t
}

func refreshWiFi() {
    guard let iface = wifiClient.interface() else { /* publish unavailable */ }
    let newSSID = (connection == .wifi && locationAuthorized) ? iface.ssid() : nil
    let r = iface.rssiValue()
    let newRSSI = (connection == .wifi && r != 0) ? r : nil
    let rate = iface.transmitRate()
    // publish observed metadata
}
```

`HANDOFF.md:75-76` records the parked direction: secondary Wi-Fi failover by
reordering CoreWLAN preferred-network profiles, relying only on credentials
already managed by macOS, with **no Keychain use**. Treat this as intent, not as
proof that reordering immediately changes the active connection.

The installed Xcode 26.5 CoreWLAN headers expose:

- `CWConfiguration.networkProfiles` as an ordered set;
- mutable profile ordering through `CWMutableConfiguration`;
- `CWInterface.commitConfiguration(_:authorization:error:)`; and
- `SFAuthorization` at the commit boundary.

Those signatures establish compile-time capability only. They do not establish
authorization frequency, live reassociation behavior, managed-device policy,
or rollback reliability. This spike must label each claim as one of: SDK fact,
compile-probe fact, documented platform behavior, product decision, or unproven
live behavior.

The non-negotiable boundaries are:

1. Never read, request, copy, persist, log, or transmit Wi-Fi credentials.
2. Never call Keychain APIs or add a Keychain entitlement/dependency.
3. Operate only on profiles already present in macOS's known-network ordering.
4. Never mutate a live network or ask for administrator authorization during
   this spike.
5. Do not choose signal thresholds, dwell times, hysteresis, cooldowns,
   preferred candidates, retry counts, notification behavior, or automatic
   defaults on Vincent's behalf.
6. A later implementation must have explicit consent, observable intent,
   bounded ownership of one reorder, verification, and a rollback path.

## Commands you will need

Prove checkout isolation first, then register only the compile-probe scratch
root. Hash the actual owner ID before using it in a path:

```sh
set -e
set -o pipefail
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
test ! -e docs/product/wifi-failover-spike.md
PLAN019_BASE='<dispatcher-supplied-execution-base-commit>'
test "$PLAN019_BASE" != '<dispatcher-supplied-execution-base-commit>'
git cat-file -e "$PLAN019_BASE^{commit}"
test "$(git rev-parse HEAD)" = "$PLAN019_BASE"

PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-019-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-019-$RESOURCE_TOKEN-receipt.json"
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py init \
  --path "$PLAN_TMP" --temp-root /private/tmp \
  --receipt "$PLAN_RECEIPT" --owner "$PLAN_OWNER" \
  --purpose "Plan 019 CoreWLAN compile-only feasibility probe" \
  --profile generic
```

Do not assume variables persist between executor commands. Before every
post-initialization shell call, repeat the exact `PLAN_OWNER`, `RESOURCE_TOKEN`,
`PLAN_TMP`, and `PLAN_RECEIPT` assignments above and require
`test -d "$PLAN_TMP"` plus `test -f "$PLAN_RECEIPT"`. Every repository-scope or
README block independently sets and validates `PLAN019_BASE` using the same
dispatcher-supplied commit.

| Purpose | Command | Expected on success |
|---|---|---|
| Clean isolated start | `test -z "$(git status --porcelain=v1 --untracked-files=all)"` | exit 0 |
| SDK gate | `test "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk macosx --show-sdk-version)" = "26.5"` | exit 0 |
| Header evidence | `rg -n 'networkProfiles|commitConfiguration' /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/CoreWLAN.framework/Headers` | required declarations print |
| Patch hygiene | `git diff --check` | exit 0; no output |

Create `$PLAN_TMP/CoreWLANCapabilityProbe.swift` using `apply_patch`, never a
shell heredoc and never repository source. Use this inert template with no
top-level call:

```swift
import CoreWLAN
import SecurityFoundation

func compileOnlyCapabilityProbe(
    interface: CWInterface,
    authorization: SFAuthorization?
) {
    guard let configuration = interface.configuration(),
          let mutable = configuration.mutableCopy() as? CWMutableConfiguration else {
        return
    }
    mutable.networkProfiles = configuration.networkProfiles
    if false {
        try? interface.commitConfiguration(mutable, authorization: authorization)
    }
}
```

The function may typecheck reading/copying configuration, ordered profiles,
and the commit boundary, but it is never called. This exact template passed a
compile-only planning probe on 2026-08-31. Invoke the verified Xcode toolchain
to typecheck only; do not produce or execute a binary:

```sh
set -e
set -o pipefail
PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-019-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-019-$RESOURCE_TOKEN-receipt.json"
test -d "$PLAN_TMP"
test -f "$PLAN_RECEIPT"
mkdir -p "$PLAN_TMP/module-cache" "$PLAN_TMP/tmp"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TMPDIR="$PLAN_TMP/tmp" \
  /usr/bin/xcrun --sdk macosx swiftc \
  -typecheck \
  -module-cache-path "$PLAN_TMP/module-cache" \
  -framework CoreWLAN -framework SecurityFoundation \
  "$PLAN_TMP/CoreWLANCapabilityProbe.swift"
test ! -e "$PLAN_TMP/CoreWLANCapabilityProbe"
for construct in 'import CoreWLAN' 'import SecurityFoundation' 'func compileOnlyCapabilityProbe(' 'CWMutableConfiguration' 'mutable.networkProfiles = configuration.networkProfiles' 'if false {' 'commitConfiguration(mutable, authorization: authorization)'; do
  rg -Fq "$construct" "$PLAN_TMP/CoreWLANCapabilityProbe.swift" || exit 1
done
! rg -n 'CWWiFiClient|\.shared\(|\.interface\(|\.ssid\(|scanForNetworks|associate\(|print\(' \
  "$PLAN_TMP/CoreWLANCapabilityProbe.swift"
```

The probe must not gain top-level expressions, current-interface lookup, SSID
access, network scanning, logging, authorization creation, or executable
invocation.

Preserve the successful typecheck, construct checks, SDK path/version, and the
fact that no executable ran in the task transcript. Then finalize the scratch
immediately, before document work:

```sh
set -e
set -o pipefail
PLAN_OWNER='<actual-executor-thread-or-session-id>'
test "$PLAN_OWNER" != '<actual-executor-thread-or-session-id>'
RESOURCE_TOKEN="$(printf '%s' "$PLAN_OWNER" | shasum -a 256 | cut -c1-12)"
PLAN_TMP="/private/tmp/geraldine-plan-019-$RESOURCE_TOKEN"
PLAN_RECEIPT="/tmp/geraldine-plan-019-$RESOURCE_TOKEN-receipt.json"
test -d "$PLAN_TMP"
test -f "$PLAN_RECEIPT"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py mark \
  --receipt "$PLAN_RECEIPT" --state disposable \
  --reason "Plan 019 compile-only evidence is preserved in the task transcript"
/Users/vincent/.codex/skills/claygo/scripts/claygo.py finalize \
  --receipt "$PLAN_RECEIPT" --check-open-files
/Users/vincent/.codex/skills/claygo/scripts/claygo.py closeout \
  --owner "$PLAN_OWNER" --finalize-disposable
test ! -e "$PLAN_TMP"
test ! -e "$PLAN_RECEIPT"
```

This is also the mandatory post-initialization STOP protocol. If any SDK,
header, source-template, typecheck, or static gate fails after `init`, preserve
the failure evidence, run the same mark/finalize/owner-closeout and exact
absence checks with a factual failure reason, and only then report the STOP. If
cleanup itself fails, stop and report that cleanup blocker without deleting or
weakening ownership checks. No registered scratch survives into Steps 1-4.

## Scope

**In scope**:

- `docs/product/wifi-failover-spike.md` (create)
- `plans/README.md` (Plan 019 status cell only)
- task-owned compile-only artifacts under the registered scratch root

**Out of scope**:

- all app source, tests, `Package.swift`, build/entitlement/plist files, and UI;
- live Wi-Fi scans, association, disassociation, profile commits/reordering,
  network-priority changes, authorization prompts, and System Settings changes;
- Keychain, credentials, secrets, SSID/profile logging, telemetry, sync, and
  cloud/network transmission;
- thresholds, timers, retry/cooldown limits, persistence/schema changes, or any
  automatic default not explicitly approved after this spike;
- installation, launch, signing, packaging, pushing, and PR creation.

## Git workflow

- Work only in the clean isolated checkout supplied by the dispatcher.
- Suggested branch: `codex/019-design-known-network-wifi-failover`.
- Do not create/finalize a worktree, commit, merge, push, install, or launch
  unless the dispatcher separately assigns that operation.

## Steps

### Step 1: Produce an evidence-classified capability map

Create the missing directory, then create the document with `apply_patch`:

```sh
set -e
set -o pipefail
mkdir -p docs/product
test ! -e docs/product/wifi-failover-spike.md
```

`docs/product/wifi-failover-spike.md` must contain exactly one of each heading,
in this order:

1. `## Status`
2. `## Evidence classification`
3. `## Fixed constraints`
4. `## Capability map`
5. `## Transaction and rollback options`
6. `## Vincent decision matrix`
7. `## Threat and failure model`
8. `## Final gate`
9. `## Implementation-plan prerequisites`

Under Status, record exact Xcode/SDK and source-commit provenance plus the line
`Implementation status: Not shipped`. Include a capability table for:

- reading current CoreWLAN configuration;
- preserving ordered known-network profiles;
- constructing a reordered mutable configuration;
- the typed authorization and commit boundary;
- whether profile objects expose credentials (the design must not use any even
  if an API exists);
- whether priority commit alone forces immediate live reassociation;
- behavior when Location/SSID access is denied;
- managed-device/admin-policy uncertainty; and
- rollback feasibility after a successful commit.

For each row, cite the local header/symbol or compile probe and label unknowns.
Do not turn the parked HANDOFF claim into a verified fact. If immediate
failover semantics cannot be established without a live mutation, record that
as a mandatory later opt-in validation gate.

Use this exact capability-table schema:

`| ID | Capability question | Evidence class | Evidence/reference | Result | Status |`

Rows use IDs `C01` through `C09`, in the bullet order above, with these exact
labels: `Read current configuration`, `Preserve ordered known-network profiles`,
`Construct reordered mutable configuration`, `Typed authorization and commit
boundary`, `Credential exposure boundary`, `Priority commit implies immediate
reassociation`, `Location or SSID access denied`, `Managed-device or
administrator policy`, and `Rollback from exact snapshot`. Evidence class is
exactly one of `SDK fact`, `compile-probe fact`, `documented platform behavior`,
`product decision`, or `unproven live behavior`. Evidence/reference and Result
must contain specific, non-placeholder analysis. Status is `ESTABLISHED` only
when the cited evidence establishes the row's result; otherwise it is
`UNPROVEN`.

Record exactly one `Capability evidence status: COMPLETE` or `Capability
evidence status: BLOCKED`. COMPLETE requires all nine rows to be ESTABLISHED.
Also record exactly one `Live mutation validation prerequisite: NONE` or `Live
mutation validation prerequisite: REQUIRED - <specific unproven behavior and
separately authorized validation needed>`. REQUIRED implies BLOCKED and forces
the terminal gate to NO-GO.

After writing the evidence and constraints sections, prove their structure:

```sh
set -e
set -o pipefail
DOC='docs/product/wifi-failover-spike.md'
for heading in 'Status' 'Evidence classification' 'Fixed constraints' 'Capability map' 'Transaction and rollback options' 'Vincent decision matrix' 'Threat and failure model' 'Final gate' 'Implementation-plan prerequisites'; do
  test "$(rg -c "^## $heading$" "$DOC")" -eq 1 || exit 1
done
EXPECTED_HEADINGS="$(printf '%s\n' '## Status' '## Evidence classification' '## Fixed constraints' '## Capability map' '## Transaction and rollback options' '## Vincent decision matrix' '## Threat and failure model' '## Final gate' '## Implementation-plan prerequisites')"
test "$(rg '^## ' "$DOC")" = "$EXPECTED_HEADINGS"
test "$(rg -c '^Implementation status: Not shipped$' "$DOC")" -eq 1
test "$(rg -c '^Local-only boundary: No cloud, sync, telemetry, or network transmission$' "$DOC")" -eq 1
test "$(rg -c '^Credential boundary: No Keychain or credential access$' "$DOC")" -eq 1
test "$(rg -Fxc '| ID | Capability question | Evidence class | Evidence/reference | Result | Status |' "$DOC")" -eq 1
require_capability_row() {
  test "$(rg -c "^\\| $1 \\| $2 \\|" "$DOC")" -eq 1
}
require_capability_row C01 'Read current configuration'
require_capability_row C02 'Preserve ordered known-network profiles'
require_capability_row C03 'Construct reordered mutable configuration'
require_capability_row C04 'Typed authorization and commit boundary'
require_capability_row C05 'Credential exposure boundary'
require_capability_row C06 'Priority commit implies immediate reassociation'
require_capability_row C07 'Location or SSID access denied'
require_capability_row C08 'Managed-device or administrator policy'
require_capability_row C09 'Rollback from exact snapshot'
for id in C01 C02 C03 C04 C05 C06 C07 C08 C09; do
  rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
    function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    {
      class=trim($4); evidence=trim($5); result=trim($6); status=trim($7)
      if (class !~ /^(SDK fact|compile-probe fact|documented platform behavior|product decision|unproven live behavior)$/) exit 1
      if (evidence == "" || evidence ~ /TBD|UNRESOLVED/) exit 1
      if (result == "" || result ~ /TBD|UNRESOLVED/) exit 1
      if (status !~ /^(ESTABLISHED|UNPROVEN)$/) exit 1
    }' || exit 1
done
test "$(rg -c '^Capability evidence status: (COMPLETE|BLOCKED)$' "$DOC")" -eq 1
test "$(rg -c '^Live mutation validation prerequisite: (NONE|REQUIRED - .+)$' "$DOC")" -eq 1
if rg -q '^Capability evidence status: COMPLETE$' "$DOC"; then
  for id in C01 C02 C03 C04 C05 C06 C07 C08 C09; do
    rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
      function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
      { if (trim($7) != "ESTABLISHED") exit 1 }' || exit 1
  done
else
  rg -q '^Capability evidence status: BLOCKED$' "$DOC"
fi
if rg -q '^Live mutation validation prerequisite: REQUIRED - .+' "$DOC"; then
  rg -q '^Capability evidence status: BLOCKED$' "$DOC"
else
  rg -q '^Live mutation validation prerequisite: NONE$' "$DOC"
fi
```

The fixed-constraint lines above are literal document markers. STOP if any
cannot be stated truthfully.

### Step 2: Define a mutation transaction without choosing its policy values

Document a future transaction as states, not implementation code:

`observing → candidate proposed → user consent → authorization → snapshot exact
order → commit one reorder → verify connection/order → success or selected
failure response`.

Specify invariants:

- snapshot the complete original order immediately before mutation;
- change only the order of two already-known profiles while preserving all
  remaining relative order and metadata;
- never manufacture a profile or accept a credential;
- if authorization is denied/cancelled, do nothing;
- verify the committed order and intended connection signal separately;
- serialize transactions so two observations cannot reorder concurrently.

Rollback capability using the exact snapshot is a required feasibility fact,
but the plan must not preselect what happens after verification fails. Present
these mutually exclusive options for Vincent: automatically attempt rollback,
offer rollback and wait for explicit consent, or stop without a second
mutation. Separately present the behavior when a selected rollback attempt
fails. Do not choose retry counts, deadlines, automatic rollback timing, or a
cease-automation policy. Keep every such behavior in the decision matrix.

### Step 3: Present every required product decision

The document must contain an explicit decision table with these exact row
labels and no preselected defaults:

1. `Eligible trigger signals`: RSSI, link rate, reachability/packet quality,
   or an explicitly selected combination.
2. `Degradation threshold and dwell`: threshold, dwell, and hysteresis.
3. `Recovery threshold and hysteresis`: recovery definition and hysteresis.
4. `Secondary eligibility and selection`: eligible known profiles and how the
   user selects them.
5. `Automation and consent`: manual-only, confirm-each-time, or opt-in
   automatic.
6. `Cooldown and retry behavior`: behavior after success, failure, denial, and
   any selected rollback.
7. `Authorization timing and explanation`: when and why macOS authorization is
   requested.
8. `Status notifications and history`: what is shown and whether any state or
   history persists.
9. `Unavailable SSID identity`: behavior when identity is unavailable or
   ambiguous.
10. `Success verification`: the exact definition of successful failover.
11. `Verification failure response`: automatic rollback, offered rollback, or
    stop with no second mutation, plus its owner/trigger.
12. `Rollback failure behavior`: behavior if a selected rollback cannot restore
    the snapshot.
13. `Managed policy rejection`: behavior when macOS or MDM rejects a change.
14. `Retention and deletion`: mandatory if any preference, suppression,
    cooldown, status, or history state persists; otherwise explicitly `N/A`
    with a no-persistence justification.
15. `Schema compatibility and evolution`: mandatory for persisted state;
    otherwise explicitly `N/A` with the same justification.
16. `Corrupt and incompatible recovery`: mandatory for persisted state;
    otherwise explicitly `N/A` with the same justification.
17. `Privacy, disclosure, and data minimization`: the exact network fields that
    may be displayed, included in notifications, persisted locally, redacted,
    and cleared by the user.

Use this exact table schema:

`| ID | Decision | Options and tradeoffs | Selected value | Vincent approval source | Status |`

Rows use IDs `D01` through `D17` in the order above. A selected row records a
nonempty value, plus `Vincent approval: YYYY-MM-DD - <direct source reference>`
and status `APPROVED`. During review, all three cells may say `UNRESOLVED`; a GO
gate may not. Record exactly one `Persistence contract: NONE`, `Persistence
contract: LOCAL`, or `Persistence contract: UNRESOLVED` line. UNRESOLVED is
valid only under NO-GO and leaves D14-D16 unresolved rather than inventing a
storage policy. Under NONE, D14-D16 must each select the literal `N/A -
Persistence contract NONE`; under LOCAL, none may select N/A. Cloud, sync,
telemetry, and network transmission are never alternatives. Do not recommend
numeric values or silently convert the current three-second display refresh
into an automation cadence.

Mechanically prove that no required row disappeared:

```sh
set -e
set -o pipefail
DOC='docs/product/wifi-failover-spike.md'
test "$(rg -Fxc '| ID | Decision | Options and tradeoffs | Selected value | Vincent approval source | Status |' "$DOC")" -eq 1
require_decision_row() {
  test "$(rg -c "^\\| $1 \\| $2 \\|" "$DOC")" -eq 1
}
require_decision_row D01 'Eligible trigger signals'
require_decision_row D02 'Degradation threshold and dwell'
require_decision_row D03 'Recovery threshold and hysteresis'
require_decision_row D04 'Secondary eligibility and selection'
require_decision_row D05 'Automation and consent'
require_decision_row D06 'Cooldown and retry behavior'
require_decision_row D07 'Authorization timing and explanation'
require_decision_row D08 'Status notifications and history'
require_decision_row D09 'Unavailable SSID identity'
require_decision_row D10 'Success verification'
require_decision_row D11 'Verification failure response'
require_decision_row D12 'Rollback failure behavior'
require_decision_row D13 'Managed policy rejection'
require_decision_row D14 'Retention and deletion'
require_decision_row D15 'Schema compatibility and evolution'
require_decision_row D16 'Corrupt and incompatible recovery'
require_decision_row D17 'Privacy, disclosure, and data minimization'
for id in D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17; do
  rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
    function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    {
      options=trim($4); selected=trim($5); source=trim($6); status=trim($7)
      if (options == "" || options ~ /TBD|UNRESOLVED/ || selected == "" || source == "" || status == "") exit 1
    }' || exit 1
done
test "$(rg -c '^Persistence contract: (NONE|LOCAL|UNRESOLVED)$' "$DOC")" -eq 1
```

### Step 4: Threat-model, decide GO/NO-GO, and stop before code

Cover wrong-network selection, stale profile order, duplicate/hidden SSIDs,
same-name networks, captive portals, VPN/Ethernet presence, loss of Location
access, rapid oscillation, authorization fatigue, managed Macs, commit success
with no reassociation, failed rollback, app crash mid-transaction, and another
actor editing preferred order concurrently. Also cover network metadata exposed
or retained beyond the user's intent in UI, notifications, logs, or durable
state.

Use this exact threat-table schema:

`| ID | Threat | Harm/consequence | Detection/evidence | Candidate containment/recovery | Status and owner |`

Assign `T01` through `T15` in the order listed above. Every harm, detection, and
containment cell must contain actual analysis, not a copied threat name, blank,
`TBD`, or `UNRESOLVED`. Status may remain unresolved under NO-GO. Under GO, each
status must be `ACCEPTED - Vincent approval: YYYY-MM-DD - <direct source
reference>`.

The document has only two terminal outcomes:

- `Final gate: NO-GO` when any decision remains unresolved, evidence is
  insufficient, a separately authorized live validation is still required, or
  risk is unacceptable; or
- `Final gate: GO` only when Vincent explicitly approves every applicable row,
  any persistence rows are selected or justified N/A, and all prerequisites for
  a separate implementation plan are recorded.

Record exactly one `Decision record status: APPROVED` or `Decision record
status: BLOCKED`. `GO` requires APPROVED. `NO-GO` may preserve unresolved rows
and must state the blocker. Neither outcome ships failover or authorizes source
work, live validation, profile mutation, or an authorization prompt.

Run all completeness gates independently:

```sh
set -e
set -o pipefail
DOC='docs/product/wifi-failover-spike.md'
test "$(rg -Fxc '| ID | Threat | Harm/consequence | Detection/evidence | Candidate containment/recovery | Status and owner |' "$DOC")" -eq 1
require_threat_row() {
  test "$(rg -c "^\\| $1 \\| $2 \\|" "$DOC")" -eq 1
}
require_threat_row T01 'wrong-network selection'
require_threat_row T02 'stale profile order'
require_threat_row T03 'duplicate/hidden SSIDs'
require_threat_row T04 'same-name networks'
require_threat_row T05 'captive portals'
require_threat_row T06 'VPN/Ethernet presence'
require_threat_row T07 'loss of Location access'
require_threat_row T08 'rapid oscillation'
require_threat_row T09 'authorization fatigue'
require_threat_row T10 'managed Macs'
require_threat_row T11 'commit success with no reassociation'
require_threat_row T12 'failed rollback'
require_threat_row T13 'app crash mid-transaction'
require_threat_row T14 'another actor editing preferred order concurrently'
require_threat_row T15 'network metadata exposed or retained beyond user intent'
for id in T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12 T13 T14 T15; do
  rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
    function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    {
      threat=trim($3); harm=trim($4); detection=trim($5); response=trim($6); status=trim($7)
      if (harm == "" || harm == "TBD" || harm == "UNRESOLVED") exit 1
      if (detection == "" || detection == "TBD" || detection == "UNRESOLVED") exit 1
      if (response == "" || response == "TBD" || response == "UNRESOLVED") exit 1
      if (harm == threat || detection == threat || response == threat) exit 1
      if (status == "") exit 1
    }' || exit 1
done
test "$(rg -c '^Decision record status: (APPROVED|BLOCKED)$' "$DOC")" -eq 1
test "$(rg -c '^Final gate: (GO|NO-GO)$' "$DOC")" -eq 1
if rg -q '^Final gate: GO$' "$DOC"; then
  rg -q '^Decision record status: APPROVED$' "$DOC"
  rg -q '^Capability evidence status: COMPLETE$' "$DOC"
  rg -q '^Live mutation validation prerequisite: NONE$' "$DOC"
  for id in D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17; do
    rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' -v id="$id" '
      function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
      {
        options=trim($4); selected=trim($5); source=trim($6); status=trim($7)
        if (options == "" || options ~ /TBD|UNRESOLVED/) exit 1
        if (selected == "" || selected == "UNRESOLVED" || selected == "TBD") exit 1
        if (id !~ /^D1[456]$/ && selected ~ /^N\/A/) exit 1
        if (source !~ /^Vincent approval: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] - .+/) exit 1
        if (status != "APPROVED") exit 1
      }' || exit 1
  done
  if rg -q '^Persistence contract: NONE$' "$DOC"; then
    for id in D14 D15 D16; do
      rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
        function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
        { if (trim($5) != "N/A - Persistence contract NONE") exit 1 }' || exit 1
    done
  else
    rg -q '^Persistence contract: LOCAL$' "$DOC"
    for id in D14 D15 D16; do
      ! rg "^\\| $id \\|[^|]*\\|[^|]*\\|[[:space:]]*N/A" "$DOC" || exit 1
    done
  fi
  for id in T01 T02 T03 T04 T05 T06 T07 T08 T09 T10 T11 T12 T13 T14 T15; do
    rg "^\\| $id \\|" "$DOC" | /usr/bin/awk -F'|' '
      function trim(v) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
      { if (trim($7) !~ /^ACCEPTED - Vincent approval: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] - .+/) exit 1 }' || exit 1
  done
fi
git diff --check
doc_diff_status=0
git diff --no-index -- /dev/null "$DOC" || doc_diff_status=$?
test "$doc_diff_status" -eq 1
```

Repeat the heading, capability, and decision-row gates from Steps 1 and 3 at
closeout. Then run the repository allowlist, inspect the no-index document diff
and README diff, and update only Plan 019's README status cell to `DONE`. `DONE`
means the decision spike finished with either GO or NO-GO; it never means
failover shipped.

```sh
set -e
set -o pipefail
PLAN019_BASE='<dispatcher-supplied-execution-base-commit>'
test "$PLAN019_BASE" != '<dispatcher-supplied-execution-base-commit>'
git cat-file -e "$PLAN019_BASE^{commit}"
test "$(git rev-parse HEAD)" = "$PLAN019_BASE"
unstaged="$(git diff --name-only "$PLAN019_BASE" -- .)"
staged="$(git diff --cached --name-only "$PLAN019_BASE" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk '
  NF && $0 != "docs/product/wifi-failover-spike.md" && $0 != "plans/README.md" { print }
')"
test -z "$unexpected"
git diff "$PLAN019_BASE" -- plans/README.md
test "$(git show "$PLAN019_BASE:plans/README.md" | rg -Fxc '| 019 | Decide a safe known-network Wi-Fi failover contract | P3 | M | — | TODO |')" -eq 1
test "$(git show "$PLAN019_BASE:plans/README.md" | rg -c '^\| 019 \|')" -eq 1
test "$(git diff --numstat "$PLAN019_BASE" -- plans/README.md | /usr/bin/awk '{print $1 " " $2}')" = '1 1'
test "$(rg -Fxc '| 019 | Decide a safe known-network Wi-Fi failover contract | P3 | M | — | DONE |' plans/README.md)" -eq 1
test "$(rg -c '^\| 019 \|' plans/README.md)" -eq 1
! rg -Fxq '| 019 | Decide a safe known-network Wi-Fi failover contract | P3 | M | — | TODO |' plans/README.md
```

## Test plan

There is no production test suite change. Proof consists of the SDK-header
citations, a compile-only capability probe, document completeness checks, scope
allowlist, no-index document diff, and local manual review. Review must confirm
no executable was produced or run, no profile/SSID data was read or logged, and
GO is impossible while any product policy is unresolved.

## Done criteria

- [ ] The document distinguishes SDK facts, compile facts, platform evidence,
      product choices, and unproven live behavior.
- [ ] The compile-only probe succeeds under the explicit Xcode 26.5 SDK and is
      never run.
- [ ] No Keychain/credential path exists and only already-known profiles are in
      the future transaction boundary.
- [ ] Consent, authorization, verification, rollback, concurrency, and failure
      states are fully specified without numeric/default policy choices.
- [ ] Every trigger, hysteresis, cooldown, persistence, and notification choice
      is marked for Vincent.
- [ ] Persisted-state choices include explicit retention/deletion, schema
      evolution, and corrupt/incompatible recovery; otherwise all three are N/A
      under `Persistence contract: NONE`, or remain explicitly unresolved under
      a NO-GO `Persistence contract: UNRESOLVED` gate.
- [ ] The threat model covers identity ambiguity and rollback failure.
- [ ] The terminal gate is exactly GO or NO-GO; GO has Vincent's explicit
      approval and contains no unresolved decision.
- [ ] Only the decision document and Plan 019 status cell differ.
- [ ] Scratch finalization and owner closeout pass.
- [ ] No app/source/network/configuration/auth/install/launch/push action ran.

## STOP conditions

Stop and report if:

- the isolated checkout is dirty, owner ID unavailable, or output doc has
  unrelated ownership;
- the installed SDK lacks the required read/order/commit symbols;
- any evidence requires running the probe or changing live Wi-Fi state;
- feasibility requires reading credentials, Keychain, creating a new profile,
  scanning networks, or logging SSIDs;
- the design cannot preserve and restore the complete original order;
- a persisted-state design lacks retention, schema, or corrupt-state policy;
- a policy choice would need to be invented to complete the document; or
- the scope guard or CLAYGO closeout fails.

## Maintenance notes

Keep observation and mutation separate. `NetworkMonitor` can remain the source
of displayed connection facts, but a later privileged transaction must have
its own explicit authorization, serialization, verification, and rollback
boundary. Never equate preferred-order commit with proven live failover until
that behavior is validated under separately authorized, recoverable conditions.
