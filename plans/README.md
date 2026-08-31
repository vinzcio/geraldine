# Geraldine implementation plans

Reconciled by the `improve` skill on 2026-08-31 against commit `7b6fa41`.
Vincent selected all 11 vetted findings and all three product-direction options,
so every selected item is represented below as Plan 006 through Plan 019. This
planning pass changed no application source, test, build, or installed-app file.

Executors must read their selected plan completely, honor every STOP condition,
and work only in a clean isolated checkout supplied by the dispatcher. A plan
does not authorize creating/removing a worktree, committing, pushing, opening a
PR, signing, installing, launching, changing live settings, or disturbing the
dirty primary checkout. Register and finalize only task-owned temporary roots
with CLAYGO unless a dispatcher separately assigns broader lifecycle work.

## Execution order and status

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 001 | Make Trash classification canonical and testable | P1 | M | — | DONE |
| 002 | Contain and qualify Uninstaller leftover paths | P1 | M | 001 | DONE |
| 003 | Preserve Finder selections as structured URLs | P1 | S | — | DONE |
| 004 | Move slow Power Tools effects off the main actor | P1 | M | refreshed after Dock lane, 007, 011 | BLOCKED (stale base and guards) |
| 005 | Extract the global keyboard policy into a reducer | P2 | M | refreshed 004 | BLOCKED (requires refreshed 004) |
| 006 | Preserve colliding launch agents during toggles | P1 | M | — | TODO |
| 007 | Make Dock action targeting exact and fail closed | P1 | M | committed Dock-preview lane | BLOCKED (awaiting clean lane handoff) |
| 008 | Enforce the Keep Awake battery policy at activation | P1 | S | — | TODO |
| 009 | Replay device refreshes that arrive during a scan | P1 | S | — | TODO |
| 010 | Keep idle-simulation pulse failures terminal | P1 | S | — | TODO |
| 011 | Dismiss an empty live Dock-preview refresh | P1 | S | Dock lane, 007 | BLOCKED (awaiting lane and 007) |
| 012 | Cancel superseded Smart Care scans | P2 | M | — | TODO |
| 013 | Harden Login Item plist reading | P2 | M | 006, approved exact byte ceiling | BLOCKED (exact byte ceiling not yet approved) |
| 014 | Align Finder and speed-test privacy disclosures | P1 | S | committed Dock-preview lane | BLOCKED (lane-owned build.sh is dirty) |
| 015 | Test Updater and Maintenance state machines | P2 | M | — | TODO |
| 016 | Add deterministic source verification and current documentation | P2 | M | 006-015, approved free-space gate | BLOCKED (exact free-space gate not yet approved) |
| 017 | Design resumable Smart Care sessions | P2 | M | 012 | BLOCKED (awaiting Plan 012) |
| 018 | Decide whether and how to offer opt-in peripheral battery alerts | P3 | M | 009, explicit product decisions | BLOCKED (threshold and cooldown decisions required) |
| 019 | Decide a safe known-network Wi-Fi failover contract | P3 | M | — | TODO |

Status values are `TODO`, `IN PROGRESS`, `DONE`, `BLOCKED (<reason>)`, or
`REJECTED (<reason>)`. `DONE` on Plans 017–019 means the decision spike is
complete; it never means that product direction was implemented or shipped.

## Recommended execution graph

1. Preserve or complete the user-owned Dock-preview lane and hand it to future
   executors as a clean committed base. Do not use the current dirty planning
   checkout for implementation.
2. Independent source lanes may proceed in parallel with non-overlapping
   ownership: Plans 006, 008, 009, 010, 012, and 015.
3. Run Plan 013 only after Plan 006 and only after Vincent approves an exact
   Login Item plist byte ceiling. The adjacent 1 MiB Uninstaller bound is an
   option, not authorization.
4. After the clean Dock handoff, run Plan 007, then Plan 011. Plan 014 may run
   from that clean handed-off lane because it needs the lane-owned `build.sh`.
5. Re-recon and rewrite stale Plans 004 and 005 after the Dock sequence; do not
   execute their 2026-07-15 hashes, `/tmp` workflow, or old source excerpts.
6. Plan 017 follows Plan 012 and may complete as NO-GO while decisions remain
   unresolved. Plan 018 follows Plan 009 and remains blocked on its explicit
   product decisions. Plan 019 has no prerequisite and may likewise complete
   its evidence spike as NO-GO without inventing policy.
7. Run Plan 016 after the selected code queue so the verifier, root README,
   current handoff, and historical QA record describe the resulting source.
   Its verifier must receive an explicitly approved positive free-space gate;
   no numeric default was selected here.

## Dependency and ownership notes

- Plans 006 and 013 both edit `LoginItemsViewModel.swift`; execute them
  serially and preserve Plan 006's fail-closed collision behavior in Plan 013.
- Plans 007, 004, and 005 edit `PowerTools.swift`; Plan 007 owns exact Dock
  identity first, then Plans 004/005 require fresh planning against that result.
- Plan 011 edits only the Dock-preview service/test pair but depends on the
  exact committed lane and the action-targeting sequence documented by Plan 007.
- Plan 014 changes one lane-owned `build.sh` disclosure plus clean Network
  source/widget paths; it must not be applied over the user's dirty lane.
- Plan 009 establishes one-running-plus-one-pending device refresh ownership.
  Plan 018 may consume its completed snapshots but cannot add scan cadence.
- Plan 012 establishes a single cancellable Smart Care worker. Plan 017 may
  design persistence around it but cannot add a second worker or reopen task
  ownership.
- Plans 017–019 are docs/decision spikes. GO authorizes a later implementation
  plan only; NO-GO is also a valid completed-spike outcome.

## Verified planning baseline

- `HEAD` and `origin/main` both resolved to `7b6fa41` during recon.
- The full source suite ran with the explicit Xcode macOS 26.5 SDK: 184 tests
  executed, 2 skipped, and 0 failed. The separate Swift Testing menu-bar
  placement run also passed its 2 tests.
- The temporary SwiftPM audit root was finalized and removed. A passing source
  suite does not prove a packaged bundle, installed `/Applications` bundle, or
  live interaction/performance behavior.
- `Package.swift` targets macOS 14+, links only system frameworks, and declares
  no third-party package graph. There is no dependency-migration finding.
- There is currently no root README or CI source gate. Plan 016 supplies a
  non-installing verifier and current docs without changing `build.sh`.
- No packaging, signing, installation, launch, foreground UI, permission
  request, or live account/system mutation was authorized or run in this pass.

## Protected current checkout work

The primary checkout contains a user-owned Dock-window-preview lane. Preserve
these exact paths; do not stage, clean, format, copy, or edit them during plan
execution:

- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
- `Sources/Geraldine/Services/Permissions.swift`
- `Sources/Geraldine/Services/PowerTools.swift`
- `build.sh`
- `Sources/Geraldine/Features/PowerTools/DockWindowPreviewView.swift`
- `Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift`
- `Sources/Geraldine/Services/DockWindowPreviewModel.swift`
- `Sources/Geraldine/Services/DockWindowPreviewService.swift`
- `Tests/GeraldineTests/DockWindowPreviewTests.swift`

At planning time, the combined tracked diff plus the five untracked file blobs
produced lane fingerprint
`a0289159995aab7d8d4052fbbcb48838dbf0c60fde0517cf5c27cda848ddf5aa`.
Plans 007, 011, and 014 contain narrower prerequisite hashes and must still
fail closed on drift. The fingerprint documents the planning snapshot; it is
not permission to recreate or overwrite a changed lane.

## Product boundaries carried into the plans

- Geraldine remains local-only freeware: no accounts, backend, sync, telemetry,
  or clipboard-history return is part of this queue.
- Dock previews remain opt-in/off by default. Accessibility owns exact window
  identity, ScreenCaptureKit supplies thumbnails, ambiguous matches fail closed,
  and cache/prewarm/generation behavior is deliberate unless a selected plan
  names the exact change.
- Bounded metric pages intentionally keep their current `VStack` composition;
  no `drawingGroup` or chart rewrite is justified without new profiling.
- Do not turn Geraldine into a generic AI dashboard or system-monitor aesthetic.
  A whole-app/icon direction remains blocked on a personal identity brief.
- No plan may invent quotas, ceilings, retention, timeouts, retries, migrations,
  schema/default changes, or policy values. Plans 013 and 016 therefore carry
  explicit numeric-approval gates, and Plans 017–019 preserve unresolved
  product decisions instead of selecting defaults.

## Selection result

All vetted findings were promoted: LaunchAgent collision safety (006), Dock
target identity (007), Keep Awake battery enforcement (008), device refresh
coalescing (009), terminal idle-pulse failure (010), empty preview dismissal
(011), Smart Care cancellation (012), safe Login Item plist reads (013), privacy
disclosures (014), testable updater/maintenance state machines (015), and a
deterministic source verifier/current docs (016). The three selected product
directions became decision-gated Plans 017–019. No vetted finding remains in a
deferred bucket.

## Findings considered and not promoted

- Third-party dependency migration: rejected because there is no third-party
  package graph.
- A generic `Shell.runAdmin` injection refactor: rejected because current
  callers pass fixed source constants; Plan 015 uses feature-local seams and
  leaves quoting/admin ownership untouched.
- A speculative `MenuBarExtra` rewrite: rejected absent a fresh reproducible
  installed-app failure.
- Chart composition, monitor-history persistence, and Dock prewarm removal:
  rejected without new profiling or a selected behavioral finding.
- Mission/default-on behavior and the current session-aware metric history:
  retained as deliberate product behavior rather than reclassified as defects.
- Subprocess timeouts, cache expiry, retry counts, scan caps, and related policy:
  not planned because no exact policy was requested or approved.
- A whole-app/icon redesign: blocked until Geraldine's personal meaning and
  identity direction are established; do not revive rejected techie branding.
