# Opt-in peripheral battery alerts

## Status

Decision status: PENDING

Implementation status: Not shipped

Plan 009 source is integrated for review; its compiler/test gates remain part
of the queue-wide verification. No notification, permission request, device
scan, cadence change, persistence, install, or launch was performed for this
spike.

## Evidence and fixed constraints

- `ConnectedDevice` exposes a display-oriented string ID, device kind, and one
  optional battery fraction (`ConnectedDevices.swift:7-40`). `lowBattery` is a
  visual/sort classification through `MetricPresentationPolicy`, not an
  approved interruption threshold.
- `MetricPresentationPolicy` classifies battery display states at its current
  visual boundaries, and the adjacent architecture note explicitly separates
  visual state from interruption (`MetricPresentationPolicy.swift:82-90,
  168-175`). No existing value is inherited as an alert policy.
- Plan 009 admits one running refresh and coalesces overlapping requests into at
  most one pending follow-up (`ConnectedDevices.swift:43-64,99-120`). It adds no
  polling or freshness policy.
- A future evaluator may consume only completed existing `DeviceMonitor.devices`
  publications (`ConnectedDevices.swift:67-72,105-120`). No new scan, timer, or
  `system_profiler` call is allowed, and no discovery cadence change is allowed
  by this spike.
- Bluetooth identity is currently `bt:<display name>`, so duplicates and renames
  are ambiguous (`ConnectedDevices.swift:230-243`). Missing or failed profiler
  evidence produces absent devices rather than a typed failure
  (`ConnectedDevices.swift:219-227`).
- Multi-battery reports collapse left, right, and case values to the lowest
  available fraction, discarding component identity
  (`ConnectedDevices.swift:250-259`). Drives and USB iOS rows do not currently
  publish battery evidence.
- `AppState` owns one process-lifetime `DeviceMonitor` (`AppState.swift:47`), and
  no notification authorization/delivery subsystem exists in current source.
- The fixed boundary is local-only with no cloud or sync, accounts, telemetry,
  or cross-device alert history.

Static source establishes these seams but cannot prove notification usefulness,
identity stability, permission behavior, or user acceptance.

## Threat model

| Threat | Current evidence | Possible user harm | Controlling decision | Validation scenarios |
|---|---|---|---|---|
| Stale battery value | Snapshots have no battery observation timestamp/freshness contract | An old low value interrupts after the device recovered | Freshness/failure behavior, repeat policy | Repeated snapshots, delayed publication, restart |
| Missing battery value | `battery` is optional and several kinds always publish nil | Missing evidence may be mistaken for recovery or suppress a useful warning | Eligible kinds and missing/stale behavior | Known device goes low then nil; first observation nil |
| Profiler failure or empty results | Parser failure returns empty Bluetooth/USB arrays | Every device may appear disconnected and suppression state may reset | Failure and disconnect cleanup | Error/empty snapshot after low reading, followed by recovery |
| Duplicate or renamed identity | Bluetooth ID derives from display name | One device can suppress another, or a rename can cause duplicate alerts | Identity/reconnect decisions | Same-name devices; rename while low; rename after recovery |
| Threshold flapping | No alert hysteresis is defined | Notifications repeat around a boundary | Threshold/hysteresis and cooldown | Alternating values around both selected boundaries |
| Disconnect and reconnect | Snapshot absence has no alert-state semantics | Reconnect may storm, or old suppression may hide a real event | Reconnect/disconnect cleanup | Low-disconnect-reconnect-low and recovered reconnect |
| Multiple simultaneous low devices | A snapshot can contain several low values | Burst notifications interrupt and obscure device identity | Batching/deduplication/content | Several eligible devices cross in one publication |
| Alert storm | No cooldown, repeat, or delivery ledger exists | Repeated completed snapshots create noisy interruptions | Cooldown/deduplication/repeat | Identical low snapshots and alternating failure/reconnect |
| Notification permission denial | No permission UX exists | Silent failure or repeated prompting erodes trust | Permission timing and denial/recovery UX | Undetermined, denied, allowed, later Settings change |
| Privacy-sensitive content/actions | Names and battery state can appear outside the app | Lock-screen disclosure or unsafe click behavior | Notification content/actions | Hidden preview, click, dismissal, action selection |
| Corrupt or incompatible local state | Relevant only if persistence is explicitly selected | Alerts are suppressed or repeated unpredictably | Persistence, compatibility, recovery | Truncated, unknown, incompatible, and tampered state |

Every response in this table remains a decision/test obligation, not a selected
mitigation.

## Decision ledger

| Decision | Neutral options and tradeoffs | Vincent decision | Rationale/source |
|---|---|---|---|
| Eligible device types | Bluetooth-only, other evidence-backed kinds, or an explicit subset; broader scope increases missing/identity ambiguity | PENDING | PENDING |
| Alert threshold and hysteresis | Exact downward and recovery boundaries trade responsiveness against flapping; no current visual value is a default | PENDING | PENDING |
| Cooldown and deduplication | Per-device or batched identity, repeat/suppression behavior, and exact timing all change interruption risk | PENDING | PENDING |
| Reconnect and disconnect cleanup | Preserve, reset, or reconcile state on absence/identity change; each risks storms or stale suppression | PENDING | PENDING |
| Notification permission UX | Ask at opt-in, first eligible event, or another explicit point; denial/recovery copy and Settings path differ | PENDING | PENDING |
| Notification content and actions | Privacy level, device naming, click destination, and optional actions change disclosure and completion semantics | PENDING | PENDING |
| Persistence or session scope | Process/session-only state versus local persistence changes restart behavior and privacy/lifecycle obligations | PENDING | PENDING |
| Multi-battery semantics | Current lowest-value composite, component-aware evidence, or an explicit subset; component support expands the source model | PENDING | PENDING |
| Missing stale and failure behavior | Hold, clear, suppress, or surface uncertainty; none can be inferred as recovery | PENDING | PENDING |
| Opt-in surface | Exact discovery/consent location and a reversible disable path must be chosen | PENDING | PENDING |
| Retention and deletion | Mandatory if any state persists; lifecycle and verified clearing must be explicit | PENDING | PENDING |
| Schema compatibility and evolution | Mandatory if any state persists; compatibility, migration, and unknown fields need explicit ownership | PENDING | PENDING |
| Corrupt and incompatible recovery | Mandatory if any state persists; preserve, quarantine, replace, or approved deletion have different risks | PENDING | PENDING |

No recommendation or agent assumption is recorded as a decision. If Vincent
selects process/session-only behavior with no persistence, the final three rows
still require his explicit `NOT APPLICABLE — no persistence` decision.

## Policy/state model

Inputs are successive completed `[ConnectedDevice]` snapshots only. The state
and transition outputs cannot be selected until the ledger is resolved.

| Scenario | Evidence input | Required unresolved policy | Current outcome |
|---|---|---|---|
| First observation | First eligible device value | Whether an already-low first value alerts | BLOCKED on ledger |
| Downward crossing | Prior value above, new value below selected boundary | Exact boundary and eligibility | BLOCKED on ledger |
| Recovery | Value reaches selected recovery condition | Hysteresis and suppression reset | BLOCKED on ledger |
| Repeated low | Consecutive low snapshots | Cooldown, deduplication, and repeat | BLOCKED on ledger |
| Missing reading | Known row has nil battery or disappears through failed evidence | Missing/stale/failure behavior | BLOCKED on ledger |
| Duplicate identity | More than one physical device maps to one ID | Identity and fail-closed behavior | BLOCKED on ledger |
| Disconnect | Device absent from a completed snapshot | Disconnect cleanup versus evidence failure | BLOCKED on ledger |
| Reconnect | Device reappears with same or changed display ID | Reconnect and identity policy | BLOCKED on ledger |
| Simultaneous devices | Several devices cross in one publication | Batching, priority, and content | BLOCKED on ledger |
| Permission state | Undetermined, denied, allowed, or later changed | Permission timing and recovery UX | BLOCKED on ledger |
| Restart/session boundary | Evaluator process restarts | Persistence/session scope and lifecycle | BLOCKED on ledger |
| Delivery failure | Intent cannot be delivered | Repeat/suppression and local status behavior | BLOCKED on ledger |

Scratch model: not used. Without selected policy, an executable model would
only encode agent assumptions.

## GO or NO-GO

Final gate: not yet selected

Vincent must resolve every applicable ledger row with rationale, review the
resulting state table, and then choose exactly GO or NO-GO. GO would authorize a
later implementation plan only. NO-GO would record its rationale and the
evidence or decision that could justify reopening. This PENDING record cannot
be marked DONE.

## Implementation outline if GO

Withheld while decisions are PENDING. A future GO outline must name a pure
snapshot evaluator, identity and state ownership, a notification permission and
delivery adapter, an opt-in/disable surface, deterministic scenario tests,
permission UX tests, and live acceptance gates. It may not add scan cadence or
choose unresolved defaults. Persistence, if selected, additionally requires
explicit retention/deletion, compatibility/evolution, and corrupt-state
recovery contracts.

## Deferred/non-goals

- No production source, test fixture, preference, permission, entitlement,
  notification, timer, background task, scan, or `system_profiler` change.
- No cloud, sync, accounts, telemetry, cross-device history, or remote delivery.
- No threshold, hysteresis, cooldown, repeat interval, identity rule, retention,
  deletion, migration, recovery, or alert action chosen by the executor.
- No install, launch, live notification, permission request, Git publication, or
  claim that the feature shipped.
