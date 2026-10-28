import SwiftUI

/// The Updates card in Settings: what this Mac runs, what the updater is
/// doing, and the two automatic-update switches.
struct AppUpdateSettingsSection: View {
    @EnvironmentObject private var updates: AppUpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            AppUpdateStatusCard(
                status: updates.statusText,
                versionText: Self.versionText(BuildInfo.current),
                updatesEnabled: updates.isEnabled,
                action: action,
                perform: perform
            )
            if updates.isEnabled {
                AppUpdatePreferences(
                    checksAutomatically: Binding(
                        get: { updates.automaticallyChecks },
                        set: { updates.setAutomaticallyChecks($0) }
                    ),
                    installsAutomatically: Binding(
                        get: { updates.automaticallyInstalls },
                        set: { updates.setAutomaticallyInstalls($0) }
                    )
                )
                .disabled(!updates.isRunning)
            }
        }
    }

    private var action: AppUpdateCardAction {
        switch updates.activity {
        case .checking, .downloading, .installing: return .progress
        case .ready: return .restart
        case .available: return .viewUpdate(enabled: updates.canStartUserCheck)
        case .idle: return updates.isEnabled ? .checkNow(enabled: updates.canStartUserCheck) : .none
        }
    }

    private func perform() {
        if updates.isReadyToRestart { updates.restartToUpdate() } else { updates.checkForUpdates() }
    }

    static func versionText(_ build: BuildInfo) -> String {
        build.bundleVersion == build.version ? build.version : "\(build.version) (\(build.bundleVersion))"
    }
}

enum AppUpdateCardAction: Equatable {
    case none
    case progress
    case checkNow(enabled: Bool)
    case viewUpdate(enabled: Bool)
    case restart
}

struct AppUpdateStatusCard: View {
    let status: AppUpdateStatusText
    let versionText: String
    let updatesEnabled: Bool
    let action: AppUpdateCardAction
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(status.title)
                    .font(.geraldineSection)
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("This Mac runs Geraldine \(versionText).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Spacing.sm)
            control
        }
        .padding(Theme.Spacing.md)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var control: some View {
        switch action {
        case .none:
            EmptyView()
        case .progress:
            ProgressView().controlSize(.small)
        case .checkNow(let enabled):
            Button("Check Now", action: perform)
                .buttonStyle(.quiet(Theme.accent, compact: true))
                .disabled(!enabled)
        case .viewUpdate(let enabled):
            Button("View Update", action: perform)
                .buttonStyle(.soft(Theme.accent))
                .disabled(!enabled)
        case .restart:
            Button("Restart To Update", action: perform)
                .buttonStyle(.soft(Theme.accent))
        }
    }

    private var symbol: String {
        switch status.tone {
        case .neutral: return updatesEnabled ? "arrow.triangle.2.circlepath" : "shippingbox"
        case .good: return "arrow.down.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch status.tone {
        case .neutral: return Theme.accent
        case .good: return Theme.good
        case .attention: return Theme.warn
        }
    }
}

struct AppUpdatePreferences: View {
    @Binding var checksAutomatically: Bool
    @Binding var installsAutomatically: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle("Check For Updates Automatically", isOn: $checksAutomatically)
            Toggle("Install Updates Automatically", isOn: $installsAutomatically)
                .disabled(!checksAutomatically)
            Text("Updates download in the background. Geraldine restarts to install one only while its window and menu bar panel are closed, and a running Keep Awake session continues after the restart, Stay Active included.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Theme.accent)
    }
}

/// A one-line prompt in the sidebar and the menu bar panel, shown only when an
/// update is waiting on the person: ready to restart, or found while automatic
/// installs are off.
struct AppUpdateNotice: View {
    @EnvironmentObject private var updates: AppUpdateController

    var body: some View {
        if let release = updates.actionableRelease {
            AppUpdateNoticeButton(release: release, isReady: updates.isReadyToRestart) {
                if updates.isReadyToRestart { updates.restartToUpdate() } else { updates.checkForUpdates() }
            }
        }
    }
}

struct AppUpdateNoticeButton: View {
    let release: AppUpdateRelease
    let isReady: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isReady ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isReady ? "Geraldine \(release.version) Is Ready" : "Geraldine \(release.version) Is Available")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(isReady ? "Restart To Update" : "View Update")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.actionableCard(padding: 10, tier: .tinted(Theme.accent), cornerRadius: Theme.Radius.control))
        .help(isReady ? "Restart Geraldine to finish installing \(release.version)" : "Review Geraldine \(release.version)")
    }
}

/// Geraldine ▸ Check for Updates…
struct CheckForUpdatesCommand: View {
    @ObservedObject var updates: AppUpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canStartUserCheck)
    }
}
