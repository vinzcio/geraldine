# Geraldine implementation plans

Originally reconciled by the `improve` skill on 2026-08-31 against commit
`7b6fa41`, then updated after local execution on top of the preserved Dock lane
(`61872f9`), the plan queue (`c1f51ea`), and the Wi-Fi NO-GO decision
(`cd1d604`). Vincent selected all 11 vetted findings and all three
product-direction options, so every selected item is represented below as Plan
006 through Plan 019.

Completed implementation and decision-spike work is local only. This queue did
not authorize a push, PR, signing, installation, launch, live settings change,
or foreground UI verification. Vincent's 2026-08-31 `Go` approved the exact
Plan 013 and Plan 016 numeric gates, the recommended Plan 018 NO-GO, and both
adjacent Keep Awake race fixes; it did not select any alert policy value.

## Execution order and status

| Plan | Title | Priority | Effort | Depends on | Status |
|------|-------|----------|--------|------------|--------|
| 001 | Make Trash classification canonical and testable | P1 | M | — | DONE |
| 002 | Contain and qualify Uninstaller leftover paths | P1 | M | 001 | DONE |
| 003 | Preserve Finder selections as structured URLs | P1 | S | — | DONE |
| 004 | Move slow Power Tools effects off the main actor | P1 | M | refreshed after Dock lane, 007, 011 | DONE |
| 005 | Extract the global keyboard policy into a reducer | P2 | M | refreshed 004 | DONE |
| 006 | Preserve colliding launch agents during toggles | P1 | M | — | DONE |
| 007 | Make Dock action targeting exact and fail closed | P1 | M | committed Dock-preview lane | DONE |
| 008 | Enforce the Keep Awake battery policy at activation | P1 | S | — | DONE |
| 009 | Replay device refreshes that arrive during a scan | P1 | S | — | DONE |
| 010 | Keep idle-simulation pulse failures terminal | P1 | S | — | DONE |
| 011 | Dismiss an empty live Dock-preview refresh | P1 | S | Dock lane, 007 | DONE |
| 012 | Cancel superseded Smart Care scans | P2 | M | — | DONE |
| 013 | Harden Login Item plist reading | P2 | M | 006, approved exact byte ceiling | DONE |
| 014 | Align Finder and speed-test privacy disclosures | P1 | S | committed Dock-preview lane | DONE |
| 015 | Test Updater and Maintenance state machines | P2 | M | — | DONE |
| 016 | Add deterministic source verification and current documentation | P2 | M | 006-015, approved free-space gate | DONE |
| 017 | Design resumable Smart Care sessions | P2 | M | 012 | DONE (NO-GO; no feature shipped) |
| 018 | Decide whether and how to offer opt-in peripheral battery alerts | P3 | M | 009, explicit product decisions | DONE (NO-GO; no feature shipped) |
| 019 | Decide a safe known-network Wi-Fi failover contract | P3 | M | — | DONE (NO-GO; no feature shipped) |

Status values are `TODO`, `IN PROGRESS`, `DONE`, `BLOCKED (<reason>)`, or
`REJECTED (<reason>)`. `DONE` on Plans 017–019 means the decision spike is
complete; it never means that product direction was implemented or shipped.

## Completion record

1. Plan 013 uses the explicitly approved `1,048,576`-byte Login Item plist
   ceiling and preserves Plan 006's collision refusal.
2. Plan 016 uses the explicitly approved `2,097,152`-KiB free-space gate for
   this verification run; the verifier has no built-in default.
3. Plan 018 closed as NO-GO. All thirteen policy rows remain explicitly
   unselected, and no peripheral-alert feature shipped.
4. The two separately authorized Keep Awake ordering fixes now preserve idle
   snapshot order and make stale expiration callbacks inert.

## Dependency and ownership notes

- Plans 006 and 013 both edit `LoginItemsViewModel.swift`; Plan 013 must preserve
  the completed fail-closed collision behavior from Plan 006.
- Plans 007, 004, and 005 were executed serially against the preserved Dock
  identity behavior in `PowerTools.swift`.
- Plan 011 was integrated after Plan 007 against the committed Dock-preview
  lane. Plan 014 then updated only its named disclosure surfaces.
- Plan 009 establishes one-running-plus-one-pending device refresh ownership.
  Plan 018 may consume its completed snapshots but cannot add scan cadence.
- Plan 012 establishes a single cancellable Smart Care worker. Plan 017 may
  design persistence around it but cannot add a second worker or reopen task
  ownership.
- Plans 017–019 are docs/decision spikes. GO authorizes a later implementation
  plan only; NO-GO is also a valid completed-spike outcome.

## Verified local execution baseline

- `origin/main` remains at `7b6fa41`; all queue completion remains local and
  unpushed.
- The final source suite ran with the explicit Xcode macOS 26.5 SDK: 266 XCTest
  tests executed, 2 skipped, and 0 failed; the separate Swift Testing
  menu-bar placement suite passed both tests. A passing source suite does not
  prove a packaged bundle, installed `/Applications` bundle, or live
  interaction/performance behavior.
- `Package.swift` targets macOS 14+, links only system frameworks, and declares
  no third-party package graph. There is no dependency-migration finding.
- The root README now separates source, packaged, installed, and live proof.
  `verify.sh` matched source and staged input SHA-256
  `b9899f5d2f47e2907b1a12c682117f7e47161fbeb8259415cb21806d1e1152a4`,
  passed full tests and a separate clean release build, and proved cleanup for
  normal, controlled-failure, and TERM paths.
- No packaging, signing, installation, launch, foreground UI, permission
  request, push, or live account/system mutation was authorized or run.

## Preserved Dock-preview lane

The user-owned Dock-window-preview lane was sealed in `61872f9` before queue
execution. Its identity/accessibility/capture behavior remains the protected
base for the completed source plans:

- `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift`
- `Sources/Geraldine/Services/Permissions.swift`
- `Sources/Geraldine/Services/PowerTools.swift`
- `build.sh`
- `Sources/Geraldine/Features/PowerTools/DockWindowPreviewView.swift`
- `Sources/Geraldine/Services/DockWindowPreviewAccessibility.swift`
- `Sources/Geraldine/Services/DockWindowPreviewModel.swift`
- `Sources/Geraldine/Services/DockWindowPreviewService.swift`
- `Tests/GeraldineTests/DockWindowPreviewTests.swift`

Plans 004, 005, 007, 011, and 014 intentionally changed only their named
ownership surfaces on top of that base. The Dock targeting slice remains
byte-for-byte preserved, as do `Permissions.swift`,
`DockWindowPreviewView.swift`, `DockWindowPreviewAccessibility.swift`, and
`DockWindowPreviewModel.swift`. No executor may recreate or overwrite the lane
from the old planning fingerprint.

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
  schema/default changes, or policy values. Plans 013 and 016 used only their
  explicitly approved numeric gates, and the NO-GO records for Plans 017–019
  preserve unselected product policies instead of manufacturing defaults.

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
