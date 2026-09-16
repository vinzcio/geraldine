# Coding usage widgets — handoff

**Updated:** 2026-09-15  
**Status:** Shown tiles now fetch remaining usage. Claude Max shows Fable + all-models bars; Plus shows all-models only. Cursor shows Cursor models + other models. Codex and Grok stay one pooled bar. Grok uses the official grok.com mark.

This is the pickup doc for the Dockset-style remaining-usage rings in Geraldine’s **menu-bar popover**. They do not live in the Dock.

## What shipped

Geraldine can connect local sign-ins for **Antigravity, Claude, Codex, Grok, and Cursor** and show remaining allowance as circular **% left** tiles in the popover widget grid.

- Settings → **Coding Usage**: Show Usage / Hide Usage per provider. Existing sessions are reused; no separate sign-in.
- Connecting a provider shows its popover tile. Disconnecting hides it.
- Small/medium: ring + name (Dockset analog). Large: every quota window + reset copy.
- Headline number is the **tightest** remaining window (lowest % left).
- Local-only: reads official CLI/app credentials on this Mac, then asks that provider for usage. Tokens are never sent to a Geraldine backend (there isn’t one).

Disclosure copy (also in tests):

> Reads existing usage or reuses the official app or CLI session for provider usage requests. No separate Geraldine sign-in or Keychain access.

## All-provider passive usage contract (2026-09-16)

Codex, Grok, and Cursor already read their existing auth files/database and call
usage endpoints directly. Preserve these working sources; do not add a connection
handshake. Claude reads its existing cache first. Antigravity reads the running
local language server first, then file credentials if present. On this machine
Antigravity was installed but not running, and no local database was available.

Missing local sources and HTTP 401/403 now report usage unavailable or usage access
rejected, without inferring that the official app is signed out. Settings and tile
actions use Show Usage, Hide Usage, and Refresh; no Sign In action is offered.
Provider credentials remain read-only. No auth refresh, Keychain access, automatic
app launch, or model prompt is performed by usage discovery.

Live testing also found Antigravity process discovery could stall on a full
stdout pipe: it waited for `ps` before draining output. Drain output first, then
wait for exit. Keep this ordering so a large process list cannot leave quota
discovery permanently loading.

Installed verification: debug build `740f006ad803-dirty` at
`2026-09-16T05:05:52Z` showed Claude 94%, Codex 43%, Grok 0%, and Cursor's
other-model pool 0% remaining. Enabling Antigravity resolved to usage unavailable
with the open-app instruction; no Sign In or permission dialog was observed.
Its tile was returned to its prior hidden state. Keep Awake was enabled
indefinitely and Stay Active remained enabled after one minute. All 30 focused
AI usage tests passed, including missing sources, rejected access for all five
providers, existing-token direct requests, and local Antigravity quota.
Scoped manual review and installed Settings verification completed; the popover
was not exercised in this pass.

## No-prompt credential invariant (2026-09-16)

AI usage must not access Keychain at all. Discovery, connect, timer refresh, and
popover refresh use existing credential files or local database entries only.
Claude first reads its account-matched local usage cache; missing Claude usage
is unavailable, not evidence that the user is signed out. The earlier
`kSecUseAuthenticationUIFail` guard did not stop installed-app prompts and has
been removed with all Keychain fallbacks. Do not reintroduce silent Keychain
reads, request Always Allow, change ACLs, or persist copied secrets. Tests cover
isolated local credential sources; verify the installed startup and refresh
workflow as well. Historical installed evidence below predates this correction.

## Claude local usage correction (2026-09-16)

Claude Code was already authenticated. A real Opus prompt returned
`OPUS_AUTH_OK`; Claude's own `/usage` reported 21% session and 6% weekly usage.
Geraldine now prefers `~/.claude.json` → `cachedUsageUtilization.utilization`,
validates its `accountUuid` against `oauthAccount.accountUuid`, and preserves
`fetchedAtMs` as the snapshot timestamp. Settings and the tile tooltip expose
the cached source and update time. No new connection, credential copy, Keychain
read, or background model prompt is required. Geraldine refresh rereads the
snapshot; Claude Code owns refreshing that snapshot. Existing file-token HTTP
support remains a fallback when no valid snapshot exists. Missing both sources
shows usage unavailable with a `/usage` refresh instruction, never Sign In.

Verification: all 26 focused AI usage tests passed, including cache identity,
original timestamp, rereading changed snapshots, and zero-network cached reads.
Installed debug build `6fb2237d904a-dirty`, built
`2026-09-16T04:52:55Z`, showed Claude **94% left** in Settings with
“Claude Code cache · updated Sep 16, 2026 at 12:46 PM”, without Sign In or
an observed permission dialog. Keep Awake was restored ON indefinitely and
Stay Active remained ON after one minute. This pass verified the actual Settings
surface; it did not exercise the menu-bar popover.

## Earlier corrective verification (2026-09-16, superseded for Claude)

The no-Keychain correction passed 21 focused AI usage tests. The installed debug
build at `2026-09-16T04:39:13Z` was checked with `nm -u`: zero direct `SecItem` or
`SecKeychain` imports. Live Settings showed Codex, Grok, and Cursor usage, and
Claude sign-in needed. A Codex disconnect/reconnect loaded usage again without an
observed permission dialog. Keep Awake was restored to indefinite and Stay Active
to its existing one-minute delay. This verifies startup and a live reconnect;
the menu-bar popover itself was not exercised in this corrective run.

## Installed build (this machine)

Do **not** infer this from source tests. Proven 2026-09-15:

| Fact | Value |
|------|--------|
| Bundle | `/Applications/Geraldine.app` |
| Running process | pid 15675, path `/Applications/Geraldine.app/Contents/MacOS/Geraldine` |
| Config | `debug` |
| Revision | `1e99185ed255-dirty` |
| Built at | `2026-09-15T12:23:17Z` |
| Signature | Developer ID `Lloyd Vincent Luardo (4S9BMP9GU3)` |
| Feature strings in binary | `Coding Usage`, `geraldine.aiUsage.connected` |

Rebuild/install (one cycle — do not rapid-relaunch; that wedges the menu-bar server):

```bash
cd "/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine"
./build.sh debug install run
```

The user runs the **installed** app, not `~/Library/Caches/GeraldineBuild/Geraldine.app`.

## How to try it

1. Click the Geraldine menu-bar item → popover.
2. **Edit Widgets…** and enable Codex / Claude / Cursor / Grok / Antigravity, **or** open the main window → Settings → **Coding Usage** → Connect.
3. Expect Codex and Grok to populate immediately on this Mac (see live probe below).
4. Claude reads its existing local usage cache. If unavailable, run `/usage` in Claude Code and refresh Geraldine. Antigravity may still require its own app to refresh authentication.

UserDefaults key for connected providers: `geraldine.aiUsage.connected` (`[String]` of `AICodingProvider.rawValue`). Widget visibility still lives in `geraldine.widgetLayout.v3` as kinds `ai.codex`, `ai.claude`, `ai.cursor`, `ai.grok`, `ai.antigravity`.

## Code map

Project root:

`/Users/vincent/Library/CloudStorage/OneDrive-Personal/Coding Projects/Geraldine`

| Path | Role |
|------|------|
| `Sources/Geraldine/Services/AIUsage/AICodingProvider.swift` | Provider enum, tints, sign-in hints, `AIUsageDisclosure` |
| `Sources/Geraldine/Services/AIUsage/AIUsageModels.swift` | Snapshot / window / status; tightest-window headline |
| `Sources/Geraldine/Services/AIUsage/AIUsageParsing.swift` | Pure JSON parsers (unit-tested) |
| `Sources/Geraldine/Services/AIUsage/AIUsageSources.swift` | Local credentials + HTTPS fetchers |
| `Sources/Geraldine/Services/AIUsage/AIUsageMonitor.swift` | Connect state, 5 min refresh, refresh-on-popover |
| `Sources/Geraldine/MenuBar/AIUsageWidget.swift` | Popover tiles + `UsageRemainingRing` |
| `Sources/Geraldine/MenuBar/WidgetLayout.swift` | `WidgetKind.aiUsage`; new kinds append hidden |
| `Sources/Geraldine/MenuBar/MetricWidgets.swift` | Grid switch includes `AIUsageWidget` |
| `Sources/Geraldine/Features/Settings/SettingsView.swift` | Coding Usage card |
| `Sources/Geraldine/App/AppState.swift` | `aiUsage` + `connectAIUsage` / `disconnectAIUsage` |
| `Package.swift` | links `sqlite3` (Cursor `state.vscdb`) |
| `Tests/GeraldineTests/AIUsageParsingTests.swift` | parsers, layout migration, connect persistence |
| `Tests/GeraldineTests/PrivacyDisclosureContractTests.swift` | disclosure contract |

Wiring: `AppDelegate` starts/stops the monitor; popover open calls `refreshIfStale()`; `GeraldineApp` and `MenuBarController` inject `state.aiUsage`.

These tiles **do not** drive the live menu-bar status item (`menuBarKind` is still metrics-only).

## Credential + fetch paths

Fail closed: missing creds → `.needsSignIn`; 401/403 → `.needsSignIn`; other HTTP → `.error`.

### Codex — live remaining worked (2026-09-15)

- File: `~/.codex/auth.json` → `tokens.access_token`, `tokens.account_id`
- `GET https://chatgpt.com/backend-api/wham/usage`
- Headers: `Authorization: Bearer`, `ChatGPT-Account-Id`, `User-Agent: codex-cli`
- Parse `rate_limit.primary_window` / `secondary_window` `used_percent`
- This Mac: **60% session remaining**

### Grok — live remaining worked (2026-09-15)

- File: `~/.grok/auth.json` (map of entries; token in `key`)
- `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
- `GET https://cli-chat-proxy.grok.com/v1/user?include=subscription`
- Parse `config.creditUsagePercent` (used); remaining = 100 − used
- This Mac: **40% weekly remaining**, plan `XPremiumPlus`, period end ~2026-09-16 17:27 UTC

### Cursor — signed in; parser corrected from live payload

- Prefer `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` key `cursorAuth/accessToken`
- Fallback: `~/.cursor/auth.json`, keychain `cursor-access-token`
- `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` (`Connect-Protocol-Version: 1`, body `{}`)
- Cookie dashboard `GET https://cursor.com/api/usage-summary` returned **401** with this token (Agent token ≠ browser cookie)
- Live `planUsage` (2026-09-15): `totalPercentUsed` 32.7, `autoPercentUsed` 24.3, `apiPercentUsed` 100, `totalSpend` 110450 vs `limit` 40000 plus `bonusSpend`
- **Do not** compute remaining from `totalSpend/limit` when spend exceeds included limit. Use the `*PercentUsed` fields.
- Headline will be **0%** here because the API-model pool is empty; large tile still shows included ~67% and Cursor models ~76%.

### Historical Claude credential probe — superseded by local usage cache

- Prefer `~/.claude/.credentials.json` (`claudeAiOauth.accessToken`) — **absent on this Mac**
- Then keychain service `Claude Code-credentials` (JSON with `claudeAiOauth`)
- `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`
- This Mac: keychain present, subscription `team`, tier `default_claude_max_5x`, access token expired (~5h at probe time) → **401**. Refresh token exists. Geraldine **does not** rotate OAuth.

### Antigravity — signed in, access token stale; keychain path was missing then added

- Files `~/.gemini/oauth_creds.json` etc. — **absent**
- Keychain: service `gemini`, account `antigravity`, value `go-keyring-base64:` + JSON `{ token: { access_token, refresh_token, expiry }, id_token, auth_method }`
- Unwrap helper: `AIUsageCredentialStore.unwrapSecretPayload`
- Cloud: `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` then `:fetchAvailableModels`
- Local fallback: running `language_server*antigravity` `--extension_server_port` + `--csrf_token` → `GetUserStatus` (app was **not** running at probe)
- This Mac: access token expired **2026-09-12** → **401**. Open Antigravity or `agy` once to rotate.

## Tests

From the Geraldine root, owned scratch **outside OneDrive** (see `README.md`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test \
  --scratch-path <owned-path-outside-OneDrive> \
  --filter AIUsage
```

Last source run: AI usage tests green, including Cursor percent-used windows and go-keyring unwrap. Full suite was green before the install (294 tests, 2 skipped). That does **not** prove popover layout or keychain prompts.

## Open work (pick up here)

1. **Live popover pass** — Connect Codex and Grok in Settings, confirm rings in the popover, resize/reorder, Disconnect hides the tile. Check both compact and wide popover widths. Do not hammer relaunch.
2. **Claude usage** — Implemented through the existing local cache. Do not add OAuth rotation or Keychain access.
3. **Antigravity refresh / local LS** — Same 401 story; optionally refresh Google token. When the app is open, prefer GetUserStatus so quota works without cloud token.
4. **Cursor headline policy** — Tightest-window makes this account show 0% while included usage is ~67%. Decide whether Cursor should headline `totalPercentUsed` (“Included”) instead.
5. **Menu-bar status item** — Not wired. A later change could let an `aiUsage` tile drive the status item the way the first metric does.
6. **Evidence ladder** — Packaged + installed proof exists for this debug build. Interaction, performance, and accessibility of the new tiles are still unverified.

## Invariants to keep

- No Geraldine accounts, backend, or clipboard history.
- No third-party Swift packages.
- Do not log or print tokens.
- Do not write provider credentials except a future, explicit OAuth rotation into the **same** official store Claude/agy already use.
- Coding-usage tiles stay in the **popover**, not a custom Dock, and not as a dashboard redesign.
- `./build.sh debug install run` is the only path that updates what the user sees.

## Process note

The historical menu-bar `NSStatusItem` is still manual (`MenuBarController`). Rapid `pkill` → `open` has wedged visibility before. Batch code changes, install once, test once.
