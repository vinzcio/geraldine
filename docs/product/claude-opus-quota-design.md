# Claude Opus quota layout decision

Requested by Vincent on 2026-09-16; design supplied by Claude Code with model
`claude-opus-5` (requested `--model opus`). Opus completed successfully before
implementation. The request was limited to Claude five-hour usage and plan-aware
Codex windows; other agents and grid geometry remain unchanged.

## Accepted design

- Peer quota rows, not a hero number for one window.
- Match Antigravity's weekly-before-five-hour ordering, as Opus's consistency
  caveat recommends. Claude: Week · All, Week · Fable (if present), 5h.
  Codex Plus: Week, 5h when supplied. Other Codex plans retain one pooled value.
- Small labels: Week · All, Week · Fable, 5h. Medium/large use Weekly · All models,
  Weekly · Fable, 5-hour session. Codex uses Week/Weekly and 5h/5-hour session.
- Regular rows: 16pt values, 11pt labels, 19pt text height, 4pt text/bar gap,
  4pt bars, 8pt row gaps.
- Compact rows: 12pt values, 10pt labels, 15pt text height, 2pt text/bar gap,
  the same 4pt bars, 4pt row gaps.
- `ViewThatFits(in: .vertical)` chooses the metrics for small/medium tiles;
  large tiles use regular metrics. Rows have intrinsic fixed height; the outer
  spacer stays outside the row renderer.
- Right-aligned monospaced percentages do not shrink. Only labels may scale
  to 85% to fit. No font-size animation when the window count changes.
- One tile tooltip lists each full window label, percentage and absolute reset,
  followed by the existing Claude cache timestamp. Accessibility reads every
  displayed quota with its full label.
- Never infer or fabricate a five-hour bucket from the plan alone. Codex uses
  `limit_window_seconds`; Plus splits existing windows only when a five-hour
  window is actually present. The current Pro account reports one weekly window.

Opus's initial height estimate assumed padding twice as large as the real 10pt
inset. The implementation preserves the real grid and uses measured fit rather
than changing dimensions to match that estimate.
