# Geraldine — Menu Bar Work Handoff

**Last updated:** 2026-07-14
**Status:** Active development consolidated onto `main`; tests, structured review, installed-app verification, and repository cleanup are the closeout gates. The June menu-bar adoption investigation in §6 is retained as historical troubleshooting context, not an unverified current blocker.

## Current closeout snapshot — 2026-07-14

- Network throughput now has a persistent in-widget `B/s` ↔ `bps` toggle with adaptive B/K/M/G units across live values, chart statistics, inspection, help, and accessibility text. Negotiated link speed and the speed-test result remain Mbps.
- A local Akko keyboard transport monitor and optional HUD distinguish wired USB, 2.4 GHz, Bluetooth, and disconnect transitions using IORegistry activity counters; Settings includes an enable toggle and preview.
- Login Items now resolves friendly app ownership, shows real app icons or monograms, preserves stable identities across enabled/disabled locations, and guards asynchronous rescan ordering.
- Shared workflow/navigation polish covers stable sidebar selection, explicit loading/empty states, accessible hit targets, and consistent status/outcome presentation across maintenance and cleanup surfaces.
- Canonical verification remains `swift test --scratch-path /tmp/geraldine-closeout-tests` followed by `./build.sh install run`, signature/build-stamp checks, and live process-path verification against `/Applications/Geraldine.app`.

This doc is a self-contained handoff so you (or a fresh Claude Code session) can resume without re-deriving everything. Read §6 first if you only have time for one section — that's the open problem.

---

## 1. What Geraldine is (context)

Native macOS Mac-care utility (an original CleanMyMac-style app — own name/code/icon, no MacPaw assets). Goal: replace a Setapp subscription.

**Build setup (no full Xcode):**
- Pure SwiftUI, built with SwiftPM (`swift build`), assembled into `Geraldine.app` by `./build.sh`.
- `./build.sh [debug|release] [run] [install]`
- Build artifacts go to `~/Library/Caches/GeraldineBuild` (kept OUT of this OneDrive folder).
- Signed with Developer ID (team 4S9BMP9GU3) + hardened runtime + `Geraldine.entitlements`.
- `@main` is in `Sources/Geraldine/App/GeraldineApp.swift` — a SwiftUI `App` with a `Window` scene + `Settings` scene + an `@NSApplicationDelegateAdaptor`. The menu bar is a **manually-created `NSStatusItem`** (NOT `MenuBarExtra`) managed by `MenuBarController`.

**⚠️ CRITICAL BUILD GOTCHA:** The user runs the **installed** app at `/Applications/Geraldine.app` (Dock / login item), NOT the cache build. Plain `./build.sh debug run` only relaunches the cache copy in `~/Library/Caches/...`, so the user keeps seeing the OLD UI and thinks nothing changed. **Always use `./build.sh debug install run`.** Verify which binary is live with:
```
ps -p $(pgrep -x Geraldine) -o command=
```

**The user's hardware matters:** 14" MacBook Pro, **notched display** (1470×956 pt @2x, `NSScreen.safeAreaInsets.top == 32`). The notch severely limits menu-bar space (see §6).

---

## 2. What we set out to achieve

Two waves of requests in this session:

### Wave 1 — "Add WiFi network and connected devices to the menu bar, like CleanMyMac"
Research finding: CleanMyMac actually splits this into **two** modules, and its "Connected Devices" is **peripherals attached to the Mac (Bluetooth/USB/paired iPhones), NOT a LAN scan**.
- The user chose **"Match CleanMyMac"** (not a LAN scanner).
- So: a **Network** panel (the Mac's own connection: security, live ↑/↓, speed test) + a **Connected Devices** panel (Bluetooth battery, external drives w/ eject, USB iPhones).

### Wave 2 — Make the menu-bar panel into iOS-style widgets
- Each metric is a **widget** that toggles **small ↔ large** via a **button you click** (explicitly NOT an iOS press-and-hold gesture).
- **iOS-style grid layout:** small widgets pair two-per-row, large widgets span the full width.
- **Drag to reorder** widgets.
- **The top (first) widget drives the live menu-bar status item** — temperature on top → temp readout; CPU on top → CPU; etc. Slow metrics (battery/storage) show glyph+value, fast ones (temp/cpu/mem/net) show a sparkline+value.
- **Network large = ONE chart with TWO lines** (download + upload).
- **Network small = the live up/down numbers.**
- **Always show the WiFi network name** (no "Show network name" button).
- **Remove "Open Full App"** from the bottom; make the **top button prominent**.
- **Fixed-width menu-bar numbers** (`000.00 B/K/M/G/T` style) so the item doesn't shift as values change — "same for all metrics."
- The sparkline on the menu bar **must be a gradient** (the number keeps its own value-color; the chart is a gradient).

### Parked for later
- **Secondary Wi-Fi auto-failover.** Feasible via CoreWLAN preferred-network *priority* (`CWMutableConfiguration.networkProfiles` + `commitConfiguration(_:authorization:)`, one admin auth). **User requirement: NO Keychain** — and we don't need it: once the user has joined Wi-Fi #2 even once, macOS already stores its credentials, so Geraldine only reorders preferred-network priority. Not started.

---

## 3. What was built and works ✅

All of this is implemented, compiles, and is installed:

- **`NetworkMonitor`** (`Sources/Geraldine/Services/NetworkInfo.swift`)
  - Connection type via `NWPathMonitor` (wifi/ethernet/other/offline).
  - Wi-Fi security / signal (RSSI) / link rate via `CoreWLAN` (`CWWiFiClient`).
  - **SSID via CoreWLAN, gated behind Location** — macOS hides the network name without Location auth (since Sonoma). We auto-request Location at launch (`requestNameAccessIfNeeded`). If denied, the name shows as "Wi-Fi" (OS limitation, not fixable in-app).
  - **Speed test = Cloudflare** (`speed.cloudflare.com/__down` & `__up`). **NOT Ookla** (Ookla needs a paid SDK/license). Same backend Apple's `networkQuality` uses.
- **`DeviceMonitor`** (`Sources/Geraldine/Services/ConnectedDevices.swift`)
  - External/removable drives via `FileManager` (free space + eject via `NSWorkspace.unmountAndEjectDevice`), refreshed on volume mount/unmount notifications.
  - Bluetooth devices + battery % and USB iPhones/iPads via one `system_profiler SPBluetoothDataType SPUSBDataType -json` call. (AirPods battery confirmed working — shows lowest of L/R/Case.)
- **Widget system** (`Sources/Geraldine/MenuBar/`)
  - `WidgetLayout.swift`: `MetricKind` (temperature/cpu/memory/storage/battery/network), `WidgetSize` (.small/.large), `WidgetItem`, and `WidgetLayoutStore` (persists order + sizes to `UserDefaults` key `geraldine.widgetLayout.v1`).
  - `MetricWidgets.swift`: `WidgetGrid` (iOS-style packing: smalls 2-up, larges full-width) + `MetricWidget` (per-metric small/large rendering, a circle resize **button**, and a `line.3.horizontal` **drag handle** that is `.draggable`; tiles are `.dropDestination`s for reorder).
  - `NetworkPanel.swift`: `DevicesCard` (the Connected Devices section — fixed, not a reorderable widget).
  - Network large uses `DualLineGraph` (`Sources/Geraldine/Components/Charts.swift`) — one chart, two lines (down=blue/accent2, up=violet/accent), shared vertical scale.
- **Menu-bar status item** (`MenuBarController.swift`)
  - Driven by the **first widget** in the layout (`WidgetLayoutStore.menuBarKind`).
  - Rendered as an **`NSImage`** (sparkline/glyph + value) set on `button.image` — see §6 for why.
  - **Fixed width** (value right-aligned inside a slot sized to the widest possible value → never shifts). Verified: the menu-bar gap stayed at a constant 20px at idle and under heavy network load.
  - **Gradient sparkline** via Core Graphics (`drawSparkline` uses `CGContext.drawLinearGradient` for area + line; temperature uses `Thermal.scaleColors`, other metrics derive a vertical gradient from their tint). The number keeps its own value-color.
- **Popover** content (`MenuBarView.swift`): header with a prominent brand-gradient **"Open"** pill (top-right), the `WidgetGrid`, the `DevicesCard`, a recommendation card, and bottom rows (Run Smart Care / Settings / Quit). The bottom **"Open Full App" row was removed**. Whole thing wrapped in a height-clamped `ScrollView`.
- **Crash fix** (see §5).
- `Package.swift` links `CoreWLAN`, `CoreLocation`, `Network`. `build.sh` Info.plist gained `NSLocationUsageDescription` + `NSLocationWhenInUseUsageDescription`.

---

## 4. Files map (where everything lives)

| File | Responsibility |
|---|---|
| `App/GeraldineApp.swift` | `@main` SwiftUI App — `Window` + `Settings` scenes. (No `MenuBarExtra` — see §7.) |
| `App/AppDelegate.swift` | `applicationDidFinishLaunching` → starts monitors, creates `MenuBarController`. |
| `App/AppState.swift` | Singleton. Owns `monitor` (SystemMonitor), `network` (NetworkMonitor), `devices` (DeviceMonitor), `layout` (WidgetLayoutStore). Owns `appShape` (menuBarAndWindow / menuBarOnly / windowOnly). |
| `Services/SystemMonitor.swift` | CPU/mem/disk/battery/thermal/network sampling on a 1s timer + rolling histories (`cpuHistory`, `memHistory`, `batteryHistory`, `diskHistory`, `netDownHistory`, `netUpHistory`, `thermalHistory`). |
| `Services/NetworkInfo.swift` | `NetworkMonitor` — connection/wifi/security/signal/linkrate + speed test + Location gating. |
| `Services/ConnectedDevices.swift` | `DeviceMonitor` — drives/bluetooth/iOS via FileManager + system_profiler. |
| `Services/Formatters.swift` | `Fmt` — `size`, `rate`, `short`, `fixedScaled`, `percent`. **All guard NaN/∞/overflow** (see §5). |
| `MenuBar/MenuBarController.swift` | Creates the `NSStatusItem`, renders the status image (`plan()` → `drawStatus()` → `drawSparkline()`), manages the `NSPopover`. |
| `MenuBar/MenuBarView.swift` | Popover content (header, WidgetGrid, DevicesCard, recommendation, menu rows). |
| `MenuBar/MetricWidgets.swift` | `WidgetGrid` + `MetricWidget` (small/large per metric, resize button, drag reorder). |
| `MenuBar/WidgetLayout.swift` | `MetricKind`, `WidgetSize`, `WidgetItem`, `WidgetLayoutStore` (persistence, `menuBarKind`). |
| `MenuBar/NetworkPanel.swift` | `DevicesCard` (Connected Devices section). |
| `Components/Charts.swift` | `SparkGraph`, `ScaledSparkGraph` (supports `gradientColors`), `DualLineGraph`, `DonutChart`. |
| `build.sh` | Build + assemble + sign + (optionally) install/run. |

---

## 5. Bugs fixed this session ✅

1. **Wrong binary confusion.** We were testing the old `/Applications` build for a while because `build.sh run` launches the cache copy. Fix: always `install run`. (See §1 gotcha.)
2. **Crash when opening YouTube / scrolling.** `EXC_BREAKPOINT` in `Fmt.size` → `Int64(value)` trap. Root cause: `SystemMonitor.sampleNetwork()` used wraparound subtraction (`&-`); when a network counter appeared to *decrease* (interface change on a new connection) it wrapped to ~1.8e19, exceeding `Int64.max`, and the byte formatter trapped.
   - Fix A (root): `sampleNetwork` now returns 0 when a counter goes backwards (no wraparound).
   - Fix B (defense): `Fmt.size` / `Fmt.short` / `Fmt.percent` / `Fmt.fixedScaled` all clamp + finite-check, so no live value can ever crash a formatter again.
   - Verified: 4× parallel heavy downloads with the dashboard open → no crash.
3. **Menu-bar item shifting + disappearing under network load.** The item width tracked the number; a wide value shoved the whole row left under the notch, hiding the item. Fix: **fixed-width** rendering (right-aligned value in a slot sized to the widest sample). Verified: gap constant (20px) idle vs. under load.
4. **Sparkline gradient regression.** When the status item moved to `NSImage` drawing, the sparkline became a solid stroke. Restored a real gradient via Core Graphics (`drawSparkline`).

---

## 6. ❌ THE OPEN BLOCKER — menu-bar item not adopted by Control Center

**Symptom:** Geraldine's menu-bar item is frequently *not visible*, even though the app is running.

**What we PROVED (so don't re-investigate these):**
- ✅ Not a crash — no crash logs during the invisible periods; app (`pgrep`) alive.
- ✅ `appShape` is `menuBarAndWindow` (not `windowOnly`), so it *should* show.
- ✅ NOT a "no room / overflow" problem — measured **125px of free space** right of the notch (other apps' items occupy from X≈950→1472; right-of-notch area is X 825→1470).
- ✅ The item **is created, rendered, sized, and image-set in-process** — confirmed via `sample <pid>`: `MenuBarController.renderStatusItem`, `plan`, `-[NSStatusItem _adjustLength]`, `-[NSStatusBarButtonCell setImage:]` all run continuously.
- ✅ It **was visibly working earlier this session** (screenshots showed a blue "↓2K/↓5K" network sparkline and an orange "56°" temperature sparkline). So the code is fundamentally correct.
- ✅ NOT the duplicate bundle id — we unregistered + moved aside the cache `Geraldine.app` (so `/Applications` was the only `com.vincent.geraldine`) and it still didn't adopt.
- ✅ `killall ControlCenter` AND `killall SystemUIServer` did **not** clear it.

**Conclusion:** macOS's menu-bar server is in a **stuck/wedged state for this app**, almost certainly caused by **~20 rapid rebuild→install→relaunch cycles** during debugging. Each `pkill`→reinstall→`open` churns the menu-bar registration; enough cycles wedge it. It survives process-level restarts of the menu-bar host processes.

### How to diagnose menu-bar placement (tools that worked)
- Free space + notch geometry: `NSScreen.auxiliaryTopRightArea` / `auxiliaryTopLeftArea` (the gap between them is the notch).
- Where items actually are: `CGWindowListCopyWindowInfo([.optionOnScreenOnly], ...)` — note that on modern macOS, third-party status items show up as owner **"Control Center"** at **layer 25** (NOT owned by the app), so you can't filter by owner "Geraldine"; infer Geraldine's presence from the leftmost X / item count / a fresh item in the free gap.
- Is the item created in-process: `sample <pid> 2` and grep for `NSStatusBar` / `renderStatusItem`.
- (There are throwaway Swift snippets used during debugging in the session scratchpad; they're easy to recreate from the above.)

### Immediate fix (do this first next session)
**Log out and back in, or reboot.** That resets the menu-bar server cleanly. The installed build is correct, so the item should reappear — now with the gradient sparkline and fixed width. Then verify normal use (incl. YouTube) keeps it visible.

### If it's STILL flaky after a clean reboot → durable fix
Move the menu bar from a manual `NSStatusItem` to SwiftUI's **`MenuBarExtra`** scene. Rationale: a manually-created `NSStatusItem` inside a SwiftUI `App` lifecycle is known to be flaky for adoption; `MenuBarExtra` is system-managed and far more reliable.
- Add a `MenuBarExtra { MenuBarView()... } label: { ... }` scene to `GeraldineApp.swift` with `.menuBarExtraStyle(.window)`.
- Bind its `isInserted` to `appShape.showsMenuBar`.
- For the label, reuse the existing image-rendering logic (extract `plan()`/`drawStatus()`/`drawSparkline()` from `MenuBarController` into a shared renderer) and show `Image(nsImage:)`, OR a compact SwiftUI label. **Risk:** `MenuBarExtra` label may force a template image (losing color/gradient) and its `.window` style changes popover dismissal behavior — validate after a clean reboot.
- This removes `MenuBarController`'s `NSStatusItem` management (keep the popover content as the MenuBarExtra content).

### ⚠️ Process rule going forward
**Do NOT rapid-relaunch.** Batch all code changes, `install` once, test once. Hammering `pkill`→`open` is what wedged the menu-bar server.

---

## 7. Notch reality (important constraint)

On this notched Mac, status items live only in the strip **right of the notch** (~645pt total). When it fills, macOS **silently hides overflow items** (it won't tuck them under the notch). Geraldine, launching last, lands leftmost (toward the notch) and is the first to be hidden when crowded.
- This is *separate* from the adoption bug in §6 (we measured free space, so right now it's not an overflow issue).
- If overflow becomes the problem after the adoption bug is solved, the realistic fixes are: keep the menu-bar item compact, free a slot, or use a menu-bar manager like **Ice** (free) / Bartender.

---

## 8. Recommended next-session checklist

1. **Reboot** (or log out/in) to clear the wedged menu-bar server.
2. Open Geraldine (from `/Applications` — it's installed). Confirm the menu-bar item appears.
   - Expected: top widget's live readout — sparkline (gradient) + fixed-width value, or glyph+value for battery/storage.
3. Open the popover; verify: resize buttons (circle ⤢) toggle small/large; drag handle (☰) reorders; Network large shows the dual-line chart; "Open" pill works; no "Open Full App" row.
4. Watch a YouTube video for a minute → confirm **no crash** and the item **doesn't shift or vanish**.
5. Reorder a different widget (e.g., CPU) to the top → confirm the menu-bar readout follows.
6. **If the item is reliably visible → this whole thread is DONE.** (Gradient + fixed-width + crash fix all included.)
7. **If the item is still flaky → do the `MenuBarExtra` rewrite** (§6).
8. Then, if desired, build the **secondary Wi-Fi failover** feature (§2 parked item) — CoreWLAN preferred-network priority, admin auth, no Keychain.

---

## 9. Quick reference — key decisions made

- "Connected Devices" = **peripherals** (match CleanMyMac), not a LAN scanner.
- Speed test = **Cloudflare**, not Ookla.
- Widget layout = **iOS-style grid** (smalls 2-up, larges full-width), not a single column.
- Resize = a **click button** per widget, not a hold gesture.
- Top widget **drives** the menu-bar readout; battery/storage = glyph+value, others = sparkline+value.
- Menu-bar value is **fixed-width** (right-aligned to widest sample) so it never shifts.
- Menu-bar item is an **`NSImage`** (not a hosted SwiftUI view) and the sparkline is a **gradient**.
- Secondary Wi-Fi: **no Keychain** (rely on macOS-stored known-network creds; only reorder priority).
