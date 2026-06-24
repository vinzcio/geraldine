import SwiftUI

/// One home for every system permission Geraldine can ask for. Nothing here is required
/// to launch — each card explains what its access unlocks and lets the user grant it when
/// they want that feature. Full Disk Access and Accessibility are functional; Location is
/// optional and only reveals the Wi-Fi network name.
struct PermissionsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .permissions)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    fullDiskCard
                    accessibilityCard
                    locationCard
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            state.refreshPermissions()
            network.refreshNameAccess()
        }
    }

    private var intro: some View {
        Text("Geraldine only asks for what a feature needs, and never sends any of it anywhere. Grant access when you want the feature it unlocks — you can change your mind in System Settings any time.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Full Disk Access

    private var fullDiskCard: some View {
        PermissionCard(icon: "externaldrive.fill",
                       tint: Theme.accent,
                       title: "Full Disk Access",
                       detail: "Lets Geraldine scan caches, browser data, mail, and other protected folders so Cleanup and Space Lens can see everything.",
                       granted: state.hasFullDiskAccess,
                       note: state.hasFullDiskAccess ? nil : "If it still shows as off right after you allow it, quit and reopen Geraldine.") {
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
        PermissionCard(icon: "accessibility",
                       tint: Module.powerTools.tint,
                       title: "Accessibility",
                       detail: "Lets Power Tools move and resize windows, tweak the Dock, and run keyboard shortcuts on your behalf.",
                       granted: state.hasAccessibility) {
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
        PermissionCard(icon: "location.fill",
                       tint: Theme.accent2,
                       title: "Location",
                       detail: "Lets macOS reveal the name of the Wi-Fi network you're on — that's the only thing it's used for. Geraldine never tracks or stores your location.",
                       granted: network.nameAccess == .authorized,
                       optional: true,
                       note: network.nameAccess == .denied ? "Location is currently turned off for Geraldine in System Settings." : nil) {
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
        }
    }
}

// MARK: - Permission card

/// A single permission row: icon, title + live status pill, what it unlocks, optional fine
/// print, and the caller's action buttons.
private struct PermissionCard<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    var optional: Bool = false
    var note: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        statusPill
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) { actions }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private var statusPill: some View {
        let label = granted ? "Granted" : (optional ? "Optional" : "Not Granted")
        let color: Color = granted ? Theme.good : (optional ? .secondary : Theme.warn)
        let symbol = granted ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "exclamationmark.triangle.fill")
        return HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
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
                    Text("Full Disk Access is off, so Cleanup and Space Lens can't see your protected folders yet.")
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
}
