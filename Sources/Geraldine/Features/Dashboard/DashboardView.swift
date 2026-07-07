import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @State private var showFreeRAM = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default:      return "Hello"
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                PermissionsBanner()

                LazyVGrid(columns: columns, spacing: 16) {
                    StatTile(icon: "cpu", title: "CPU",
                             value: Fmt.percent(monitor.cpuUsage),
                             valueAnimationValue: monitor.cpuUsage * 100,
                             caption: "In Use",
                             fraction: monitor.cpuUsage,
                             tint: Theme.status(for: monitor.cpuUsage))

                    StatTile(icon: "memorychip", title: "Memory",
                             value: Fmt.percent(monitor.memoryFraction),
                             valueAnimationValue: monitor.memoryFraction * 100,
                             caption: Fmt.size(monitor.memoryUsed),
                             captionAnimationValue: monitor.memoryUsed,
                             fraction: monitor.memoryFraction,
                             tint: Theme.status(for: monitor.memoryFraction))

                    StatTile(icon: "internaldrive", title: "Storage",
                             value: Fmt.percent(monitor.diskFraction),
                             valueAnimationValue: monitor.diskFraction * 100,
                             caption: "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free",
                             captionAnimationValue: max(0, monitor.diskTotal - monitor.diskUsed),
                             fraction: monitor.diskFraction,
                             tint: Theme.status(for: monitor.diskFraction))

                    batteryTile
                }

                networkCard
                quickActions
            }
            .padding(26)
        }
        .sheet(isPresented: $showFreeRAM) {
            FreeRAMView().environmentObject(monitor)
        }
        .onAppear { state.refreshFullDiskAccess() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.rounded(28, .bold))
                .foregroundStyle(Theme.brandGradient)
            Text("Here's how your \(state.hardware.displayName) is doing right now.")
                .font(.title3).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var batteryTile: some View {
        if let level = monitor.batteryLevel {
            StatTile(icon: monitor.batteryCharging ? "battery.100.bolt" : "battery.100",
                     title: "Battery",
                     value: Fmt.percent(level),
                     valueAnimationValue: level * 100,
                     caption: monitor.batteryCharging ? "Charging"
                        : (monitor.batteryHealth.map { "Health \(Fmt.percent($0))" } ?? "On Battery"),
                     captionAnimationValue: monitor.batteryHealth.map { $0 * 100 },
                     fraction: level,
                     tint: level < 0.2 ? Theme.bad : Theme.good)
        } else {
            StatTile(icon: "powerplug", title: "Power",
                     value: "AC", caption: "Plugged In",
                     fraction: 1, tint: Theme.good)
        }
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Network", systemImage: "wifi")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            NetworkTrafficChart(samples: monitor.networkHistory,
                                stats: networkStats,
                                chartHeight: 72)
        }
        .card()
    }

    private var networkStats: NetworkThroughputStats {
        NetworkThroughputStats(samples: monitor.networkHistory,
                               currentDown: monitor.netDown,
                               currentUp: monitor.netUp)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Quick Actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                freeRAMChip
                actionChip(.cleanup, "Run Cleanup")
                actionChip(.spaceLens, "Open Space Lens")
                actionChip(.uninstaller, "Uninstall An App")
            }
        }
    }

    private var freeRAMChip: some View {
        Button { showFreeRAM = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "memorychip").foregroundStyle(Theme.accent)
                Text("Free Up RAM").font(.rounded(14, .medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func actionChip(_ module: Module, _ title: String) -> some View {
        Button { state.selection = module } label: {
            HStack(spacing: 10) {
                Image(systemName: module.systemImage).foregroundStyle(module.tint)
                Text(title).font(.rounded(14, .medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
