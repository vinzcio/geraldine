import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $state.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            DetailHost(module: state.selection ?? .dashboard)
        }
        .background(WindowAccessor { window in state.bind(window: window) })
        .sheet(isPresented: Binding(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
            WelcomeView { didOnboard = true }
                .environmentObject(state.layout)
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Module?
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        List(selection: $selection) {
            BrandHeader()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 14, trailing: 8))

            ForEach(Module.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(Module.modules(in: group)) { module in
                        SidebarRow(module: module)
                            .tag(module)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Geraldine").font(.rounded(16, .bold))
                Text("Mac Care").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var monitor: SystemMonitor
    var module: Module

    private var title: String {
        module == .battery && !monitor.hasBattery ? "Power" : module.title
    }

    private var systemImage: String {
        module == .battery && !monitor.hasBattery ? "powerplug" : module.systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(module.tint)
        }
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var monitor: SystemMonitor
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                AnimatedNumberText("\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free",
                                   value: max(0, monitor.diskTotal - monitor.diskUsed))
                    .font(.caption.weight(.medium))
                StatBar(fraction: monitor.diskFraction,
                        tint: Theme.status(for: monitor.diskFraction), height: 5)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

/// Routes the selected module to its screen. Unbuilt modules show a
/// polished placeholder so the app feels complete while we fill them in.
struct DetailHost: View {
    var module: Module

    var body: some View {
        Group {
            switch module {
            case .dashboard:   DashboardView()
            case .smartCare:   SmartCareView()
            case .activity:    ActivityView()
            case .storage:     StorageView()
            case .battery:     BatteryView()
            case .keepAwake:   KeepAwakeView()
            case .calendar:    CalendarSettingsView()
            case .powerTools:  PowerToolsView()
            case .cleanup:     CleanupView()
            case .uninstaller: UninstallerView()
            case .largeFiles:  LargeFilesView()
            case .spaceLens:   SpaceLensView()
            case .loginItems:  LoginItemsView()
            case .privacy:     PrivacyView()
            case .maintenance: MaintenanceView()
            case .updater:     UpdaterView()
            case .permissions: PermissionsView()
            case .settings:    AppSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowBackground())
    }
}

/// Subtle two-tone brand wash behind every detail screen: violet falling in
/// from the top leading edge, blue from the trailing edge — quiet, but
/// unmistakably Geraldine instead of a flat window.
struct WindowBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.07), .clear],
                           startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [Theme.accent2.opacity(0.05), .clear],
                           startPoint: .topTrailing, endPoint: .center)
        }
        .ignoresSafeArea()
    }
}
