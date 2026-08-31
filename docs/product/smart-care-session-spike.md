# Resumable Smart Care sessions

> **Design spike only — Geraldine behavior is unchanged. `DONE` means this
> document is complete, not that resumable Smart Care sessions shipped.**

Implementation status: feature not shipped

Decision gate: NO-GO — required Vincent decisions unresolved

## Evidence and current ownership

- `Finding` receives a new runtime UUID for every construction; title, detail,
  severity, module, and score penalty are presentation/result data rather than a
  durable rule identity (`SmartCareView.swift:3-56`).
- The current rule families are disk capacity, reviewable junk, memory usage,
  and user launch-agent count (`SmartCareView.swift:143-251`). Each family emits
  good, warning, bad, or limited-evidence variants without a stable key.
- The Plan 012 boundary owns one cancellable scan task. A replacement cancels
  and awaits its predecessor, checks cancellation before and after the injected
  scanner, and publishes only through the latest `scanID`
  (`SmartCareView.swift:65-137`). Persisted state must not restore a `Task`,
  bypass this generation guard, or introduce another scanner/coordinator.
- Published results, score, date, and phase are in-memory view-model state
  (`SmartCareView.swift:68-74,253-258`). Queue membership is separate view-local
  UUID state and a rescan clears it (`SmartCareView.swift:273-280,418-427`).
- Opening a finding only changes the selected module. It produces no completion
  receipt and cannot prove that the user completed an action
  (`SmartCareView.swift:446-449`).
- Static source inspection proves ownership and data flow only. It does not
  prove restart behavior, product acceptance, or a shipped persistence feature.

## Goals and non-goals

The fixed direction to investigate is local-only resumable Smart Care sessions,
stable finding keys, restart/revalidation, and completion reconciliation. A
future design should make stored evidence visibly distinguishable from newly
validated evidence and preserve Plan 012's single-worker publication boundary.

This spike does not select a store, production path, serialization format,
schema value, migration, retention or freshness duration, size ceiling, quota,
automatic-resume behavior, deletion/recovery behavior, or action-history
policy. It adds no cloud, sync, telemetry, encryption, worker, runtime behavior,
or implementation plan.

## Stable finding identity candidates

A stable key should name the rule family, not a severity variant, title/detail,
score penalty, array position, destination module, or scan UUID. The current
candidate families are disk capacity, reviewable junk, memory usage, and user
launch-agent count.

| Candidate | Benefits | Risks and evolution burden |
|---|---|---|
| Namespaced string key | Can preserve unknown future keys and makes stored references inspectable | Typos and renames are runtime failures; ownership and version interpretation need a registry |
| Typed enum key | Exhaustive handling in current source and direct rule ownership | Unknown future cases need a separate representation; split, merge, and retirement still require explicit compatibility policy |

Both candidates remain stable across severity/content changes only if rule
ownership treats the identifier as an enduring contract. Neither resolves a
rename, collision, retired rule, one-to-many split, many-to-one merge, or an
unknown incompatible key automatically. A queued or completed key absent from a
revalidated scan could mean recovery, rule retirement, missing evidence, or
drift; it must not be silently treated as completed.

Proposal-only pseudotype, not a selected schema:

```text
RuleKey
FindingEvidence { ruleKey, observedValues, severity, confidence, routeHint }
SessionMetadata { scanIdentity, observationTime, validationState }
QueueReference { ruleKey }
CompletionEvidence { ruleKey, evidenceKind, observationReference }
```

Dynamic copy and derived score can be recomputed from revalidated evidence;
whether any of them are persisted is UNRESOLVED.

## Persistence and state-model options

| Shape | Candidate fields | Atomic boundary and owner | Testability | Privacy/corruption/evolution tradeoff |
|---|---|---|---|---|
| One replaceable current-session snapshot | Session metadata, rule-keyed evidence, optional queue/score | One candidate persistence owner replaces one complete snapshot after an accepted publication | Deterministic encode/decode, interruption, replacement, and revalidation tests | Smallest surface, but no completion chronology; one corrupt object can hide the whole prior session |
| Snapshot plus action/completion journal | Snapshot fields plus rule-keyed actions/receipts | Snapshot replacement and append/reconcile boundaries need separately defined ownership | Ordering, duplicate, replay, truncation, and cross-boundary crash tests | More health/activity history and a larger reconciliation/corruption surface |
| Independently keyed finding records plus session metadata | Per-rule evidence and references plus session envelope | Multi-record commit or manifest ownership is required to prevent mixed sessions | Partial-write, orphan, missing-key, and concurrent-instance tests | Selective recovery is possible, but schema evolution and partial-state ambiguity are greatest |

Each shape is an option only. The read/write owner, atomic-replacement mechanism,
durability expectation, and treatment of a prior complete snapshot after a
failed write are unresolved. Stored content must be treated as untrusted local
data. No production location or representation is selected.

Candidate persisted-session availability is separate from the runtime scan
phase:

```text
no stored session ─┐
readable stored session ──> available but unvalidated ──> revalidation ──> reconciled result
unreadable or incompatible ─> blocked recovery choice
                         scan failure ─> prior snapshot disposition unresolved
```

Plan 012 continues to own only `idle → scanning → results` and the one current
task. Persistence availability must not masquerade as that task state.

## Restart and revalidation options

| Restart option | What the user can see | Main risk | Required proof/decision |
|---|---|---|---|
| Revalidate before presenting current results | Stored data may support continuity internally, but current claims appear only after a fresh scan | A failed or partial scan leaves the disposition of the prior snapshot unresolved | Failure copy, partial-evidence rules, cancellation tests, and freshness decision |
| Present stored results as explicitly unvalidated, then revalidate | Continuity is immediate and visually labeled | Stale findings may still influence navigation or trust | Strong stale-state UI, route disabling rules, and user acceptance |
| Require manual resume | The user chooses whether to read/revalidate stored state | Sessions may be overlooked and startup behavior may feel inert | Consent copy, clearing behavior, and manual-flow acceptance |

Cancellation or replacement must flow through Plan 012: cancel the current task,
await it, then begin revalidation; only the newest scan identity may publish.
Termination mid-write, scan failure, missing permissions, or partial evidence
cannot implicitly promote stored results to current. Whether the last complete
snapshot remains visible, is preserved but hidden, or is replaced is UNRESOLVED.

## Completion reconciliation options

Navigation is not completion. Candidate approaches are:

| Signal | False-positive risk | False-negative risk | Ownership expansion |
|---|---|---|---|
| Infer from a later fresh scan by stable key | A rule may disappear because evidence was unavailable or thresholds changed | A legitimate action may not immediately change measured evidence | Mostly Smart Care, but every rule needs explicit absence/evidence semantics |
| Receive explicit downstream-module receipts | A weak receipt may record opening or attempted work as success | Existing modules without receipts cannot reconcile | Expands contracts into Cleanup, Storage, Activity, Login Items, and future modules |
| Manual acknowledgement | The user can mark unfinished work complete accidentally | Users may omit acknowledgement | Adds explicit Smart Care interaction and copy ownership |

A future policy must define what constitutes completion, how conflicting
signals reconcile, whether history exists, and how an absent/retired/split key
is handled. No candidate is selected.

## Threat and failure model

| Failure/threat | Harm | Detection | Candidate fail-closed response | Required decision/test |
|---|---|---|---|---|
| Termination mid-write or truncated data | Mixed or unreadable health state | Integrity/complete-read failure | Do not publish it as current; preserve evidence for the selected recovery path | Atomic interruption tests and corrupt recovery decision |
| Incompatible stored data | Older/newer meaning is misread | Compatibility check rejects it | Block resume and explain locally | Schema-evolution and recovery decisions |
| Stale or incompletely revalidated findings | Incorrect health claims or routes | Per-rule evidence state and scan outcome | Label or withhold according to an approved policy | Freshness/partial-evidence decision and UI tests |
| Invalid or destructive route | A stale finding opens unsafe work | Validate current rule/action ownership before routing | Disable the route rather than infer a target | Route contract and cross-feature tests |
| Stable-key collision or drift | Evidence attaches to the wrong rule | Registry/typed ownership and duplicate-key checks | Reject ambiguous records | Key ownership and collision fixtures |
| Rule split, merge, or retirement | Queue/history meaning changes | Compatibility layer encounters changed ownership | Preserve as unresolved or block; never infer completion | Evolution decision and fixtures |
| Queued/completed key absent after scan | Work is lost or falsely completed | Reconciliation compares keys and evidence availability | Surface as unresolved under the chosen UI policy | Completion and missing-evidence decisions |
| Plan 012 cancellation/replacement race | Stale scan overwrites a newer result | Task cancellation plus latest `scanID` guard | Drop stale publication; never restore active work | Existing Plan 012 tests plus persistence integration tests |
| Duplicate publication | Store and UI diverge | Publication identity/idempotency checks | Accept at most the authorized latest publication | Persistence-owner tests |
| Permission or read failure | Partial evidence appears complete | Scanner reports unavailable/limited evidence | Do not convert unavailable evidence into a good result | Revalidation policy and permission tests |
| Read-only or full-disk write failure | New state is not durable | Write/replace error | Keep runtime result separate; do not claim it is resumable | Failure copy and prior-snapshot decision |
| Rename/replace failure | Partial store or lost prior snapshot | Post-write verification | Retain the last provably complete boundary when possible; otherwise block | Atomicity design and injected failures |
| Overlapping app instances | Last writer erases newer state | Ownership/compare-before-replace check | Refuse ambiguous concurrent write | Instance-ownership decision and race tests |
| Local tampering | Forged health findings or routes | Validate structure, keys, values, and action ownership | Treat data as untrusted and block invalid content | Decoder and route-validation tests |
| Unsafe link or path replacement | Reads/writes escape intended storage | File identity/type and ownership checks | Refuse the operation | Storage-location design and filesystem fixtures |
| Local health-data disclosure | Other users/processes or shoulder-surfing see sensitive state | Permission and UI inventory review | Minimize fields and disclose storage/clearing | Privacy decision and permission inspection |
| Failed recovery or deletion | Data remains, disappears, or loops on launch | Verify outcome and surface failure | Stop automatic recovery; retain explicit status | Recovery/deletion decision and failure tests |
| Unprovable completion | Work is marked done without evidence | Receipt/source cannot meet the selected contract | Keep completion unresolved | Completion-owner decision and negative tests |

These are candidate containment strategies, not adopted product policy.

## Privacy and local-data inventory

Candidate data includes rule keys, scan time, disk capacity/free-space evidence,
aggregate cache/log/Trash size, live memory fraction, user LaunchAgents count,
confidence/severity, score, queue membership, route hints, and any selected
completion evidence. This is local health metadata even when it contains no file
contents. Some route/action records can reveal user intent.

The fixed boundary is local-only: no cloud, cross-device sync, telemetry, or
network transmission. The still-unresolved disclosure must say what is stored,
where it is visible, how the user clears it, which observations are revalidated,
and what remains after failure. Data minimization, file permissions, retention,
and deletion/recovery behavior require explicit decisions and verification.

## Vincent decision matrix

| Decision | Options and tradeoffs | Vincent decision | Date/source | Consequence |
|---|---|---|---|---|
| Persistence scope | Session metadata only; findings; queue; score; actions; diagnostics, with increasing continuity and privacy/corruption surface | UNRESOLVED | UNRESOLVED | Storage shape and field inventory cannot be selected |
| Retention and deletion | Replace/remove events, manual clearing, and deletion promise; no duration selected | UNRESOLVED | UNRESOLVED | Lifecycle and failure handling remain blocked |
| Freshness and revalidation | Always revalidate, expose explicitly unvalidated state, or require selected checks for partial/unavailable evidence; no expiry selected | UNRESOLVED | UNRESOLVED | Restart presentation cannot be selected |
| Auto versus manual resume | Automatic startup/on-appear behavior, explicit prompt, or manual-only with different interruption/consent costs | UNRESOLVED | UNRESOLVED | Resume trigger and copy remain blocked |
| Completed/action history | No history, fresh-scan inference, downstream receipts, manual acknowledgement, or an approved combination | UNRESOLVED | UNRESOLVED | Reconciliation ownership remains blocked |
| Schema evolution | Compatibility, unknown keys, split/merge/retirement, and migration behavior; no default/migration selected | UNRESOLVED | UNRESOLVED | Durable representation cannot be selected |
| Privacy disclosure | Exact data, local location description, visibility, clearing, and health-metadata copy | UNRESOLVED | UNRESOLVED | User-facing disclosure and minimization remain blocked |
| Corrupt/incompatible recovery | Fail closed, preserve, quarantine, replace, or approved deletion with different loss/privacy risks | UNRESOLVED | UNRESOLVED | Recovery implementation and tests remain blocked |

## GO / NO-GO gate

Final gate: NO-GO

Required Vincent decisions remain UNRESOLVED. A GO requires all eight rows to
contain direct decisions with a date/source, Plan 012 integrated and verified,
stable-key ownership defined, an accepted response/test obligation for every
threat, and an authorized owner for completion signals. GO would authorize only
a separate implementation plan; it would not ship the feature.

This NO-GO is a valid completed-spike result: the decision surface is explicit,
but resumable sessions remain feature not shipped.

## Implementation-plan prerequisites

- Direct Vincent decisions and sources for every matrix row.
- Stable rule-key ownership plus collision, rename, retirement, split, merge,
  and unknown-key behavior.
- A selected persistence shape and single read/write owner that remains outside
  Plan 012's task ownership.
- Approved restart, partial-evidence, prior-snapshot, and completion contracts.
- Accepted threat responses and deterministic failure fixtures.
- Exact privacy disclosure, data minimization, local permissions, clearing,
  lifecycle, compatibility, and corrupt-recovery contracts.
- A separate scoped implementation plan and subsequent source, test, installed,
  and user-acceptance proof appropriate to the selected behavior.

## Validation notes and open questions

- Source references were inspected in the current working tree after the Plan
  012 implementation was integrated for review. Compilation and full tests are
  separate Plan 012 gates and are not claimed by this document.
- The document selects no policy, path, format, version, limit, duration,
  migration, automatic trigger, deletion, or recovery behavior.
- Open questions are exactly the eight decision rows plus the threat ownership
  and completion-signal prerequisites above.
- Static review cannot prove restart durability, failed-write recovery,
  disclosure quality, or user acceptance; those require later authorized work.
