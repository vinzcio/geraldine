# Plan 017: Design resumable Smart Care sessions

> **Executor instructions**: This is a design/architecture spike, not production
> implementation. Work only in the dispatcher's clean isolated checkout. Create
> the specified product document, run every document/scope gate, and stop rather
> than inventing a policy. Do not create or finalize a Git worktree. Update only
> Plan 017's `plans/README.md` status cell when the spike is complete, unless the
> reviewer owns the index.
>
> **Meaning of DONE**: Plan 017 `DONE` means the spike document and decision gate
> are complete. It never means resumable sessions are implemented or shipped.
>
> **Dependency gate**: Plan 012 must be DONE and integrated first. Reuse its
> single owned worker, predecessor awaiting, cancellation, and latest-publication
> boundary. Never fold persistence into Plan 012 or reopen its task ownership.
>
> **Drift check**:
> `git diff --stat 7b6fa41..HEAD -- Sources/Geraldine/Features/SmartCare/SmartCareView.swift plans/012-cancel-superseded-smart-care-scans.md docs/product/smart-care-session-spike.md plans/README.md`
> Plan 012's scoped Smart Care changes are expected. The identity, queue, rescan,
> and action semantics excerpted below must otherwise match. Drift is a STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: `plans/012-cancel-superseded-smart-care-scans.md`
- **Category**: direction, docs
- **Planned at**: commit `7b6fa41`, 2026-08-31
- **Output**: `docs/product/smart-care-session-spike.md` (create)

## Why this matters

Smart Care results, queued actions, and scan identity currently exist only in
memory and use per-instance UUIDs. Resuming safely across restart requires stable
finding identity, local persistence, revalidation, and completion reconciliation,
but each introduces product policy and stale-data risks. This spike will expose
those choices and produce a GO/NO-GO gate without changing Geraldine behavior.

## Current state

`Sources/Geraldine/Features/SmartCare/SmartCareView.swift:3-14` gives every
finding a fresh UUID rather than a durable rule identity:

```swift
let id = UUID()
var isActionable: Bool { module != nil && severity != .good }
```

The view model holds only current runtime state and a logical scan UUID
(`SmartCareView.swift:59-89,199-203` at the planned commit):

Exact identity/publication fragments:

```swift
private var scanID = UUID()
let id = UUID()
scanID = id
guard self.scanID == id else { return }
self.findings = results.sorted { $0.severity.penalty > $1.severity.penalty }
self.score = max(5, 100 - penalty)
self.scanDate = Date()
self.phase = .results
```

Plan 012 replaces the logical-only worker with one owned cancellable worker and
requires replacements to await their predecessor. A persisted session must use
that worker for restart/revalidation; it must not restore an active task, publish
around the generation guard, or introduce a second scanner/coordinator.

The queue is view-local UUID state and is cleared on rescan
(`SmartCareView.swift:227-236,367-391`):

```swift
@State private var queuedFindingIDs = Set<UUID>()
private var queuedFindings: [Finding] {
    vm.findings.filter { queuedFindingIDs.contains($0.id) }
}
```

`rescan()` calls `queuedFindingIDs.removeAll()` before `vm.scan()` and also resets
the existing reveal presentation; those behaviors are not persistence policy.

The current action has no completion receipt; it only navigates
(`SmartCareView.swift:395-402`):

```swift
private func open(_ finding: Finding) {
    guard let module = finding.module else { return }
    state.selection = module
}

private func openFirstQueuedAction() {
    guard let first = queuedFindings.first else { return }
    open(first)
}
```

The view currently auto-scans on appearance only when phase is `.idle`
(`SmartCareView.swift:268`). Resuming automatically versus asking the user is an
unresolved product decision; do not treat current scan-on-appear as approval.

The fixed product direction for this spike is: local-only resumable Smart Care
sessions, stable finding keys, restart/revalidation, and completion reconciliation.
It explicitly excludes cloud and cross-device sync. Everything listed in the
decision gate below remains unapproved until Vincent chooses it.

## Required spike document

Create the missing directory, then create the document with `apply_patch`:

```sh
mkdir -p docs/product
test ! -e docs/product/smart-care-session-spike.md
```

Create `docs/product/smart-care-session-spike.md`. Start it with:

> **Design spike only — Geraldine behavior is unchanged. `DONE` means this
> document is complete, not that resumable Smart Care sessions shipped.**

The document must contain, in order: `Evidence and current ownership`, `Goals and
non-goals`, `Stable finding identity candidates`, `Persistence and state-model
options`, `Restart and revalidation options`, `Completion reconciliation options`,
`Threat and failure model`, `Privacy and local-data inventory`, `Vincent decision
matrix`, `GO / NO-GO gate`, `Implementation-plan prerequisites`, and `Validation
notes and open questions`.

Use current `file:line` evidence and Plan 012's documented invariants. Do not
claim live behavior, user acceptance, or implementation proof from static source.

## Decision matrix: no implicit selections

The document's matrix must use columns:

`Decision | Options and tradeoffs | Vincent decision | Date/source | Consequence`

Include all eight rows below. Each `Vincent decision` starts `UNRESOLVED` unless
the executor has a direct, explicit answer from Vincent. A recommendation may be
recorded separately, but must never be copied into the decision column.

1. **Persistence scope** — which metadata, findings, queue, score, actions, and diagnostics are stored.
2. **Retention and deletion** — replacement/removal events, manual clearing, and deletion promise; no duration.
3. **Freshness and revalidation** — required checks and partial/unavailable evidence; no expiry.
4. **Auto versus manual resume** — startup/on-appear behavior and consent copy.
5. **Completed/action history** — storage/granularity and what constitutes completion.
6. **Schema evolution** — compatibility and rule split/merge/retirement; no migration/default now.
7. **Privacy disclosure** — data, location, visibility, clearing, and local health metadata copy.
8. **Corrupt/incompatible recovery** — fail-closed, preserve, quarantine, replace, or approved deletion.

No retention duration, freshness interval, storage quota, schema default/migration,
automatic resume behavior, or recovery deletion may appear as selected policy.

## Stable identity and data-model analysis

Document the current four rule families—disk capacity, reviewable junk, memory
usage, and user launch-agent count. A candidate stable key identifies the rule,
not its good/warn/bad variant, dynamic title/detail, score penalty, array index,
module, or current UUID. Analyze namespaced-string and typed-enum keys, including:

- stability across severity/content changes and rescans;
- key collision, rename, retirement, split, and merge handling;
- unknown future keys and incompatible key versions;
- queue/history references to a key absent from revalidated results.

Compare at least these persistence shapes without selecting one:

- one replaceable current-session snapshot;
- snapshot plus an action/completion journal;
- independently keyed finding records plus session metadata.

For each, inventory candidate fields, atomic-write boundary, read/write owner,
testability, privacy exposure, corruption surface, and schema-evolution burden.
Do not name a production path, format, schema version/default, size ceiling, quota,
or retention policy as decided. Illustrative pseudotypes must be marked proposals.

## State, restart, and reconciliation analysis

Provide candidate state diagrams for persisted-session availability, revalidation,
reconciled results, unreadable/incompatible data, and no stored session. Keep that
state separate from Plan 012's runtime `.idle/.scanning/.results` and worker task.

Compare restart flows that always revalidate before presenting current results,
show stored results as explicitly unvalidated, or require manual resume. Explain
how cancellation, scan failure, app termination mid-write, and partial evidence
affect the prior complete snapshot. Do not choose freshness or auto-resume policy.

Completion reconciliation must acknowledge that navigation is not completion.
Compare fresh-scan inference by stable key, explicit receipts from downstream
modules, and manual acknowledgement. For each, state false-positive/negative risk,
required cross-feature ownership, and whether it expands beyond Smart Care.

## Threat and failure model

Include a table with `Failure/threat | Harm | Detection | Candidate fail-closed
response | Required decision/test`. Cover at least:

- termination mid-write and truncated/corrupt/incompatible data;
- stale/incompletely revalidated findings and invalid or destructive routes;
- key collision/drift/split/merge/retirement and absent queued/completed keys;
- Plan 012 cancellation/replacement and duplicate publication;
- permission/read-only/full-disk/write/rename failures and overlapping instances;
- tampering, unsafe links/path replacement, health-data disclosure, failed recovery/deletion, and unprovable completion.

List candidate mitigations, not adopted policy. Never add encryption, cloud, sync,
telemetry, quotas, expiry, destructive repair, or a new worker as an assumption.

## GO / NO-GO gate

The document starts at `NO-GO — required Vincent decisions unresolved`. It may
change to GO only when all eight decision rows contain explicit Vincent decisions
with a date/source, Plan 012 is integrated, stable-key ownership is defined, every
threat has an accepted response/test obligation, and completion signals have an
authorized owner. GO authorizes drafting a separate implementation plan only.

NO-GO is a valid completed-spike outcome. Mark Plan 017 `DONE` when the document
faithfully records evidence/options/decisions/open decisions and the gates pass,
even if its implementation gate remains NO-GO. Do not draft an implementation
plan, source code, storage model, migration, or UI from unresolved rows.

## Commands and clean-checkout gate

```sh
PRIMARY_REPO='/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine'
CHECKOUT_ROOT="$(git rev-parse --show-toplevel)"
test "$(cd "$CHECKOUT_ROOT" && pwd -P)" != "$(cd "$PRIMARY_REPO" && pwd -P)"
test -z "$(git status --porcelain=v1)"
BASE_COMMIT="$(git rev-parse HEAD)"
awk -F'|' '$2 ~ /^[[:space:]]*012[[:space:]]*$/ && $0 ~ /DONE/ { found=1 } END { exit !found }' plans/README.md
```

Use this scope guard after every document step:

```sh
set -e
set -o pipefail
git cat-file -e "$BASE_COMMIT^{commit}"
test "$(git rev-parse HEAD)" = "$BASE_COMMIT"
unstaged="$(git diff --name-only "$BASE_COMMIT" -- .)"
staged="$(git diff --cached --name-only "$BASE_COMMIT" -- .)"
untracked="$(git ls-files --others --exclude-standard)"
changed="$(printf '%s\n%s\n%s\n' "$unstaged" "$staged" "$untracked" | sort -u)"
unexpected="$(printf '%s\n' "$changed" | /usr/bin/awk 'NF && $0 != "docs/product/smart-care-session-spike.md" && $0 != "plans/README.md" { print }')"
test -z "$unexpected"
```

Verification commands:

| Purpose | Command | Expected on success |
|---|---|---|
| Required sections | `for heading in 'Evidence and current ownership' 'Goals and non-goals' 'Stable finding identity candidates' 'Persistence and state-model options' 'Restart and revalidation options' 'Completion reconciliation options' 'Threat and failure model' 'Privacy and local-data inventory' 'Vincent decision matrix' 'GO / NO-GO gate' 'Implementation-plan prerequisites' 'Validation notes and open questions'; do test "$(rg -Fxc "## $heading" docs/product/smart-care-session-spike.md)" -eq 1 || exit 1; done` | every required heading appears exactly once |
| Decision gate | `for marker in 'UNRESOLVED' 'NO-GO' 'local-only' 'feature not shipped'; do rg -qiF "$marker" docs/product/smart-care-session-spike.md || exit 1; done` | every independent boundary is explicit |
| Hygiene | `git diff --check` | exit 0, no output |
| No app edits | `git diff --name-only "$BASE_COMMIT" -- Sources Tests Package.swift` | no output |

Do not run repository builds/tests, `./build.sh`, install, sign, launch, commit,
push, or open a PR. Do not modify source merely to validate a proposal.

## Scope

**In scope**:

- `docs/product/smart-care-session-spike.md` (create, including its parent folder)
- `plans/README.md` (Plan 017 status cell only)

**Out of scope**:

- every app source, repository test, `Package.swift`, Plan 012, UI, defaults,
  production storage/persistence, schema/migration, and implementation plan;
- retention/freshness durations, quotas/ceilings, deletion/recovery defaults,
  auto-resume, action-history policy, cloud/sync, encryption, telemetry, or limits;
- worktree management, commit/push/PR, build/install/sign/launch, real user data,
  and the primary checkout's user-owned Dock-preview work.

## Ordered steps

1. Run dependency, clean-checkout, drift, and scope gates. STOP if Plan 012 is not
   integrated; do not combine the tasks.
2. Write evidence, fixed direction, stable-key candidates, model/state options,
   revalidation/reconciliation options, and threat/privacy inventories.
3. Populate all eight decision rows. Record only direct Vincent decisions with
   source/date; otherwise leave `UNRESOLVED` and the gate NO-GO.
4. Run document, hygiene, no-app-edit, and scope gates; perform a scoped review
   for hidden defaults or claims of implementation.
5. Update only Plan 017's README status cell to DONE, explicitly reporting
   “spike complete; feature not shipped” and the document's GO/NO-GO result.

## Test plan

This docs-only spike is verified by exact section and decision-ledger gates,
the no-app-edit and path allowlists, and a local review for hidden policy
defaults or unsupported behavior claims. No scratch experiment or executable
model is needed or authorized by this plan.

## Done criteria

- [ ] Required sections/evidence preserve Plan 012's worker boundary without folding into it.
- [ ] Stable-key, persistence, restart, revalidation, and completion options expose UUID/queue/navigation caveats.
- [ ] All eight Vincent decision rows are present with no fabricated selection.
- [ ] Threat/failure and privacy inventories cover every required case.
- [ ] GO requires all explicit decisions; NO-GO remains valid when unresolved.
- [ ] No retention/freshness duration, quota, migration/default, auto-resume, recovery deletion, cloud, or sync was chosen.
- [ ] Scope/no-app-edit/hygiene gates pass; only the product doc and README cell changed.
- [ ] DONE is reported as spike complete, feature not shipped; no code/implementation/worktree/commit/push/install/launch occurred.

## STOP conditions

Stop if Plan 012 is not DONE/integrated; source semantics drift beyond Plan 012;
the supplied checkout is primary or dirty; the product doc has unrelated ownership;
an option requires selecting a duration, expiry, quota, migration/default,
auto-resume, deletion/recovery, history, privacy, cloud/sync, or other policy
without Vincent's explicit decision; completion cannot be distinguished from mere
navigation; the spike starts altering runtime state/task ownership; another repo
file or scratch experiment is needed; a gate fails twice; or the scope guard
fails.

## Maintenance notes

Future implementation planning must cite the exact Vincent decisions and preserve
Plan 012's worker boundary. Stable keys belong to finding rules, never display text
or scan UUIDs. A shipped store must treat persisted content as untrusted local data
and revalidate according to the approved policy. Reopen this spike whenever rules,
completion ownership, schema behavior, privacy disclosure, or resume policy changes.
