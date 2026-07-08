import SwiftUI

enum ReadinessStatus {
    case ready
    case needsSetup
    case optional
    case onDemand
    case included

    var label: String {
        switch self {
        case .ready:      return "Ready"
        case .needsSetup: return "Needs Setup"
        case .optional:   return "Optional"
        case .onDemand:   return "On Demand"
        case .included:   return "Included"
        }
    }

    var icon: String {
        switch self {
        case .ready, .included: return "checkmark.circle.fill"
        case .needsSetup:       return "exclamationmark.triangle.fill"
        case .optional:         return "circle.dashed"
        case .onDemand:         return "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .ready, .included: return Theme.good
        case .needsSetup:       return Theme.warn
        case .optional:         return .secondary
        case .onDemand:         return Theme.accent2
        }
    }
}

struct ReadinessStatusPill: View {
    var status: ReadinessStatus
    var labelOverride: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
            Text(labelOverride ?? status.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.14), in: Capsule())
        .foregroundStyle(status.tint)
    }
}

/// One home for every system permission Geraldine can ask for. Each card explains the
/// feature impact before it asks for access, and separates permanent setup from macOS
/// prompts that only appear when the user runs a specific action.
struct PermissionsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .permissions)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    readinessSummary
                    fullDiskCard
                    accessibilityCard
                    locationCard
                    automationAndFilesCard
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            state.refreshPermissions()
            network.refreshNameAccess()
        }
    }

    private var requiredMissingCount: Int {
        [state.hasFullDiskAccess, state.hasAccessibility].filter { !$0 }.count
    }

    private var readinessSummary: some View {
        let ready = requiredMissingCount == 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: ready ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(ready ? Theme.good : Module.permissions.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(ready ? "Geraldine Is Ready" : "Finish Geraldine Setup")
                            .font(.rounded(19, .semibold))
                        ReadinessStatusPill(status: ready ? .ready : .needsSetup,
                                            labelOverride: ready ? nil : "\(requiredMissingCount) Step\(requiredMissingCount == 1 ? "" : "s") Left")
                    }
                    Text(ready
                         ? "Full Disk Access and Accessibility are enabled, so Cleanup, Space Lens, and Power Tools can run without degraded results."
                         : "Full Disk Access and Accessibility unlock Geraldine's core cleanup, disk insight, and automation features. Location is optional, and Finder or file prompts appear only when a specific action needs them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .card()
    }

    // MARK: Full Disk Access

    private var fullDiskCard: some View {
        PermissionCard(
            icon: "externaldrive.fill",
            tint: Theme.accent,
            title: "Full Disk Access",
            status: state.hasFullDiskAccess ? .ready : .needsSetup,
            summary: "Required for complete cleanup and disk insight.",
            impact: "Feature impact: Cleanup, Privacy cleanup, Space Lens, Large & Old Files, and Uninstaller leftover scans can miss protected folders without it.",
            note: state.hasFullDiskAccess ? nil : "If it still shows as off right after you allow it, quit and reopen Geraldine, then recheck."
        ) {
            if !state.hasFullDiskAccess {
                Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            Button("Recheck") { state.refreshFullDiskAccess() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Accessibility

    private var accessibilityCard: some View {
        PermissionCard(
            icon: "accessibility",
            tint: Module.powerTools.tint,
            title: "Accessibility",
            status: state.hasAccessibility ? .ready : .needsSetup,
            summary: "Required for Power Tools and Idle Activity.",
            impact: "Feature impact: window controls, Dock behavior, keyboard shortcuts, Idle Activity pulses, and other system-level helpers stay limited until macOS trusts Geraldine."
        ) {
            if !state.hasAccessibility {
                Button("Grant Access") {
                    Permissions.requestAccessibilityAccess()
                    state.refreshAccessibility()
                }
                .buttonStyle(.borderedProminent).tint(Module.powerTools.tint)
            }
            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                .buttonStyle(.bordered)
            Button("Recheck") { state.refreshAccessibility() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Location

    private var locationCard: some View {
        PermissionCard(
            icon: "location.fill",
            tint: Theme.accent2,
            title: "Location",
            status: network.nameAccess == .authorized ? .ready : .optional,
            summary: "Optional, only for showing the current Wi-Fi network name.",
            impact: "Feature impact: the menu bar network widget can still show connection type, signal, speed test, and traffic. Without Location, macOS hides the SSID.",
            note: network.nameAccess == .denied ? "Location is currently turned off for Geraldine in System Settings." : nil
        ) {
            switch network.nameAccess {
            case .undetermined:
                Button("Allow Location") { network.requestNameAccessAndOpenSettings() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent2)
            case .denied:
                Button("Open Settings") { NetworkMonitor.openLocationSettings() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent2)
            case .authorized:
                Button("Open Settings") { NetworkMonitor.openLocationSettings() }
                    .buttonStyle(.bordered)
            }
            Button("Recheck") { network.refreshNameAccess() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Apple Events, Finder automation, and file access

    private var automationAndFilesCard: some View {
        PermissionCard(
            icon: "finder",
            tint: Module.loginItems.tint,
            title: "Apple Events, Finder & File Access",
            status: .onDemand,
            summary: "Handled by macOS when a feature actually needs it.",
            impact: "Feature impact: Finder automation is used for actions such as revealing items, sending approved files to Trash, and coordinating file operations. File pickers grant access to the folders or files you choose.",
            note: "These are not first-run setup switches. macOS may show an Automation, Files and Folders, or folder picker prompt at the moment Geraldine performs that action."
        ) {
            EmptyView()
        }
    }
}

// MARK: - Permission card

/// A single permission row: icon, readiness state, what it unlocks, feature impact,
/// optional fine print, and the caller's action buttons.
private struct PermissionCard<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let status: ReadinessStatus
    let summary: String
    let impact: String
    var note: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 42, height: 42)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.rounded(16, .semibold))
                        ReadinessStatusPill(status: status)
                    }
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            Text(impact)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                actions
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

// MARK: - Dashboard banner

/// Gentle Dashboard nudge shown only when a *functional* permission is still off. It routes
/// to the Permissions page rather than nagging in place; optional access (Location) never
/// triggers it.
struct PermissionsBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if !state.hasFullDiskAccess {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(Module.permissions.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish Setting Up Geraldine").font(.rounded(14, .semibold))
                    Text(bannerDetail)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review Permissions") { state.selection = .permissions }
                    .buttonStyle(.borderedProminent).tint(Module.permissions.tint)
            }
            .card(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Module.permissions.tint.opacity(0.35), lineWidth: 1))
        }
    }

    private var bannerDetail: String {
        "Full Disk Access is off, so cleanup, privacy cleanup, disk insight, and leftover scans may miss protected folders."
    }
}
