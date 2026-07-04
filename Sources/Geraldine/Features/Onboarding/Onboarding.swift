import SwiftUI

/// First-run checklist for the setup choices that affect Geraldine's first impression
/// and feature readiness.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @EnvironmentObject private var widgetLayout: WidgetLayoutStore
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                appearanceCard
                launchAtLoginCard
                permissionsChecklist
                calendarClocksCard
                footer
            }
            .padding(30)
        }
        .frame(width: 680, height: 720)
        .onAppear {
            state.refreshPermissions()
            network.refreshNameAccess()
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 78, height: 78)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Set Up Geraldine").font(.rounded(28, .bold))
                Text("Choose how Geraldine appears, decide whether it starts with macOS, and grant the access that unlocks cleanup, disk insight, Power Tools, and network names.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklistHeader(icon: "menubar.dock.rectangle",
                            title: "App Appearance",
                            status: .included)
            AppearanceModePicker()
        }
        .card()
    }

    private var launchAtLoginCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            checklistHeader(icon: "power",
                            title: "Launch Geraldine at Login",
                            status: launchAtLoginEnabled ? .ready : .optional)
            LaunchAtLoginControl { launchAtLoginEnabled = $0 }
        }
        .card()
    }

    private var permissionsChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Permissions", subtitle: "Core access can be granted now or later from the Permissions page.")

            OnboardingChecklistRow(
                icon: "externaldrive.fill",
                tint: Theme.accent,
                title: "Full Disk Access",
                detail: "Required for complete Cleanup, Space Lens, Large & Old Files, Privacy cleanup, and app leftover scans.",
                status: state.hasFullDiskAccess ? .ready : .needsSetup
            ) {
                if !state.hasFullDiskAccess {
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                Button("Recheck") { state.refreshFullDiskAccess() }
                    .buttonStyle(.bordered)
            }

            Divider()

            OnboardingChecklistRow(
                icon: "accessibility",
                tint: Module.powerTools.tint,
                title: "Accessibility",
                detail: "Required for Power Tools such as window controls, Dock behavior, and keyboard automation.",
                status: state.hasAccessibility ? .ready : .needsSetup
            ) {
                if !state.hasAccessibility {
                    Button("Grant Access") {
                        Permissions.requestAccessibilityAccess()
                        state.refreshAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Module.powerTools.tint)
                }
                Button("Recheck") { state.refreshAccessibility() }
                    .buttonStyle(.bordered)
            }

            Divider()

            OnboardingChecklistRow(
                icon: "location.fill",
                tint: Theme.accent2,
                title: "Location",
                detail: "Optional. macOS requires it only to show the current Wi-Fi network name; Geraldine does not track or store your location.",
                status: network.nameAccess == .authorized ? .ready : .optional
            ) {
                switch network.nameAccess {
                case .undetermined:
                    Button("Allow Location") { network.requestNameAccessAndOpenSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent2)
                case .denied:
                    Button("Open Settings") { NetworkMonitor.openLocationSettings() }
                        .buttonStyle(.bordered)
                case .authorized:
                    Button("Open Settings") { NetworkMonitor.openLocationSettings() }
                        .buttonStyle(.bordered)
                }
                Button("Recheck") { network.refreshNameAccess() }
                    .buttonStyle(.bordered)
            }
        }
        .card()
    }

    private var calendarClocksCard: some View {
        let isWidgetShown = widgetLayout.items.first { $0.kind == .calendar }?.isShown ?? false
        let isIncluded = calendar.appearsInPopover && isWidgetShown
        return OnboardingChecklistRow(
            icon: Module.calendar.systemImage,
            tint: Module.calendar.tint,
            title: "Calendar & Clocks",
            detail: calendarClocksDetail(isWidgetShown: isWidgetShown),
            status: isIncluded ? .included : .optional
        ) {
            Button(isIncluded ? "Set Up" : "Show & Set Up") {
                widgetLayout.setShown(.calendar, true)
                state.selection = .calendar
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .tint(Module.calendar.tint)
        }
        .card()
    }

    private func calendarClocksDetail(isWidgetShown: Bool) -> String {
        if calendar.appearsInPopover && isWidgetShown {
            return "Calendar & Clocks is already in the menu bar popover. Open setup to adjust date format, week options, seconds, and world clocks."
        }
        if calendar.appearsInPopover {
            return "Calendar content is enabled, but its widget is hidden. Show it here, or use Customize in the menu bar popover."
        }
        return "Choose whether the calendar, local clock, and world clocks appear in the menu bar popover."
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Nothing is deleted without review. Files outside the Trash move to the Trash first; Trash cleanup asks again before permanent deletion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            PrimaryButton(title: "Start Using Geraldine", icon: "arrow.right", action: onDone)
        }
        .padding(.top, 2)
    }

    private func checklistHeader(icon: String, title: String, status: ReadinessStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(status.tint)
                .frame(width: 22)
            Text(title).font(.rounded(16, .semibold))
            ReadinessStatusPill(status: status)
            Spacer()
        }
    }
}

private struct OnboardingChecklistRow<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let status: ReadinessStatus
    let actions: Actions

    init(icon: String,
         tint: Color,
         title: String,
         detail: String,
         status: ReadinessStatus,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.tint = tint
        self.title = title
        self.detail = detail
        self.status = status
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.rounded(15, .semibold))
                    ReadinessStatusPill(status: status)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    actions
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
    }
}
