import AppKit
import SwiftUI

private enum OnboardingStage: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case presence
    case readiness
    case finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Meet Geraldine"
        case .presence: "Choose Her Place"
        case .readiness: "Get Ready"
        case .finish: "You're Set"
        }
    }

    var shortTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .presence: "Presence"
        case .readiness: "Readiness"
        case .finish: "Finish"
        }
    }
}

/// A staged first run: identity, a live presence preview, permission readiness,
/// and a clear completion handoff. It keeps native permission surfaces intact.
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @EnvironmentObject private var widgetLayout: WidgetLayoutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: OnboardingStage = .welcome
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled

    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stageRail
            Divider().opacity(0.45)

            ScrollView {
                WorkflowPhaseHost(phase: stage) {
                    stageContent
                        .frame(maxWidth: 660, alignment: .topLeading)
                        .padding(Theme.Spacing.xxl)
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().opacity(0.45)
            navigationFooter
        }
        .background {
            ZStack {
                Theme.canvas
                RadialGradient(
                    colors: [Theme.accent.opacity(0.12), .clear],
                    center: UnitPoint(x: 0.12, y: 0.04),
                    startRadius: 0,
                    endRadius: 430
                )
            }
        }
        .frame(width: 720, height: 680)
        .onAppear(perform: refreshReadiness)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }

    private var stageRail: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(OnboardingStage.allCases) { item in
                HStack(spacing: Theme.Spacing.xs) {
                    ZStack {
                        Circle()
                            .fill(item.rawValue <= stage.rawValue ? Theme.accent : Theme.surfaceMuted)
                        if item.rawValue < stage.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(item.rawValue + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(item.rawValue <= stage.rawValue ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(item.shortTitle)
                        .font(.caption.weight(item == stage ? .semibold : .regular))
                        .foregroundStyle(item == stage ? .primary : .secondary)
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, 6)
                .background(
                    item == stage ? Theme.accent.opacity(0.09) : Color.clear,
                    in: Capsule()
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(item == stage ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surfaceBase)
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .welcome:
            welcomeStage
        case .presence:
            presenceStage
        case .readiness:
            readinessStage
        case .finish:
            finishStage
        }
    }

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.pageSpacing) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                GeraldineMark(size: 92)
                    .geraldineEntrance()
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Meet Geraldine")
                        .font(.geraldineHero)
                    Text("A quietly alive Mac-care instrument that watches the useful signals, explains what changed, and asks before it removes anything.")
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .geraldineEntrance(delay: 0.08)
            }

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                OnboardingPrinciple(
                    icon: "waveform.path.ecg",
                    tint: Theme.accent2,
                    title: "Quietly Live",
                    detail: "CPU, memory, network, storage, power, and thermal signals stay readable without becoming a wall of gauges."
                )
                OnboardingPrinciple(
                    icon: "checkmark.shield.fill",
                    tint: Theme.good,
                    title: "Review First",
                    detail: "Files move to the Trash when possible, sensitive data stays opt-in, and destructive actions keep their native confirmation."
                )
            }
        }
    }

    private var presenceStage: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.pageSpacing) {
            stageHeading(
                "Choose Geraldine's Place",
                "Pick the presence that fits your Mac. The preview and app policy update immediately."
            )
            AppShapePreview(shape: state.appShape)
            AppearanceModePicker()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                SectionHeader(
                    "Start With macOS",
                    subtitle: "This affects Geraldine only; other startup apps remain in Login Items."
                )
                LaunchAtLoginControl { launchAtLoginEnabled = $0 }
            }
            .card(tier: .base)
        }
    }

    private var readinessStage: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.pageSpacing) {
            stageHeading(
                "Get Geraldine Ready",
                "Core access can be granted now or later. Geraldine never imitates macOS permission dialogs."
            )

            VStack(spacing: 0) {
                readinessRow(
                    icon: "externaldrive.fill",
                    tint: Theme.accent,
                    title: "Full Disk Access",
                    detail: "Required for complete cleanup, Space Lens, large-file scans, privacy cleanup, and app leftovers.",
                    status: state.hasFullDiskAccess ? .ready : .needsSetup
                ) {
                    if !state.hasFullDiskAccess {
                        Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                            .buttonStyle(.soft(Theme.accent))
                    }
                    Button("Recheck") { state.refreshFullDiskAccess() }
                        .buttonStyle(.quiet(Theme.accent))
                }

                Divider().padding(.leading, 48)

                readinessRow(
                    icon: "accessibility",
                    tint: Module.powerTools.tint,
                    title: "Accessibility",
                    detail: "Required for window, Dock, keyboard, and automation Power Tools.",
                    status: state.hasAccessibility ? .ready : .needsSetup
                ) {
                    if !state.hasAccessibility {
                        Button("Grant Access") {
                            Permissions.requestAccessibilityAccess()
                            state.refreshAccessibility()
                        }
                        .buttonStyle(.soft(Module.powerTools.tint))
                    }
                    Button("Recheck") { state.refreshAccessibility() }
                        .buttonStyle(.quiet(Module.powerTools.tint))
                }

                Divider().padding(.leading, 48)

                readinessRow(
                    icon: "location.fill",
                    tint: Theme.accent2,
                    title: "Location For Wi-Fi Name",
                    detail: "Optional. macOS requires Location only to reveal the current Wi-Fi network name; Geraldine does not store location.",
                    status: network.nameAccess == .authorized ? .ready : .optional
                ) {
                    if network.nameAccess == .undetermined {
                        Button("Allow Location") { network.requestNameAccessAndOpenSettings() }
                            .buttonStyle(.soft(Theme.accent2))
                    } else {
                        Button("Open Settings") { NetworkMonitor.openLocationSettings() }
                            .buttonStyle(.quiet(Theme.accent2))
                    }
                    Button("Recheck") { network.refreshNameAccess() }
                        .buttonStyle(.quiet(Theme.accent2))
                }
            }
            .card(padding: Theme.Spacing.md, tier: .raised, cornerRadius: Theme.Radius.raised)

            calendarReadinessCard
        }
    }

    private var finishStage: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.pageSpacing) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                WorkflowMark(state: .success, tint: Theme.accent, idleIcon: "checkmark", size: 86)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Geraldine Is Ready")
                        .font(.geraldineHero)
                    Text("You can change every choice later. Start with the Dashboard, or open any care module from the sidebar.")
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                CompletionSummary(
                    icon: state.appShape.systemImage,
                    tint: Theme.accent,
                    title: state.appShape.label,
                    detail: launchAtLoginEnabled ? "Starts with macOS" : "Starts when you open it"
                )
                CompletionSummary(
                    icon: "lock.shield.fill",
                    tint: state.hasFullDiskAccess && state.hasAccessibility ? Theme.good : Theme.warn,
                    title: state.hasFullDiskAccess && state.hasAccessibility
                        ? "Core Access Ready"
                        : "Core Access Needs Setup",
                    detail: state.hasFullDiskAccess && state.hasAccessibility
                        ? "Optional access can be added later"
                        : "Finish required access from Permissions"
                )
            }

            Text("Nothing is deleted without review. Files outside the Trash move to the Trash first; Trash cleanup asks again before permanent deletion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Spacing.md)
                .background(Theme.good.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private var calendarReadinessCard: some View {
        let isWidgetShown = widgetLayout.items.first { $0.kind == .calendar }?.isShown ?? false
        let isIncluded = calendar.appearsInPopover && isWidgetShown

        return readinessRow(
            icon: Module.calendar.systemImage,
            tint: Module.calendar.tint,
            title: "Calendar & Clocks",
            detail: isIncluded
                ? "Already included in the menu-bar popover. Open setup to refine date, week, seconds, and world clocks."
                : "Optional. Add the calendar, local clock, and world clocks to Geraldine's popover.",
            status: isIncluded ? .included : .optional
        ) {
            Button(isIncluded ? "Set Up" : "Show & Set Up") {
                widgetLayout.setShown(.calendar, true)
                state.selection = .calendar
                onDone()
            }
            .buttonStyle(.soft(Module.calendar.tint))
        }
        .card(padding: Theme.Spacing.md, tier: .tinted(Module.calendar.tint))
    }

    private var navigationFooter: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                move(to: OnboardingStage(rawValue: stage.rawValue - 1) ?? .welcome)
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
            .buttonStyle(.quiet(Theme.accent))
            .disabled(stage == .welcome)

            Spacer()

            if stage == .finish {
                PrimaryButton(title: "Start Using Geraldine", icon: "arrow.right") {
                    onDone()
                }
            } else {
                PrimaryButton(title: "Continue", icon: "arrow.right") {
                    move(to: OnboardingStage(rawValue: stage.rawValue + 1) ?? .finish)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surfaceBase)
    }

    private func stageHeading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.geraldineHero)
            Text(detail)
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readinessRow<Actions: View>(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        status: OnboardingReadiness,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            ModuleGlyph(systemImage: icon, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(title).font(.rounded(14, .semibold))
                    OnboardingStatusPill(status: status)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.xs) { actions() }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }

    private func move(to newStage: OnboardingStage) {
        if let animation = GeraldineMotion.animation(.standard, reduceMotion: reduceMotion) {
            withAnimation(animation) { stage = newStage }
        } else {
            stage = newStage
        }
    }

    private func refreshReadiness() {
        state.refreshPermissions()
        network.refreshNameAccess()
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }
}

private enum OnboardingReadiness {
    case ready
    case needsSetup
    case included
    case optional

    var label: String {
        switch self {
        case .ready: "Ready"
        case .needsSetup: "Needs Setup"
        case .included: "Included"
        case .optional: "Optional"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .included: Theme.good
        case .needsSetup: Theme.warn
        case .optional: Theme.accent2
        }
    }

    var icon: String {
        switch self {
        case .ready, .included: "checkmark"
        case .needsSetup: "exclamationmark"
        case .optional: "circle"
        }
    }
}

private struct OnboardingStatusPill: View {
    let status: OnboardingReadiness

    var body: some View {
        Label(status.label, systemImage: status.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.10), in: Capsule())
    }
}

private struct OnboardingPrinciple: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ModuleGlyph(systemImage: icon, tint: tint, size: 42)
            Text(title).font(.geraldineSection)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tier: .tinted(tint), cornerRadius: Theme.Radius.raised)
    }
}

private struct CompletionSummary: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            ModuleGlyph(systemImage: icon, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.rounded(13, .semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Spacing.md, tier: .base)
    }
}
