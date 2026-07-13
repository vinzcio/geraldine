# Geraldine installed-app visual verification

This folder records the real installed `/Applications/Geraldine.app` before and after the full visual-audit implementation.

## Result

- Implemented and statically traced all 56 visual-audit backlog items and all 25 motion requirements.
- Installed source revision `3d66c374385e54456583e58afe5a6eb461c56cb3` (debug, dirty worktree preserved), built at `2026-07-11T15:27:08Z`.
- Verified the installed bundle's Developer ID signature and full Apple certificate chain outside the workspace sandbox.
- Exercised every sidebar module in the installed app, including rapid directional navigation and interruption recovery.
- Verified the canonical Settings gateway, four-stage onboarding, widget customization mode, calendar month reversal, chart accessibility metadata, and live Keep Awake controls.
- Confirmed Full Disk Access and Accessibility both report Ready after relaunch.
- Confirmed `NoIdleSleepAssertion` and `NoDisplaySleepAssertion` are both active for Geraldine.
- See `REQUIREMENT-EVIDENCE.md` for the row-by-row 56-item backlog and 25-item motion implementation matrix.

## Baseline

- `00-before-dashboard.jpeg` — dashboard hierarchy, cards, native sidebar selection, and chart treatment.
- `00-before-smart-care.jpeg` — score result, summary, finding card, and action hierarchy.
- `00-before-activity.jpeg` — live metrics, process rows, and dense information hierarchy.
- `00-before-keep-awake.jpeg` — active indefinite session, eye identity, duration selection, and policies.
- `00-before-settings.jpeg` — former uniform-form settings architecture.
- `00-before-menu-popover.jpeg` — native popover anchoring and widget composition.

## Final evidence

- `10-after-dashboard.jpeg` — responsive dashboard hierarchy, live health narrative, metric rings, and quick-action architecture.
- `11-after-smart-care.jpeg` — health score, scope/confidence language, staged finding cards, and primary review action.
- `12-after-activity.jpeg` — live chart treatment, metric hierarchy, thermal context, and accessible sample inspection.
- `13-after-keep-awake.jpeg` — signature eye state, active-session hierarchy, duration controls, and policy surface.
- `14-after-settings.jpeg` — canonical settings architecture, live presence preview, and preserved session defaults.
- `15-after-menu-popover.jpeg` — native anchored popover, varied widget rhythm, calendar, live charts, and active Keep Awake state.
- `16-after-space-lens.jpeg` — live disk-map hierarchy and drill-in evidence.
- `17-after-calendar-clocks.jpeg` — date preview, calendar/world-clock controls, and popover-oriented setup.
- `18-after-onboarding-welcome.jpeg` — first stage of the verified four-stage onboarding flow.
- `19-final-keep-awake-restored.jpeg` — final installed-app state after signing, permission, lifecycle, and preference restoration.

## Verification

- `swift build --disable-sandbox` passed.
- `swift test --disable-sandbox` passed: 9 tests, 0 failures.
- `git diff --check`, Swift parser checks, C bridge syntax, shell syntax, and entitlements plist lint passed.
- Final structured autoreview returned no actionable findings.
- Gatekeeper identifies this as an unnotarized Developer ID development build; notarization was not part of this local install pass.

## Preserved state

- App shape: Menu Bar Only.
- Launch Geraldine at Login: enabled.
- Onboarding completion: true.
- Keep Awake: active indefinitely; display sleep prevented.
- Idle Activity: disabled; 1-minute delay retained.
- Widget visibility, order, and sizing: unchanged.
- Main window frame and sidebar split: unchanged.
