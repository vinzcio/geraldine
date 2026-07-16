import AppKit
import SwiftUI

enum ReadinessStatus: Hashable {
    case ready
    case needsSetup
    case optional
    case onDemand
    case included

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .needsSetup: return "Needs Setup"
        case .optional: return "Optional"
        case .onDemand: return "On Demand"
        case .included: return "Included"
        }
    }

    var icon: String {
        switch self {
        case .ready, .included: return "checkmark.circle.fill"
        case .needsSetup: return "exclamationmark.triangle.fill"
        case .optional: return "circle.dashed"
        case .onDemand: return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .included: return Theme.good
        case .needsSetup: return Theme.warn
        case .optional: return .secondary
        case .onDemand: return Theme.accent2
        }
    }
}

struct ReadinessStatusPill: View {
    var status: ReadinessStatus
    var labelOverride: String?

    var body: some View {
        HStack(spacing: 4) {
            PermissionStatusSymbol(status: status, size: 11)
            Text(labelOverride ?? status.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.12), in: Capsule())
        .foregroundStyle(status.tint)
        .accessibilityElement(children: .combine)
    }
}

private struct PermissionStatusSymbol: View {
    let status: ReadinessStatus
    let size: CGFloat

    var body: some View {
        WorkflowPhaseHost(phase: status) {
            Image(systemName: status.icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(status.tint)
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityHidden(true)
    }
}

/// One home for every system permission Geraldine can ask for. Required,
/// optional, and on-demand access stay visually distinct and system-owned
/// prompts remain native.
struct PermissionsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var network: NetworkMonitor
    @State private var handoffTarget: PermissionKind?
    @State private var returningTarget: PermissionKind?
    @State private var returnTone: OutcomeTone?

    var body: some View {
        ModulePage(module: .permissions, headerStyle: .utility, widthRole: .readable) {
            readinessSummary

            SectionHeader("Required Access",
                          subtitle: "These two permissions unlock Geraldine's core care and automation features.")
            fullDiskCard
            accessibilityCard

            SectionHeader("Optional Access",
                          subtitle: "Geraldine remains useful without this; only the named detail is unavailable.")
            locationCard

            SectionHeader("On-Demand Access",
                          subtitle: "macOS asks only when an action needs a native picker or automation handoff.")
            automationAndFilesCard
        }
        .onAppear { refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            acknowledgeSystemReturnIfNeeded()
        }
    }

    private var requiredMissingCount: Int {
        [state.hasFullDiskAccess, state.hasAccessibility].filter { !$0 }.count
    }

    private var requiredReadyCount: Int { 2 - requiredMissingCount }

    private var readinessSummary: some View {
        let ready = requiredMissingCount == 0
        return HStack(spacing: Theme.Spacing.lg) {
            WorkflowMark(state: ready ? .success : .warning,
                         tint: Module.permissions.tint,
                         idleIcon: "lock.shield.fill",
                         size: 74)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(ready ? "Geraldine Is Ready" : "Finish Geraldine Setup")
                        .font(.geraldineSection)
                    ReadinessStatusPill(
                        status: ready ? .ready : .needsSetup,
                        labelOverride: ready ? nil : "\(requiredMissingCount) Step\(requiredMissingCount == 1 ? "" : "s") Left"
                    )
                }

                Text(ready
                     ? "Core cleanup, disk insight, Power Tools, and Idle Activity can run without degraded results."
                     : "Complete the required access below. Optional Location and on-demand Finder prompts can wait until you need them.")
                    .font(.geraldineBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.xs) {
                    ProgressView(value: Double(requiredReadyCount), total: 2)
                        .tint(ready ? Theme.good : Module.permissions.tint)
                        .frame(maxWidth: 260)
                    Text("\(requiredReadyCount) of 2 required")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .outcomeWash(ready ? .success : .warning)
        .card(tier: .tinted(ready ? Theme.good : Module.permissions.tint))
    }

    private var fullDiskCard: some View {
        PermissionCard(
            icon: "externaldrive.fill",
            tint: Theme.accent,
            title: "Full Disk Access",
            requirement: .required,
            status: state.hasFullDiskAccess ? .ready : .needsSetup,
            summary: "Required for complete cleanup and disk insight.",
            impact: "Cleanup, Privacy cleanup, Large & Old Files, and Uninstaller leftover scans can miss protected folders without it.",
            note: state.hasFullDiskAccess ? nil : "If it still shows as off right after you allow it, quit and reopen Geraldine, then recheck.",
            returnTone: tone(for: .fullDisk)
        ) {
            if !state.hasFullDiskAccess {
                Button("Open Settings") { openSystemSettings(.fullDisk) }
                    .buttonStyle(.soft(Theme.accent))
            }
            Button("Recheck") { recheck(.fullDisk) }
                .buttonStyle(.quiet(Theme.accent))
        }
    }

    private var accessibilityCard: some View {
        PermissionCard(
            icon: "accessibility",
            tint: Module.powerTools.tint,
            title: "Accessibility",
            requirement: .required,
            status: state.hasAccessibility ? .ready : .needsSetup,
            summary: "Required for Power Tools and Idle Activity.",
            impact: "Window controls, Dock behavior, keyboard shortcuts, Idle Activity pulses, and other system-level helpers stay limited until macOS trusts Geraldine.",
            returnTone: tone(for: .accessibility)
        ) {
            if !state.hasAccessibility {
                Button("Grant Access") { requestAccessibility() }
                    .buttonStyle(.soft(Module.powerTools.tint))
            }
            Button("Open Settings") { openSystemSettings(.accessibility) }
                .buttonStyle(.quiet(Module.powerTools.tint))
            Button("Recheck") { recheck(.accessibility) }
                .buttonStyle(.quiet(Module.powerTools.tint))
        }
    }

    private var locationCard: some View {
        PermissionCard(
            icon: "location.fill",
            tint: Theme.accent2,
            title: "Location",
            requirement: .optional,
            status: network.nameAccess == .authorized ? .ready : .optional,
            summary: "Optional, only for showing the current Wi-Fi network name.",
            impact: "The menu bar network widget can still show connection type, signal, speed test, and traffic. Without Location, macOS hides the SSID.",
            note: network.nameAccess == .denied ? "Location is currently turned off for Geraldine in System Settings." : nil,
            returnTone: tone(for: .location)
        ) {
            switch network.nameAccess {
            case .undetermined:
                Button("Allow Location") { requestLocation() }
                    .buttonStyle(.soft(Theme.accent2))
            case .denied:
                Button("Open Settings") { openSystemSettings(.location) }
                    .buttonStyle(.soft(Theme.accent2))
            case .authorized:
                Button("Open Settings") { openSystemSettings(.location) }
                    .buttonStyle(.quiet(Theme.accent2))
            }
            Button("Recheck") { recheck(.location) }
                .buttonStyle(.quiet(Theme.accent2))
        }
    }

    private var automationAndFilesCard: some View {
        PermissionCard(
            icon: "finder",
            tint: Module.loginItems.tint,
            title: "Apple Events, Finder & File Access",
            requirement: .onDemand,
            status: .onDemand,
            summary: "Handled by macOS when a feature actually needs it.",
            impact: "Finder automation reveals items, sends approved files to Trash, and coordinates file operations. File pickers grant access only to the folders or files you choose.",
            note: "These are not first-run setup switches. macOS may show an Automation, Files and Folders, or folder picker prompt at the moment Geraldine performs that action.",
            returnTone: nil
        ) {
            EmptyView()
        }
    }

    private func refreshAll() {
        state.refreshPermissions()
        network.refreshNameAccess()
    }

    private func openSystemSettings(_ kind: PermissionKind) {
        handoffTarget = kind
        switch kind {
        case .fullDisk: Permissions.openFullDiskAccessSettings()
        case .accessibility: Permissions.openAccessibilitySettings()
        case .location: NetworkMonitor.openLocationSettings()
        case .automation: break
        }
    }

    private func requestAccessibility() {
        handoffTarget = .accessibility
        Permissions.requestAccessibilityAccess()
        state.refreshAccessibility()
        showReturnFeedback(for: .accessibility)
    }

    private func requestLocation() {
        handoffTarget = .location
        network.requestNameAccessAndOpenSettings()
    }

    private func recheck(_ kind: PermissionKind) {
        refresh(kind)
        showReturnFeedback(for: kind)
    }

    private func acknowledgeSystemReturnIfNeeded() {
        guard let target = handoffTarget else { return }
        handoffTarget = nil
        refresh(target)
        showReturnFeedback(for: target)
    }

    private func refresh(_ kind: PermissionKind) {
        switch kind {
        case .fullDisk: state.refreshFullDiskAccess()
        case .accessibility: state.refreshAccessibility()
        case .location: network.refreshNameAccess()
        case .automation: break
        }
    }

    private func showReturnFeedback(for kind: PermissionKind) {
        returningTarget = kind
        returnTone = isReady(kind) ? .success : .warning
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if returningTarget == kind {
                returningTarget = nil
                returnTone = nil
            }
        }
    }

    private func tone(for kind: PermissionKind) -> OutcomeTone? {
        returningTarget == kind ? returnTone : nil
    }

    private func isReady(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .fullDisk: state.hasFullDiskAccess
        case .accessibility: state.hasAccessibility
        case .location: network.nameAccess == .authorized
        case .automation: true
        }
    }
}

private enum PermissionKind: Hashable {
    case fullDisk
    case accessibility
    case location
    case automation
}

private enum PermissionRequirement: String {
    case required = "Required"
    case optional = "Optional"
    case onDemand = "On Demand"

    var icon: String {
        switch self {
        case .required: "asterisk.circle.fill"
        case .optional: "circle.dashed"
        case .onDemand: "hand.tap.fill"
        }
    }
}

private struct PermissionCard<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let requirement: PermissionRequirement
    let status: ReadinessStatus
    let summary: String
    let impact: String
    var note: String? = nil
    let returnTone: OutcomeTone?
    @ViewBuilder var actions: Actions

    @State private var showsImpact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                ModuleGlyph(systemImage: icon, tint: tint, size: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(title).font(.geraldineSection)
                        requirementPill
                        ReadinessStatusPill(status: status)
                    }
                    Text(summary)
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.xs)
            }

            HStack(spacing: Theme.Spacing.xs) {
                actions
            }

            Button {
                showsImpact.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(showsImpact ? "Hide Feature Impact" : "What This Unlocks")
                    ContextualSymbol(inactive: "chevron.down",
                                     active: "chevron.up",
                                     isActive: showsImpact,
                                     tint: tint,
                                     size: 11)
                }
            }
            .buttonStyle(.quiet(tint))

            if showsImpact {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(impact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Label(note, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceMuted,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .transition(.opacity)
            }
        }
        .outcomeWash(returnTone)
        .interactiveCard(tier: cardTier)
        .geraldineAnimation(.standard, value: showsImpact)
    }

    private var requirementPill: some View {
        Label(requirement.rawValue, systemImage: requirement.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(requirementTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(requirementTint.opacity(0.09), in: Capsule())
    }

    private var requirementTint: Color {
        switch requirement {
        case .required: return Theme.warn
        case .optional: return Color.secondary
        case .onDemand: return Theme.accent2
        }
    }

    private var cardTier: CardTier {
        switch status {
        case .ready, .included: return .tinted(Theme.good)
        case .needsSetup: return .tinted(Theme.warn)
        case .optional: return .raised
        case .onDemand: return .tinted(Theme.accent2)
        }
    }
}

/// Gentle Dashboard nudge shown only when a functional permission is still off.
struct PermissionsBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if !state.hasFullDiskAccess {
            HStack(spacing: Theme.Spacing.sm) {
                ModuleGlyph(systemImage: "lock.shield.fill", tint: Module.permissions.tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish Setting Up Geraldine").font(.rounded(14, .semibold))
                    Text(bannerDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review Permissions") { state.selection = .permissions }
                    .buttonStyle(.soft(Module.permissions.tint))
            }
            .card(padding: Theme.Spacing.md, tier: .tinted(Module.permissions.tint))
        }
    }

    private var bannerDetail: String {
        "Full Disk Access is off, so cleanup, privacy cleanup, disk insight, and leftover scans may miss protected folders."
    }
}
