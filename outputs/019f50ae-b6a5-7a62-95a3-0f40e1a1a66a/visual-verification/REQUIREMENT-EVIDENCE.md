# Geraldine requirement evidence

All **56/56 visual-audit backlog requirements** and **25/25 motion requirements** are implemented in the current source tree.

The implementation-evidence column records the strongest source-owned acceptance criterion for each row. Installed proof is deliberately narrower:

- **Direct** — the requirement-specific behavior or surface was exercised or captured in the installed `/Applications/Geraldine.app`.
- **Representative** — installed screenshots or interactions prove the shared visual/motion treatment, but not every appearance, hardware, or state variant.
- **Surface loaded** — the installed surface loaded successfully; the complete state journey was not exercised.
- **Not directly verified** — acceptance is source-verified only. This is used for unavailable hardware or accessibility variants and destructive/system handoffs that were intentionally not forced.

The installed-app verification narrative and screenshot index are in [README.md](README.md).

## Foundation

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| FND-01 | Implemented | `Sources/Geraldine/DesignSystem/Theme.swift:32-183` | Representative — final screenshots exercise the semantic visual system. |
| FND-02 | Implemented | `Sources/Geraldine/DesignSystem/Theme.swift:77-126` | Not directly verified — the light-mode contrast matrix was not explicitly captured. |
| FND-03 | Implemented | `Sources/Geraldine/Navigation/Module.swift:71-90` | Representative — final module screenshots show the centralized palette. |
| FND-04 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:40-189` | Representative — final screenshots show the card tier system. |
| FND-05 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:53-78` | Not directly verified — Reduce Transparency and increased contrast were not explicitly toggled. |
| FND-06 | Implemented | `Sources/Geraldine/DesignSystem/Theme.swift:150-183` | Representative — final screenshots show the shared geometry and depth scale. |
| FND-07 | Implemented | `Sources/Geraldine/DesignSystem/Scaffold.swift:107-179` | Representative — installed module pages use the shared scaffold. |
| FND-08 | Implemented | `Sources/Geraldine/DesignSystem/Scaffold.swift:3-15` | Not directly verified — a full installed resize matrix was not recorded. |
| FND-09 | Implemented | `Sources/Geraldine/DesignSystem/Theme.swift:204-215` | Representative — installed screenshots show the shared type hierarchy. |
| FND-10 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:669-872` | Representative — primary, secondary, quiet, and contextual controls were used live. |
| FND-11 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:194-238` | Not directly verified — the complete pointer, press, focus, and disabled matrix was not recorded. |
| FND-12 | Implemented | `Sources/Geraldine/DesignSystem/VisualPrimitives.swift:241-245` | Not directly verified — hit areas were not measured in the installed app. |
| FND-13 | Implemented | `Sources/Geraldine/DesignSystem/Motion.swift:19-85` | Representative — navigation, calendar, and widget motion were exercised live. |
| FND-14 | Implemented | `Sources/Geraldine/DesignSystem/Motion.swift:32-84` | Not directly verified — Reduce Motion was not explicitly toggled during the recorded pass. |
| FND-15 | Implemented | `Sources/Geraldine/DesignSystem/VisualPrimitives.swift:3-46` | Direct — the Geraldine mark and module glyphs appear throughout the final screenshots. |
| FND-16 | Implemented | `Sources/Geraldine/DesignSystem/VisualPrimitives.swift:69-149` | Representative — sidebar and Keep Awake selected states were captured live. |

## App shell

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| SHL-01 | Implemented | `Sources/Geraldine/Navigation/RootView.swift:73-111` | Direct — sidebar selection and navigation are visible in the final app screenshots. |
| SHL-02 | Implemented | `Sources/Geraldine/Navigation/RootView.swift:172-278` | Direct — rapid directional navigation and interruption recovery were exercised. |
| SHL-03 | Implemented | `Sources/Geraldine/Navigation/RootView.swift:284-321` | Representative — multiple installed module captures show the changing aura. |
| SHL-04 | Implemented | `Sources/Geraldine/DesignSystem/Scaffold.swift:17-83` | Representative — standard, data, and utility headers were loaded across modules. |
| SHL-05 | Implemented | `Sources/Geraldine/Features/Settings/SettingsView.swift:3-114` | Direct — the canonical Settings gateway and main settings page were verified. |
| SHL-06 | Implemented | `Sources/Geraldine/Features/Onboarding/Onboarding.swift:3-306` | Direct — all four onboarding stages were completed in the installed app. |
| SHL-07 | Implemented | `Sources/Geraldine/MenuBar/MenuBarController.swift:176-237` | Representative — the live status item opened the installed popover; its full Reduce Motion matrix was not recorded. |
| SHL-08 | Implemented | `Sources/Geraldine/MenuBar/MenuBarView.swift:18-60` | Direct — `15-after-menu-popover.jpeg` captures the anchored native popover. |
| SHL-09 | Implemented | `Sources/Geraldine/MenuBar/MetricWidgets.swift:290-507` | Direct — customization exposed visibility, reorder, and size controls and exited without changing layout. |

## Signature experiences

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| SIG-01 | Implemented | `Sources/Geraldine/Features/KeepAwake/KeepAwakeView.swift:8-18` | Direct — `13-after-keep-awake.jpeg` records the active eye and red state language. |
| SIG-02 | Implemented | `Sources/Geraldine/MenuBar/KeepAwakeWidget.swift:154-200` | Direct — live Keep Awake controls and the countdown composition were verified. |
| SIG-03 | Implemented | `Sources/Geraldine/Features/SpaceLens/SpaceLensViewModel.swift:5-20` | Direct — the installed Space Lens map and drill-in behavior were exercised. |
| SIG-04 | Implemented | `Sources/Geraldine/Components/Charts.swift:163-259` | Direct — Activity and popover chart treatment plus inspection metadata were verified. |
| SIG-05 | Implemented | `Sources/Geraldine/Features/SmartCare/SmartCareView.swift:291-533` | Representative — `11-after-smart-care.jpeg` captures the resolved score and staged result hierarchy. |
| SIG-06 | Implemented | `Sources/Geraldine/Features/Calendar/CalendarPopover.swift:109-178` | Direct — previous/next month reversal returned to July 2026 in the installed popover. |
| SIG-07 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:274-486` | Representative — live metric readouts were captured, but every unit-token replacement was not recorded. |

## Modules

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| MOD-01 | Implemented | `Sources/Geraldine/Features/Dashboard/DashboardView.swift:70-136` | Direct — `10-after-dashboard.jpeg`. |
| MOD-02 | Implemented | `Sources/Geraldine/Features/Activity/ActivityView.swift:93-117` | Direct — `12-after-activity.jpeg`. |
| MOD-03 | Implemented | `Sources/Geraldine/Features/Storage/StorageView.swift:238-318` | Surface loaded — Storage opened successfully in the installed module sweep. |
| MOD-04 | Implemented | `Sources/Geraldine/Features/Battery/BatteryView.swift:16-65` | Surface loaded — the hardware-appropriate Power page opened on the Mac mini. |
| MOD-05 | Implemented | `Sources/Geraldine/Features/KeepAwake/KeepAwakeView.swift:58-201` | Direct — `13-after-keep-awake.jpeg` and restored live assertions. |
| MOD-06 | Implemented | `Sources/Geraldine/Features/Calendar/CalendarSettingsView.swift:60-111` | Direct — `17-after-calendar-clocks.jpeg`. |
| MOD-07 | Implemented | `Sources/Geraldine/Features/PowerTools/PowerToolsView.swift:393-438` | Surface loaded — Power Tools opened successfully in the installed module sweep. |
| MOD-08 | Implemented | `Sources/Geraldine/Features/Cleanup/CleanupView.swift:3-94` | Surface loaded — Cleanup opened successfully; destructive completion was not forced. |
| MOD-09 | Implemented | `Sources/Geraldine/Features/LargeFiles/LargeFilesView.swift:56-118` | Surface loaded — Large & Old Files opened successfully. |
| MOD-10 | Implemented | `Sources/Geraldine/Features/Uninstaller/UninstallerView.swift:90-125` | Surface loaded — Uninstaller opened successfully; no app was removed. |
| MOD-11 | Implemented | `Sources/Geraldine/Features/Privacy/PrivacyView.swift:122-185` | Surface loaded — Privacy opened successfully; sensitive cleanup was not forced. |
| MOD-12 | Implemented | `Sources/Geraldine/Features/LoginItems/LoginItemsView.swift:150-246` | Surface loaded — Login Items opened successfully without changing startup state. |
| MOD-13 | Implemented | `Sources/Geraldine/Features/Maintenance/MaintenanceView.swift:66-207` | Surface loaded — Maintenance opened successfully; privileged tasks were not forced. |
| MOD-14 | Implemented | `Sources/Geraldine/Features/Updater/UpdaterView.swift:204-312` | Surface loaded — Updater opened successfully; app updates were not forced. |
| MOD-15 | Implemented | `Sources/Geraldine/Features/Permissions/PermissionsView.swift:112-150` | Direct — Full Disk Access and Accessibility both reported Ready after relaunch. |
| MOD-16 | Implemented | `Sources/Geraldine/Features/FreeRAM/FreeRAMView.swift:90-197` | Not directly verified — the Free RAM sheet was not explicitly recorded. |
| MOD-17 | Implemented | `Sources/Geraldine/MenuBar/NetworkPanel.swift:121-196` | Surface loaded — the installed popover loaded its connected-device area. |
| MOD-18 | Implemented | `Sources/Geraldine/MenuBar/MetricWidgets.swift:734-912` | Direct — `15-after-menu-popover.jpeg` captures connection, traffic, security, and speed-test controls. |

## Shared states

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| STS-01 | Implemented | `Sources/Geraldine/DesignSystem/WorkflowComponents.swift:4-89` | Representative — multiple workflow surfaces loaded in ready, working, or result states. |
| STS-02 | Implemented | `Sources/Geraldine/Components/ScanResultsView.swift:5-140` | Representative — Smart Care and scan surfaces prove the shared review language. |
| STS-03 | Implemented | `Sources/Geraldine/DesignSystem/WorkflowComponents.swift:265-309` | Surface loaded — Login Items and Activity loaded ledger rows successfully. |
| STS-04 | Implemented | `Sources/Geraldine/Features/Cleanup/CleanupView.swift:63-126` | Not directly verified — destructive cancellation-return paths were not forced live. |
| STS-05 | Implemented | `Sources/Geraldine/Features/LargeFiles/LargeFilesViewModel.swift:33-40` | Not directly verified — native file-picker and external-operation handoffs were not forced. |
| STS-06 | Implemented | `Sources/Geraldine/DesignSystem/Motion.swift:87-167` | Representative — lifecycle and preference restoration completed without changing preserved state. |

## Motion audit

| ID | Status | Implementation evidence | Installed proof scope |
|---|---|---|---|
| MOT-01 | Implemented | `Sources/Geraldine/DesignSystem/Motion.swift:19-85` | Representative — live navigation, calendar, and widget motion exercised the policy. |
| MOT-02 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:274-363` | Not directly verified — Reduce Motion was not explicitly toggled. |
| MOT-03 | Implemented | `Sources/Geraldine/MenuBar/MenuBarController.swift:176-237` | Representative — the live status item updated while installed. |
| MOT-04 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:194-238` | Representative — shared card buttons were used, but the full focus/press matrix was not recorded. |
| MOT-05 | Implemented | `Sources/Geraldine/MenuBar/MetricWidgets.swift:290-333` | Direct — Space Lens drill-in and widget customization were exercised. |
| MOT-06 | Implemented | `Sources/Geraldine/Navigation/RootView.swift:172-278` | Direct — rapid navigation and interruption recovery were exercised. |
| MOT-07 | Implemented | `Sources/Geraldine/DesignSystem/WorkflowComponents.swift:4-89` | Representative — installed workflow surfaces changed phase successfully. |
| MOT-08 | Implemented | `Sources/Geraldine/Features/SmartCare/SmartCareView.swift:291-533` | Representative — the resolved Smart Care state was captured; the full morph was not recorded as video. |
| MOT-09 | Implemented | `Sources/Geraldine/Features/FreeRAM/FreeRAMView.swift:90-197` | Not directly verified — the Free RAM sheet was not explicitly recorded. |
| MOT-10 | Implemented | `Sources/Geraldine/MenuBar/MetricWidgets.swift:397-499` | Direct — widget customization and reflow controls were exercised. |
| MOT-11 | Implemented | `Sources/Geraldine/DesignSystem/WorkflowComponents.swift:91-127` | Representative — contextual symbols appear in installed captures. |
| MOT-12 | Implemented | `Sources/Geraldine/MenuBar/KeepAwakeWidget.swift:40-200` | Direct — active Keep Awake controls and countdown hierarchy were verified. |
| MOT-13 | Implemented | `Sources/Geraldine/DesignSystem/EyeView.swift:18-109` | Direct — the live eye control was exercised during Keep Awake verification. |
| MOT-14 | Implemented | `Sources/Geraldine/Features/Calendar/CalendarPopover.swift:109-178` | Direct — directional month reversal was exercised. |
| MOT-15 | Implemented | `Sources/Geraldine/Features/Calendar/CalendarPopover.swift:375-428` | Surface loaded — the time-travel controls loaded; a complete scrub recording was not captured. |
| MOT-16 | Implemented | `Sources/Geraldine/Components/Charts.swift:521-548` | Representative — live Activity and popover charts were captured. |
| MOT-17 | Implemented | `Sources/Geraldine/Components/Charts.swift:53-145` | Direct — chart accessibility metadata and inspection behavior were verified. |
| MOT-18 | Implemented | `Sources/Geraldine/DesignSystem/Components.swift:274-486` | Representative — live measurement readouts were captured; all unit transitions were not recorded. |
| MOT-19 | Implemented | `Sources/Geraldine/Components/ScanResultsView.swift:42-140` | Surface loaded — scan and Smart Care review surfaces loaded successfully. |
| MOT-20 | Implemented | `Sources/Geraldine/MenuBar/MenuBarView.swift:139-179` | Direct — the installed popover opened and its final composition was captured. |
| MOT-21 | Implemented | `Sources/Geraldine/DesignSystem/WorkflowComponents.swift:184-243` | Surface loaded — Maintenance and Updater loaded their stateful controls. |
| MOT-22 | Implemented | `Sources/Geraldine/Features/Battery/BatteryView.swift:267-328` | Not directly verified — the test Mac has no internal battery. |
| MOT-23 | Implemented | `Sources/Geraldine/Features/SpaceLens/SpaceLensView.swift:120-238` | Direct — installed Space Lens drill-in was exercised. |
| MOT-24 | Implemented | `Sources/Geraldine/Features/Permissions/PermissionsView.swift:288-301` | Direct — permission return state was verified after relaunch. |
| MOT-25 | Implemented | `Sources/Geraldine/Features/Onboarding/Onboarding.swift:44-72` | Direct — Settings and onboarding sheet paths were exercised. |
