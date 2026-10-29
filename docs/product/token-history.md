# Token history and estimated cost

Geraldine's Coding Usage page has separate **Allowances** and **Tokens & Cost** tabs.
Opening **Tokens & Cost** shows cached summaries immediately and refreshes stale
accounts independently in the background. Requested histories continue refreshing
on the existing five-minute usage cadence while the page is closed and after
relaunch. **Refresh Usage** requests prices and visible histories independently;
slow public pricing never delays token totals. **Read history** refreshes one
account. Choose history folder keeps a custom location for this app session;
custom-folder summaries are not restored as default-source totals after relaunch.
No history database or retention cutoff is introduced.

Supported readers:

- Claude: projects JSONL, including sibling account homes; repeated content blocks are deduplicated by message/request identity.
- Codex: sessions and archived sessions JSONL, including sibling homes; cumulative counters validate request usage and copied fork history is suppressed.
- Grok: completed turns in sessions/updates.jsonl, per-model counts and provider-reported dollar ticks.
- Cursor: paginated account history from the dashboard, using existing auth.json files only. No Keychain or desktop database credentials are used by the history reader. Identical billed events are preserved; overlapping pagination boundaries are reconciled against the server's total.
- Antigravity: read-only conversation SQLite generation/step metadata, including retry usage; overlapping request identities are merged.
- OpenCode: read-only SQLite and legacy storage/message JSON, deduplicated by message ID.
- Pi: native session JSONL, including auxiliary tool/summary usage.
- Muse: native session.jsonl, including automated review records. A read-only CLI initialization discovers Muse's home. Without the CLI, choose the native sessions folder explicitly.

Environment paths are honored where supplied to the Geraldine process:
CLAUDE_CONFIG_DIR, CODEX_HOME, GROK_HOME, OPENCODE_DATA_DIR, XDG_DATA_HOME,
ANTIGRAVITY_DATA_DIR, PI_CODING_AGENT_DIR, and PI_CODING_AGENT_SESSION_DIR.
Named Claude/Codex sibling identities retain their own homes rather than inheriting
the default account's environment override. T3-managed custom profiles are not
automatically discovered; select their history folder when needed.

Input, cache read, cache write, and output form disjoint totals. Reasoning is
already included in normalized output. Public LiteLLM rates supply estimated
API-equivalent cost, including recorded speed tiers when rates are available.
Provider-reported cost takes precedence. Unknown models remain unpriced and
partial costs are explicitly labeled. Estimates use current fetched rates and
are not historical invoices or subscription bills. Rates stay in memory; default
history display summaries are cached in Geraldine's preferences for relaunch. Partial/unreadable sources are disclosed; a failed refresh retains the
last successful summary. Prompts and credentials are never retained or logged.

Existing history readers and provider credential ownership remain unchanged. OpenCode, Pi, and Muse currently support history in Geraldine; their
allowance tiles report unavailable rather than fabricate subscription limits.
No provider ceilings, account schemas, credential refreshes, or Keychain access
were added. Cursor history and public pricing are the approved direct HTTP exceptions.

Mechanics were adapted from T3 Code revision
`c0f9e36184956994d6d26c6f3e526676380161d3`: provider `usage.ts` readers,
`apps/server/src/usage/usagePricing.ts`, and Cursor `accountUsage.ts`.
The MIT notice is bundled in `Resources/Licenses/T3Code.txt`.

Verification: `swift test --filter AIUsage` with an owned scratch path and
`GERALDINE_CREDENTIAL_TEST_ROOT`. Set `AI_HISTORY_RENDER_DIR` for offscreen light/dark
history renders. Set `AI_HISTORY_LIVE=1` only for explicit read-only live history
verification (aggregate counts only). These checks do not install or activate the app.

## Local verification — 2026-10-28

- Focused AI usage suite: 141 tests, zero failures, two opt-in checks skipped.
- Widget migration/drag, monitor rendering, and control-host regression selection:
  29 tests, zero failures; the three fixture-dependent control-host tests initially
  skipped and then all passed when rerun with the registered fixture root.
- After review fixes, all 18 history tests passed (one opt-in live check skipped);
  the live read check was also run separately.
- Actual read-only scans found Claude, Codex, Grok, OpenCode, and Antigravity
  history. Cursor lacks a file-based login here; Pi and Muse have no discoverable
  local history here. Their readers were exercised with synthetic data.
- Antigravity's final scan read 192 records with three unpriced records; OpenCode
  read 1,157 records with 760 unpriced records. No price is inferred from a model
  name containing “free.” Codex disclosed 81 invalid/unreadable records.
- SwiftUI history cards were rendered and visually checked offscreen in light and
  dark appearances at widths 850 and 650. No user window was activated.
- Scoped manual source/diff review and whitespace checks completed. The app was
  built locally for tests; it was not installed, committed, pushed, or released.
