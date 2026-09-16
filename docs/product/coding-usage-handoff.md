# Coding usage widgets — handoff

**Updated:** 2026-09-15  
**Status:** Shown tiles now fetch remaining usage. Claude Max shows Fable + all-models bars; Plus shows all-models only. Cursor shows Cursor models + other models. Codex and Grok stay one pooled bar. Grok uses the official grok.com mark.

This is the pickup doc for the Dockset-style remaining-usage rings in Geraldine’s **menu-bar popover**. They do not live in the Dock.

## What shipped

Geraldine can connect local sign-ins for **Antigravity, Claude, Codex, Grok, and Cursor** and show remaining allowance as circular **% left** tiles in the popover widget grid.

- Settings → **Coding Usage**: Connect / Sign In / Disconnect per provider.
- Connecting a provider shows its popover tile. Disconnecting hides it.
- Small/medium: ring + name (Dockset analog). Large: every quota window + reset copy.
- Headline number is the **tightest** remaining window (lowest % left).
- Local-only: reads official CLI/app credentials on this Mac, then asks that provider for usage. Tokens are never sent to a Geraldine backend (there isn’t one).

Disclosure copy (also in tests):

> Reads local sign-in state for Antigravity, Claude, Codex, Grok, and Cursor, then asks each provider for remaining usage. Tokens stay on this Mac and are never sent to Geraldine.

## No-prompt credential invariant (2026-09-16)

Every AI usage Keychain read must disallow authentication UI, including discovery,
connect, timer refresh, and refresh on opening the popover. The shared reader uses
`kSecUseAuthenticationUIFail`; denied reads return no token without an interactive
retry. File/database sources and silently accessible Keychain items still work.
If the only credential requires approval, the existing sign-in state is shown.
Do not request Always Allow, modify credential ACLs, or persist copied secrets.
Preserve this rule for future providers and rebuilds. Regression coverage lives in
`AIUsageCredentialStoreTests`. This source change does not update the installed
build evidence below.

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
4. Claude and Antigravity will likely show sign-in/error until those CLIs rotate their tokens (open `claude` / `agy` once).

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
| `Tests/GeraldineTests/AIUsageParsingTests.swift` | parsers, layout migration, connect persist, go-keyring unwrap |
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

### Claude — signed in, access token stale

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
2. **Claude OAuth refresh** — On 401, use `refreshToken` the way Claude Code does, write the rotated blob back to the same keychain item, then retry usage. Until then, “open Claude Code once” is the workaround.
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
