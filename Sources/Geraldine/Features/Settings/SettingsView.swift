import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            KeepAwakeSettings()
                .tabItem { Label("Keep Awake", systemImage: Module.keepAwake.systemImage) }
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
    }
}

struct AppSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.rounded(28, .bold))
                    Text("Choose where Geraldine appears and how it starts.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                SettingsSectionCard {
                    SectionHeader("Appearance")
                    AppearanceModePicker()
                }

                SettingsSectionCard {
                    SectionHeader("Keep Awake")
                    KeepAwakeSettingsControls()
                }

                SettingsSectionCard {
                    SectionHeader("Geraldine Startup",
                                  subtitle: "This controls Geraldine itself, not every app that starts with macOS.")
                    LaunchAtLoginControl()
                }

                SettingsSectionCard {
                    SectionHeader("Build", subtitle: "The installed app's source revision.")
                    BuildInfoRows()
                }
            }
            .padding(26)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .card()
    }
}

private struct KeepAwakeSettings: View {
    var body: some View {
        Form {
            Section("Keep Awake") {
                KeepAwakeSettingsControls()
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeepAwakeSettingsControls: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController

    var body: some View {
        Group {
            Picker("Default Duration", selection: $keepAwake.defaultDuration) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Text(duration.label).tag(duration)
                }
            }
            Toggle("Allow Display Sleep", isOn: $keepAwake.allowDisplaySleep)
            Toggle("Deactivate On Battery", isOn: $keepAwake.deactivateOnBattery)
            Toggle("Pause While Screen Is Locked", isOn: $keepAwake.pauseWhenScreenLocked)
        }
    }
}

private struct GeneralSettings: View {
    var body: some View {
        Form {
            Section("Appearance") {
                AppearanceModePicker()
            }
            Section("Geraldine Startup") {
                LaunchAtLoginControl()
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceModePicker: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show Geraldine In", selection: $state.appShape) {
                ForEach(AppShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Text(state.appShape.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LaunchAtLoginControl: View {
    var onChange: ((Bool) -> Void)? = nil
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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

private struct PermissionsSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Permissions") {
                statusRow("Full Disk Access", granted: state.hasFullDiskAccess)
                statusRow("Accessibility", granted: state.hasAccessibility)
                Button("Open Permissions…") { state.open(.permissions) }
            }
            Text("Review, grant, and manage all of Geraldine's permissions in one place.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { state.refreshPermissions() }
    }

    private func statusRow(_ title: String, granted: Bool) -> some View {
        LabeledContent(title) {
            Label(granted ? "Granted" : "Not Granted",
                  systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Theme.good : Theme.warn)
                .labelStyle(.titleAndIcon)
        }
    }
}

private struct AboutSettings: View {
    private let build = BuildInfo.current

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.brandGradient).frame(width: 68, height: 68)
                Image(systemName: "sparkles").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
            }
            Text("Geraldine").font(.rounded(22, .bold))
            Text(build.versionLabel).font(.caption).foregroundStyle(.secondary)
            Text("Your Mac's tidy little helper.").font(.callout).foregroundStyle(.secondary)
            BuildInfoRows()
                .padding(.top, 8)
                .frame(width: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BuildInfoRows: View {
    private let build = BuildInfo.current

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            buildRow("Revision", build.revisionLabel)
            buildRow("Built", build.builtAt)
            buildRow("Configuration", build.configuration)
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func buildRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
