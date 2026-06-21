import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 380)
    }
}

struct AppSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.rounded(28, .bold))
                    Text("Choose where Geraldine appears and how it starts.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Appearance")
                    AppearanceModePicker()
                }
                .card()

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Startup")
                    Toggle("Launch Geraldine at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            if !LaunchAtLogin.set(newValue) { launchAtLogin = LaunchAtLogin.isEnabled }
                        }
                }
                .card()
            }
            .padding(26)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Appearance") {
                AppearanceModePicker()
            }
            Section("Startup") {
                Toggle("Launch Geraldine at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if !LaunchAtLogin.set(newValue) { launchAtLogin = LaunchAtLogin.isEnabled }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceModePicker: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show Geraldine in", selection: $state.appShape) {
                ForEach(AppShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Text(state.appShape.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionsSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Full Disk Access") {
                HStack {
                    Label(state.hasFullDiskAccess ? "Granted" : "Not granted",
                          systemImage: state.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasFullDiskAccess ? Theme.good : Theme.warn)
                    Spacer()
                    Button("Recheck") { state.refreshFullDiskAccess() }
                    Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                }
                Text("Lets Geraldine scan caches, browser data, mail, and other protected locations. If Geraldine still shows this after granting access, quit and reopen it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshFullDiskAccess() }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.brandGradient).frame(width: 68, height: 68)
                Image(systemName: "sparkles").font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
            }
            Text("Geraldine").font(.rounded(22, .bold))
            Text("Version 0.1.0").font(.caption).foregroundStyle(.secondary)
            Text("Your Mac's tidy little helper.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
