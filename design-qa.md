# Keep Awake Watch Panel Design QA

Source visual truth:

- Figma file: `https://www.figma.com/design/RlTciPre9TA7zRKZsa7jXl`
- Main card node: `4:12`
- Popover card node: `4:22`
- Figma main capture: `/tmp/geraldine-keep-awake-polish-audit/09-final-installed-main.png`
- Figma popover capture: `/tmp/geraldine-keep-awake-polish-audit/10-final-installed-popover.png`

Installed implementation:

- Exact-state main-window screenshot: `/tmp/geraldine-figma-apply-live-main-figma-state.png`
- Exact-state popover screenshot: `/tmp/geraldine-figma-apply-live-popover-figma-state.png`
- Main side-by-side comparison: `/tmp/geraldine-figma-apply-main-comparison.png`
- Popover side-by-side comparison: `/tmp/geraldine-figma-apply-popover-comparison.png`
- Timed half-elapsed render: `/tmp/geraldine-figma-apply-snapshots/widget-large-active-half-elapsed.png`
- Final user-visible main window: `/tmp/geraldine-figma-apply-final-visible-main.png`

Viewport and normalization:

- Installed main capture: 920 x 672 pixels at native 1x capture density.
- Installed popover capture: 640 x 810 pixels at native 1x capture density.
- Figma and installed captures were placed at equal native widths without rescaling
  the Keep Awake component.
- Comparison state: active indefinitely, Stay Active disabled, 1-minute delay retained
  as the disabled selection.

## Full-view comparison evidence

The side-by-side comparisons show the same component bounds, left/right proportions,
rounded-square marker perimeter, eye scale, 2-3-3 honeycomb geometry, selected infinity
state, Stay Active divider, and 1m/2m/5m segmented control. The installed surfaces have
the expected slight screenshot/material softening but no layout or hierarchy drift.
Live temperature, CPU, clock, and calendar values differ from the earlier Figma capture
because they are current system data.

The installed main-window capture shows the same production component above the
remaining Power Policy and Automation settings. The main page no longer contains the
old separate hero, rectangular duration grid, or duplicate Stay Active card.

## Focused-region evidence

The component itself is the focused region and all important details remain readable
at native size: marker labels, duration labels, selected borders, eye treatment, Stay
Active state dot, and segmented-delay labels. No smaller crop is needed. The dedicated
half-elapsed render separately proves the bright remaining markers and dark elapsed
markers without waiting six hours in a live 12-hour session.

## Required fidelity surfaces

- Fonts and typography: rounded duration numerals, weights, sizes, compact marker
  labels, and Stay Active hierarchy match the source.
- Spacing and layout rhythm: component dimensions, 39/61 split, marker spacing,
  honeycomb overlap, divider position, padding, radii, and shadows match.
- Colors and visual tokens: graphite gradient, coral selection/glow, subdued idle
  markers, white eye, and muted secondary controls match.
- Image quality and asset fidelity: the existing Geraldine eye is retained at native
  SwiftUI resolution with no raster stretching or replacement asset.
- Copy and content: 10m, 30m, 1h, 2h, 4h, 8h, 12h, infinity, Stay Active, and only
  1m/2m/5m are present.

## Comparison history

1. Earlier installed-state finding: the main page still used the old card layout and
   the popover persisted Keep Awake at medium size, so the approved watch panel was
   not visible.
2. Fix: extracted one shared `KeepAwakeWatchPanel`, used it in the main page and the
   full-width popover widget, changed the default to large, and added a one-time v2/v1
   layout migration to large.
3. Post-fix evidence: the installed main page and actual debug-opened popover both
   display the shared panel. Eye start/stop, active marker state, Stay Active toggle,
   the 2-minute selection, 12-hour duration selection, and indefinite duration
   selection were exercised through the installed UI. Accessibility state reported
   `On, 12h left` and `On, Until stopped` for the corresponding sessions.
4. Final exact-state evidence: Figma and installed main/popover captures were compared
   in the same active-indefinite state. No component geometry, hierarchy, or state
   representation mismatch remains.
5. Final automation regression evidence: the freshly installed app handled
   `geraldine:activate?minutes=10`, selected only the 10m honeycomb node, announced
   the running countdown, and displayed the exact `0s / 2:30 / 5m / 7:30` perimeter
   labels. Deactivation restored the saved indefinite default without leaving a power
   assertion behind.

## Findings

No actionable P0, P1, or P2 visual differences remain.

## Follow-up polish

No blocking polish item. The live screenshot is marginally softer than the direct
renderer because it passes through the window material and screen capture. Eye press,
selection, active-state, and perimeter-marker transitions were exercised in the live
app; Reduce Motion remains handled by the production SwiftUI implementation.

final result: passed
