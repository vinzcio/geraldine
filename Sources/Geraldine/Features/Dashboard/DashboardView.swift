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

                if !state.hasFullDiskAccess {
                    FDABanner { state.refreshFullDiskAccess() }
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    StatTile(icon: "cpu", title: "CPU",
                             value: Fmt.percent(monitor.cpuUsage),
                             valueAnimationValue: monitor.cpuUsage * 100,
                             caption: "in use",
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
                             caption: "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) free",
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
            Text(greeting).font(.rounded(28, .bold))
            Text("Here's how your Mac is doing right now.")
                .font(.title3).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var batteryTile: some View {
        if let level = monitor.batteryLevel {
            StatTile(icon: monitor.batteryCharging ? "battery.100.bolt" : "battery.100",
                     title: "Battery",
                     value: Fmt.percent(level),
                     valueAnimationValue: level * 100,
                     caption: monitor.batteryCharging ? "charging"
                        : (monitor.batteryHealth.map { "health \(Fmt.percent($0))" } ?? "on battery"),
                     captionAnimationValue: monitor.batteryHealth.map { $0 * 100 },
                     fraction: level,
                     tint: level < 0.2 ? Theme.bad : Theme.good)
        } else {
            StatTile(icon: "powerplug", title: "Power",
                     value: "AC", caption: "plugged in",
                     fraction: 1, tint: Theme.good)
        }
    }

    private var networkCard: some View {
        HStack(spacing: 28) {
            netStat(icon: "arrow.down", label: "Download", value: monitor.netDown, tint: Theme.accent2)
            Divider().frame(height: 34)
            netStat(icon: "arrow.up", label: "Upload", value: monitor.netUp, tint: Theme.accent)
            Spacer()
            Image(systemName: "wifi").font(.title2).foregroundStyle(.secondary)
        }
        .card()
    }

    private func netStat(icon: String, label: String, value: Double, tint: Color) -> some View {
        let animationValue = value.isFinite ? max(0, value) : 0

        return HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                AnimatedNumberText(Fmt.rate(value), value: animationValue)
                    .font(.rounded(15, .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: 82, alignment: .leading)
            }
        }
        .layoutPriority(1)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Quick actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                freeRAMChip
                actionChip(.cleanup, "Run Cleanup")
                actionChip(.spaceLens, "Open Space Lens")
                actionChip(.uninstaller, "Uninstall an app")
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
    }
}
