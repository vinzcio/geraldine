import SwiftUI

/// The native Settings scene is intentionally a gateway. Geraldine's canonical
/// configuration surface lives in the main window so appearance, permissions,
/// Keep Awake behavior, previews, and build context stay in one place.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(
                colors: [Theme.accent.opacity(0.14), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )

            VStack(spacing: Theme.Spacing.lg) {
                GeraldineMark(size: 68)
                VStack(spacing: Theme.Spacing.xs) {
                    Text("Geraldine Settings")
                        .font(.geraldineTitle)
                    Text("All settings live together in the main Geraldine window, alongside the features they affect.")
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryButton(title: "Open Settings", icon: "arrow.up.forward.app") {
                    state.open(.settings)
                    dismiss()
                }
            }
            .padding(Theme.Spacing.xxl)
            .frame(maxWidth: 390)
        }
        .frame(width: 460, height: 330)
    }
}

struct AppSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ModulePage(
            module: .settings,
            title: "Geraldine Settings",
            subtitle: "Shape how Geraldine appears, behaves, and earns access.",
            headerStyle: .utility,
            widthRole: .focused
        ) {
            SettingsSectionCard(tier: .tinted(Theme.accent)) {
                SectionHeader(
                    "Appearance",
                    subtitle: "Choose Geraldine's presence. The preview updates with the selected shape."
                )
                AppShapePreview(shape: state.appShape)
                AppearanceModePicker()
            }

            SettingsSectionCard {
                SectionHeader(
                    "Keep Awake",
                    subtitle: "Defaults and safety policies for new sessions. Active sessions keep their current duration."
                )
                KeepAwakeSettingsPreview()
                KeepAwakeSettingsControls()
            }

            SettingsSectionCard {
                SectionHeader(
                    "Geraldine Startup",
                    subtitle: "Controls Geraldine itself, not other apps that start with macOS."
                )
                LaunchAtLoginControl()
            }

            SettingsSectionCard(tier: .tinted(Theme.accent2)) {
                SectionHeader(
                    "Coding Usage",
                    subtitle: AIUsageDisclosure.current.text
                )
                ForEach(AICodingProvider.allCases) { provider in
                    AIUsageConnectionRow(provider: provider)
                }
            }

            SettingsSectionCard(tier: .tinted(Module.permissions.tint)) {
                SectionHeader(
                    "Readiness",
                    subtitle: "See which capabilities are ready and open the full Permissions page for details."
                )
                PermissionStatusRow(
                    title: "Full Disk Access",
                    detail: "Complete cleanup and disk insight",
                    granted: state.hasFullDiskAccess
                )
                PermissionStatusRow(
                    title: "Accessibility",
                    detail: "Window, Dock, keyboard, and automation tools",
                    granted: state.hasAccessibility
                )
                Button {
                    state.open(.permissions)
                } label: {
                    Label("Review Permissions", systemImage: "arrow.right")
                }
                .buttonStyle(.soft(Module.permissions.tint))
            }

            SettingsSectionCard(tier: .base) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    GeraldineMark(size: 54)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        SectionHeader("About Geraldine", subtitle: "A quietly alive Mac-care instrument.")
                        Text(BuildInfo.current.versionLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        BuildInfoRows()
                    }
                }
            }
        }
        .onAppear { state.refreshPermissions() }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let tier: CardTier
    @ViewBuilder let content: Content

    init(tier: CardTier = .raised, @ViewBuilder content: () -> Content) {
        self.tier = tier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            content
        }
        .card(padding: Theme.Spacing.lg, tier: tier, cornerRadius: Theme.Radius.raised)
    }
}

private struct KeepAwakeSettingsPreview: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            EyeView(isActive: keepAwake.isActive, size: 52)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(keepAwake.isActive ? "A session is active" : "Ready for the next session")
                    .font(.geraldineSection)
                Text(keepAwake.isActive
                     ? "These defaults will apply after the current session ends."
                     : "New sessions begin with the duration and sleep contract below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(
            Module.keepAwake.tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
    }
}

private struct KeepAwakeSettingsControls: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker("Default Duration", selection: $keepAwake.defaultDuration) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Text(duration.label).tag(duration)
                }
            }
            Toggle("Allow Display Sleep", isOn: $keepAwake.allowDisplaySleep)
            Toggle("Deactivate On Battery", isOn: $keepAwake.deactivateOnBattery)
            Toggle("Pause While Screen Is Locked", isOn: $keepAwake.pauseWhenScreenLocked)
        }
        .tint(Theme.accent)
    }
}

struct AppearanceModePicker: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: Theme.Spacing.sm)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
            ForEach(AppShape.allCases) { shape in
                Button {
                    state.appShape = shape
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            Image(systemName: shape.systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Image(systemName: state.appShape == shape ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(state.appShape == shape ? Theme.accent : Color.secondary)
                        }
                        Text(shape.label)
                            .font(.geraldineLabel)
                            .foregroundStyle(.primary)
                        Text(shape.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.actionableCard(
                    padding: Theme.Spacing.sm,
                    tier: state.appShape == shape ? .tinted(Theme.accent) : .base,
                    cornerRadius: Theme.Radius.card
                ))
                .accessibilityAddTraits(state.appShape == shape ? .isSelected : [])
            }
        }
    }
}

struct AppShapePreview: View {
    let shape: AppShape

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous)
                .fill(Theme.canvas)
                .frame(height: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }

            HStack(spacing: 5) {
                Circle().fill(Color.secondary.opacity(0.28)).frame(width: 6, height: 6)
                Circle().fill(Color.secondary.opacity(0.18)).frame(width: 6, height: 6)
                Circle().fill(Color.secondary.opacity(0.12)).frame(width: 6, height: 6)
                Spacer()
                if shape.showsMenuBar {
                    GeraldineMark(size: 17)
                }
            }
            .padding(10)

            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.sidebar)
                    .frame(width: 76)
                VStack(spacing: 8) {
                    Capsule().fill(Theme.accent.opacity(0.20)).frame(width: 82, height: 8)
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.surfaceRaised)
                        .frame(height: 58)
                }
                .padding(12)
            }
            .padding(.top, 32)
            .padding(.horizontal, 20)
            .frame(height: 145)

            if shape.showsDock {
                HStack(spacing: 4) {
                    GeraldineMark(size: 20)
                    Circle().fill(Color.secondary.opacity(0.18)).frame(width: 16, height: 16)
                    Circle().fill(Color.secondary.opacity(0.12)).frame(width: 16, height: 16)
                }
                .padding(5)
                .background(Theme.surfaceFloating.opacity(0.92), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 7)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(shape.label)")
        .geraldineAnimation(.standard, value: shape)
    }
}

struct LaunchAtLoginControl: View {
    var onChange: ((Bool) -> Void)? = nil
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Toggle("Launch Geraldine At Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    if LaunchAtLogin.set(newValue) {
                        onChange?(newValue)
                    } else {
                        launchAtLogin = LaunchAtLogin.isEnabled
                        onChange?(launchAtLogin)
                    }
                }

            Text("Only controls whether Geraldine opens itself when you sign in. Use Login Items to manage other apps, helpers, and background startup items.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            onChange?(launchAtLogin)
        }
    }
}

private struct AIUsageConnectionRow: View {
    let provider: AICodingProvider
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var usage: AIUsageMonitor

    private var snapshot: AIUsageSnapshot { usage.snapshot(for: provider) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            CodingAssistantMark(provider: provider, size: 18)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(.rounded(13, .semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if snapshot.status == .ready, let remaining = snapshot.remainingPercent {
                Text("\(Int(remaining.rounded()))% left")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(UsageRemainingRing.tint(for: remaining, brand: provider.tint))
            }
            connectionButton
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch snapshot.status {
        case .disconnected:
            return "Show usage from the existing app or CLI session."
        case .needsSignIn:
            return provider.usageUnavailableHint
        case .loading:
            return "Reading remaining usage…"
        case .ready:
            if provider == .antigravity {
                return snapshot.displayWindows.map { "\($0.title): \(Int($0.remainingPercent.rounded()))% left" }
                    .joined(separator: " · ")
            }
            if provider == .claude || (provider == .codex && snapshot.displayWindows.count > 1) {
                let windows = snapshot.displayWindows.map {
                    "\($0.title): \(Int($0.remainingPercent.rounded()))% left"
                }.joined(separator: " · ")
                return [windows, snapshot.cachedSourceDescription].compactMap { $0 }.joined(separator: " · ")
            }
            if let source = snapshot.cachedSourceDescription { return source }
            if let window = snapshot.headline {
                return window.title
            }
            return "Connected"
        case .error(let message):
            return message
        }
    }

    @ViewBuilder private var connectionButton: some View {
        switch snapshot.status {
        case .disconnected:
            Button("Show Usage") { state.connectAIUsage(provider) }
                .buttonStyle(.soft(Theme.accent))
        case .needsSignIn:
            Button("Refresh") { usage.connect(provider) }
                .buttonStyle(.soft(Theme.warn))
        case .loading:
            ProgressView().controlSize(.small)
        case .ready, .error:
            Button("Hide Usage") { state.disconnectAIUsage(provider) }
                .buttonStyle(.quiet(Theme.accent, compact: true))
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let granted: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Theme.good : Theme.warn)
                .font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.rounded(13, .semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "Ready" : "Needs Setup")
                .font(.caption.weight(.semibold))
                .foregroundStyle(granted ? Theme.good : Theme.warn)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

private struct BuildInfoRows: View {
    private let build = BuildInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            buildRow("Revision", build.revisionLabel)
            buildRow("Built", build.builtAt)
            buildRow("Configuration", build.configuration)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func buildRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
