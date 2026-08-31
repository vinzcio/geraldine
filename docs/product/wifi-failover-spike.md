# Known-network Wi-Fi failover feasibility

## Status

Implementation status: Not shipped

- Source commit inspected: `cd1d604` (2026-08-31 local execution base).
- Toolchain: `/Applications/Xcode.app/Contents/Developer`, macOS SDK 26.5.
- Probe: compile-only Swift typecheck; no executable was produced or run.
- Reproduction record: the exact inert source template, Xcode 26.5 SDK gate,
  `swiftc -typecheck` command, forbidden-construct checks, and no-binary check are
  retained in `plans/019-design-known-network-wifi-failover.md` under
  "Commands and exact gates"; the recorded result was exit 0 on 2026-08-31.
- Live Wi-Fi mutation, scan, association, profile reorder, authorization prompt,
  Keychain access, installation, and launch were not performed.

Capability evidence status: BLOCKED

Live mutation validation prerequisite: REQUIRED - immediate reassociation, authorization frequency, managed-policy behavior, and rollback reliability require a separately authorized recoverable live test

Decision record status: BLOCKED

## Evidence classification

- **SDK fact**: a declaration present in the installed Xcode 26.5 headers.
- **Compile-probe fact**: the inert template typechecked against that SDK.
- **Documented platform behavior**: behavior stated by an Apple framework header
  or Geraldine's current documented permission adapter.
- **Product decision**: a policy Vincent must select explicitly.
- **Unproven live behavior**: behavior that headers and compilation cannot prove
  without changing a real Mac's network configuration.

Header and compile facts establish that an ordered profile configuration can be
constructed and submitted. They do not establish that committing order changes
the active connection, how often authorization appears, or whether macOS/MDM
will accept and reliably reverse the mutation.

## Fixed constraints

Local-only boundary: No cloud, sync, telemetry, or network transmission

Credential boundary: No Keychain or credential access

- Operate only on profiles already present in macOS's preferred-network order.
- Never manufacture a profile, scan for nearby networks, request a password, or
  log an SSID/profile identity.
- Trigger and verification evidence is passive OS/CoreWLAN/interface evidence
  only. Any active reachability or packet probe would transmit network data and
  is outside this spike unless Vincent separately approves its destination,
  payload, disclosure, timing, and failure contract.
- Observation and mutation remain separate ownership seams.
- Any future mutation requires explicit consent, bounded transaction ownership,
  verification, and an approved failure/rollback policy.
- This spike does not authorize source work, live validation, authorization,
  installation, or launch.

## Capability map

| ID | Capability question | Evidence class | Evidence/reference | Result | Status |
|---|---|---|---|---|---|
| C01 | Read current configuration | SDK fact | `CWInterface.h:273-278` declares `configuration()` | The installed SDK provides an optional immutable interface configuration | ESTABLISHED |
| C02 | Preserve ordered known-network profiles | SDK fact | `CWConfiguration.h:31,54` declares `NSOrderedSet<CWNetworkProfile *> *networkProfiles` | The complete preferred-network order has an ordered snapshot representation | ESTABLISHED |
| C03 | Construct reordered mutable configuration | compile-probe fact | `CWConfiguration.h:183-197`; inert probe copied the configuration and assigned `networkProfiles` | The SDK accepts an ordered profile set on `CWMutableConfiguration` at compile time | ESTABLISHED |
| C04 | Typed authorization and commit boundary | compile-probe fact | `CWInterface.h:653-674`; `SFAuthorization.h:15-33`; inert commit branch typechecked | A commit accepts a configuration, optional `SFAuthorization`, and error boundary | ESTABLISHED |
| C05 | Credential exposure boundary | SDK fact | Public `CWNetworkProfile.h:1-240` exposes SSID/security metadata but no credential accessor; probe touches neither | The proposed seam needs no credential or Keychain API and none is permitted | ESTABLISHED |
| C06 | Priority commit implies immediate reassociation | unproven live behavior | Commit headers describe writing configuration to disk but make no reassociation guarantee | A successful priority commit cannot be treated as proof that the active connection changed | UNPROVEN |
| C07 | Location or SSID access denied | documented platform behavior | `NetworkInfo.swift` publishes no SSID without Location authorization; mutation behavior is undocumented here | Display identity fails closed, but safe candidate identity and mutation behavior remain unproven | UNPROVEN |
| C08 | Managed-device or administrator policy | unproven live behavior | Commit API can return an error and may require authorization; no inspected header defines MDM outcomes | Rejection, authorization frequency, and managed-Mac behavior are unknown | UNPROVEN |
| C09 | Rollback from exact snapshot | unproven live behavior | Ordered snapshot and reassignment typecheck, but no live restore was attempted | Exact order can be represented, but successful recovery after a real commit is unproven | UNPROVEN |

## Transaction and rollback options

A future transaction, if separately planned, has these states:

`observing → candidate proposed → user consent → authorization → snapshot exact order → commit one reorder → verify connection and order → success or selected failure response`

Required invariants:

- Snapshot the complete original ordered profile set immediately before mutation.
- Move only two already-known profiles and preserve every other profile's order
  and metadata.
- Serialize transactions; a second observation cannot start another reorder.
- Authorization denial or cancellation produces no mutation.
- Verify committed order separately from connection identity/quality.
- Never infer success from a nil error alone.

No rollback behavior is selected. Vincent must choose between an automatic
single rollback attempt, an offered rollback requiring fresh consent, or no
second mutation. A separate choice is required for rollback failure. Retry
counts, deadlines, cooldowns, and cease-automation behavior remain unresolved.

## Vincent decision matrix

Persistence contract: UNRESOLVED

| ID | Decision | Options and tradeoffs | Selected value | Vincent approval source | Status |
|---|---|---|---|---|---|
| D01 | Eligible trigger signals | Passive RSSI, link rate, OS-reported reachability/quality, or an explicitly approved passive combination; active probes are outside this spike and require a separate network-transfer decision | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D02 | Degradation threshold and dwell | Exact threshold, dwell, and hysteresis values balance responsiveness against oscillation | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D03 | Recovery threshold and hysteresis | Exact recovery definition and separation from degradation determine when automation may re-arm | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D04 | Secondary eligibility and selection | User-selected known profiles, an approved ordered subset, or another explicit eligibility rule | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D05 | Automation and consent | Manual-only, confirm each time, or explicit opt-in automation have different interruption and outage risks | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D06 | Cooldown and retry behavior | Separate approved behavior is needed after success, failure, denial, and any rollback | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D07 | Authorization timing and explanation | Request only at confirmed mutation time or another explicitly approved point, with exact user-facing rationale | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D08 | Status notifications and history | Ephemeral status, local history, and notification choices change persistence and interruption costs | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D09 | Unavailable SSID identity | Stop, request Location access, or use another explicitly approved stable identity; never guess by display text | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D10 | Success verification | Exact order, connection identity, reachability, and quality evidence required for success must be selected | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D11 | Verification failure response | Automatic rollback, offered rollback, or no second mutation require an explicit owner and trigger | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D12 | Rollback failure behavior | Stop, notify, disable future automation, or another approved response must not be inferred | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D13 | Managed policy rejection | Stop, explain, suppress future attempts, or another approved response depends on managed-device expectations | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D14 | Retention and deletion | If any preference, cooldown, status, or history persists, exact retention and deletion behavior is required | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D15 | Schema compatibility and evolution | Any local persisted state needs versioning and compatibility rules | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D16 | Corrupt and incompatible recovery | Any local persisted state needs a fail-closed recovery and deletion contract | UNRESOLVED | UNRESOLVED | UNRESOLVED |
| D17 | Privacy, disclosure, and data minimization | Select exactly which SSID/profile/security/quality/transaction fields may appear in the app or lock-screen notifications, which may persist locally, what is redacted, and how the user clears it; no field set or disclosure is implied | UNRESOLVED | UNRESOLVED | UNRESOLVED |

## Threat and failure model

| ID | Threat | Harm/consequence | Detection/evidence | Candidate containment/recovery | Status and owner |
|---|---|---|---|---|---|
| T01 | wrong-network selection | The Mac may lose service or join an unintended trust boundary | Compare stable profile identity and full pre-commit snapshot before mutation | Require explicit candidate selection and stop on any identity ambiguity | UNRESOLVED |
| T02 | stale profile order | A reorder may overwrite a user's or system's newer preference change | Re-read and compare complete order immediately before commit | Abort when the live order differs from the consented snapshot | UNRESOLVED |
| T03 | duplicate/hidden SSIDs | Display names cannot uniquely identify the intended known profile | Detect missing or duplicate visible identifiers in the candidate set | Fail closed and require an approved stable-identity method | UNRESOLVED |
| T04 | same-name networks | A same-name profile can cross security or location expectations | Compare profile identity/security metadata rather than display text alone | Never choose by SSID string alone; request explicit resolution | UNRESOLVED |
| T05 | captive portals | Apparent connectivity may still block useful network access | Verification must distinguish association from usable reachability | Treat captive/limited access as verification failure under the selected policy | UNRESOLVED |
| T06 | VPN/Ethernet presence | Another route can make Wi-Fi quality signals misleading | Observe active interface/route context before proposing a candidate | Suppress mutation when an approved route-context rule is not satisfied | UNRESOLVED |
| T07 | loss of Location access | SSID identity disappears and a candidate can no longer be proven | `NetworkMonitor.nameAccess` and nil identity expose the loss | Stop without mutation; never fall back to guessed display identity | UNRESOLVED |
| T08 | rapid oscillation | Repeated reorders can disrupt connectivity and authorization trust | Record transaction ownership and selected hysteresis/cooldown state | Serialize and apply only explicitly approved hysteresis and cooldown rules | UNRESOLVED |
| T09 | authorization fatigue | Repeated prompts can train unsafe approval or block work | Count only transaction-local prompt outcomes under an approved persistence contract | Request at the selected point and stop after the approved denial behavior | UNRESOLVED |
| T10 | managed Macs | MDM or administrator policy may reject or reverse changes | Preserve commit errors and compare post-commit order without profile contents in logs | Stop and surface a local explanation; do not bypass policy | UNRESOLVED |
| T11 | commit success with no reassociation | The preferred order changes while the degraded connection remains active | Verify connection identity/quality separately from committed order | Do not report success; apply only the selected failure response | UNRESOLVED |
| T12 | failed rollback | The Mac may remain on an unwanted order after recovery is attempted | Compare restored order against the exact snapshot and record only local status | Stop further mutations and apply the explicitly approved failure behavior | UNRESOLVED |
| T13 | app crash mid-transaction | Ownership and the original order may be lost between commit and verification | Define durable transaction evidence only if Vincent approves persistence | Without an approved crash contract, automation remains NO-GO | UNRESOLVED |
| T14 | another actor editing preferred order concurrently | A rollback can erase a newer user or system change | Re-read order before commit, verification, and any rollback | Abort or request new consent whenever snapshot ownership is stale | UNRESOLVED |
| T15 | network metadata exposed or retained beyond user intent | SSID/profile/security/quality or transaction details may reveal location and network habits in UI, notifications, logs, or durable state | Inventory every field and surface against D17 and the selected persistence contract | Minimize and redact by default; remain NO-GO until Vincent approves display, notification, retention, and clearing behavior | UNRESOLVED |

## Final gate

Final gate: NO-GO

The SDK and compile probe establish a typed configuration boundary, but four
capability rows remain unproven, live validation is separately required, every
product decision is unresolved, persistence is unresolved, and no threat has
Vincent's accepted-risk record. This outcome completes the evidence spike only.
It does not ship or authorize Wi-Fi failover.

## Implementation-plan prerequisites

- Vincent-approved values and sources for D01-D17, including explicit
  persistence, privacy/disclosure, retention, schema, and recovery decisions.
- Accepted owner/status for T01-T15.
- A separately authorized, recoverable live-validation protocol proving
  reassociation, authorization, managed-policy, and exact rollback behavior.
- A new implementation plan with typed observation, transaction, authorization,
  verification, and recovery ownership; no Keychain or credential seam.
- Fresh source, SDK, privacy, entitlement, test, installed-bundle, and physical
  interaction review before any shipping claim.
