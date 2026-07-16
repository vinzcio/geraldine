import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("didOnboard") private var didOnboard = false

    var body: some View {
        HStack(spacing: 0) {
            // Swallow nil writes: clicking empty sidebar space deselects the
            // List, which would drop the highlight while a module stays open.
            Sidebar(selection: Binding(
                get: { state.selection },
                set: { newValue in
                    guard let newValue else { return }
                    state.selection = newValue
                }
            ))
            .frame(width: Theme.Layout.sidebarIdealWidth)
            .frame(maxHeight: .infinity)

            Divider()

            let module = state.selection ?? .dashboard
            ZStack {
                WindowBackground(module: module)
                DetailHost(module: module, direction: state.navigationDirection)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()
        }
        .geraldineSurfaceActive(state.mainWindowVisible)
        .background(WindowAccessor { window in state.bind(window: window) })
        .sheet(isPresented: Binding(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) {
            WelcomeView { didOnboard = true }
                .environmentObject(state.layout)
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Module?

    var body: some View {
        // Keep the List independently bounded by the app shell. Detail screens
        // can have large intrinsic sizes, spacers, or geometry readers without
        // participating in the sidebar's layout or scroll position.
        List(selection: $selection) {
            BrandHeader()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 14, trailing: 8))

            ForEach(Module.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(Module.modules(in: group)) { module in
                        SidebarRow(module: module, isSelected: selection == module)
                            .tag(module)
                            .listRowBackground(Color.clear)
                    }
                }
            }

            SidebarFooter()
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 12, leading: 6, bottom: 6, trailing: 6))
                .listRowBackground(Color.clear)
                .selectionDisabled()
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .frame(maxHeight: .infinity)
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            GeraldineMark(size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text("Geraldine").font(.geraldineSection)
                Text("Mac care, quietly alive")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    var module: Module
    var isSelected: Bool

    private var title: String {
        module == .battery && !monitor.hasBattery ? "Power" : module.title
    }

    private var systemImage: String {
        module == .battery && !monitor.hasBattery ? "powerplug" : module.systemImage
    }

    private var tint: Color {
        module == .keepAwake && keepAwake.isActive ? Theme.bad : module.tint
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ModuleGlyph(systemImage: systemImage, tint: tint, size: 28)
            Text(title)
                .font(.rounded(13, isSelected ? .semibold : .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(isHovered && !isSelected ? tint.opacity(0.065) : .clear)
        }
        .selectionPlate(isSelected: isSelected, tint: tint)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
    }
}

private struct SidebarFooter: View {
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var acknowledgement = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                AnimatedNumberText("\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free",
                                   value: max(0, monitor.diskTotal - monitor.diskUsed))
                    .font(.caption.weight(.medium))
                StatBar(fraction: monitor.diskFraction,
                        tint: Theme.Chart.status(for: monitor.diskFraction), height: 5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceBase)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Theme.status(for: monitor.diskFraction).opacity(acknowledgement ? 0.14 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) free of \(Fmt.size(monitor.diskTotal))")
        .onChange(of: monitor.diskFraction) { oldValue, newValue in
            guard oldValue < 0.85, newValue >= 0.85 else { return }
            acknowledgement = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion)) {
                    acknowledgement = false
                }
            }
        }
    }
}

/// Routes the selected module to its screen. Unbuilt modules show a
/// polished placeholder so the app feels complete while we fill them in.
struct DetailHost: View {
    var module: Module
    var direction: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedModule: Module
    @State private var transitionDirection = 1

    init(module: Module, direction: Int) {
        self.module = module
        self.direction = direction
        _displayedModule = State(initialValue: module)
    }

    var body: some View {
        ZStack {
            moduleContent(for: displayedModule)
                .id(displayedModule)
                .transition(GeraldineMotion.moduleTransition(
                    direction: transitionDirection,
                    reduceMotion: reduceMotion
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: module) { _, nextModule in
            beginTransition(to: nextModule, direction: direction)
        }
    }

    @ViewBuilder private func moduleContent(for module: Module) -> some View {
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
            case .loginItems:  LoginItemsView()
            case .privacy:     PrivacyView()
            case .maintenance: MaintenanceView()
            case .updater:     UpdaterView()
            case .permissions: PermissionsView()
            case .settings:    AppSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginTransition(to nextModule: Module, direction: Int) {
        guard nextModule != displayedModule else { return }
        transitionDirection = direction < 0 ? -1 : 1
        withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
            displayedModule = nextModule
        }
    }
}

/// Subtle two-tone brand wash behind every detail screen: violet falling in
/// from the top leading edge, blue from the trailing edge — quiet, but
/// unmistakably Geraldine instead of a flat window.
struct WindowBackground: View {
    let module: Module

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @EnvironmentObject private var keepAwake: KeepAwakeController

    private var auraTint: Color {
        module == .keepAwake && keepAwake.isActive ? Theme.bad : module.tint
    }

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(
                colors: [auraTint.opacity(0.12), .clear],
                center: UnitPoint(x: 0.82, y: 0.14),
                startRadius: 0,
                endRadius: 440
            )
            LinearGradient(
                colors: [Theme.accent.opacity(0.065), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            LinearGradient(
                colors: [Theme.accent2.opacity(0.045), .clear],
                startPoint: .topTrailing,
                endPoint: .center
            )
        }
        .animation(GeraldineMotion.animation(.emphasis,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: module)
        .animation(GeraldineMotion.animation(.emphasis,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: module == .keepAwake && keepAwake.isActive)
        .ignoresSafeArea()
    }
}
