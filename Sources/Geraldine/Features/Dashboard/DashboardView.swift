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
        ModulePage(
            module: .dashboard,
            title: greeting,
            subtitle: "Here's how your \(state.hardware.displayName) is doing right now.",
            headerStyle: .data,
            widthRole: .fluid
        ) {
            healthHero
                .geraldineEntrance(delay: 0)
            PermissionsBanner()

            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                StatTile(icon: "cpu", title: "CPU",
                         value: Fmt.percent(monitor.cpuUsage),
                         valueAnimationValue: monitor.cpuUsage * 100,
                         caption: "In Use",
                         fraction: monitor.cpuUsage,
                         tint: Theme.Chart.status(for: monitor.cpuUsage))

                StatTile(icon: "memorychip", title: "Memory",
                         value: Fmt.percent(monitor.memoryFraction),
                         valueAnimationValue: monitor.memoryFraction * 100,
                         caption: Fmt.size(monitor.memoryUsed),
                         captionAnimationValue: monitor.memoryUsed,
                         fraction: monitor.memoryFraction,
                         tint: Theme.Chart.status(for: monitor.memoryFraction))

                StatTile(icon: "internaldrive", title: "Storage",
                         value: Fmt.percent(monitor.diskFraction),
                         valueAnimationValue: monitor.diskFraction * 100,
                         caption: "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free",
                         captionAnimationValue: max(0, monitor.diskTotal - monitor.diskUsed),
                         fraction: monitor.diskFraction,
                         tint: Theme.Chart.status(for: monitor.diskFraction))

                batteryTile
            }
            .geraldineEntrance(delay: 0.07)

            networkCard
            quickActions
                .geraldineEntrance(delay: 0.14)
        }
        .sheet(isPresented: $showFreeRAM) {
            FreeRAMView().environmentObject(monitor)
        }
        .onAppear { state.refreshFullDiskAccess() }
    }

    @ViewBuilder private var healthHero: some View {
        let judgement = healthJudgement
        if let module = judgement.module {
            Button { state.selection = module } label: {
                healthHeroContent(judgement)
            }
            .buttonStyle(.actionableCard(
                padding: Theme.Spacing.lg,
                tier: .tinted(judgement.tint),
                cornerRadius: Theme.Radius.hero
            ))
        } else {
            healthHeroContent(judgement)
                .card(padding: Theme.Spacing.lg,
                      tier: .tinted(judgement.tint),
                      cornerRadius: Theme.Radius.hero)
        }
    }

    private func healthHeroContent(
        _ judgement: (title: String, detail: String, icon: String, tint: Color, module: Module?)
    ) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(judgement.tint.opacity(0.12))
                    .frame(width: 74, height: 74)
                Image(systemName: judgement.icon)
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(judgement.tint)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(judgement.title)
                    .font(.geraldineTitle)
                    .foregroundStyle(.primary)
                Text(judgement.detail)
                    .font(.geraldineBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.md)
            if judgement.module != nil {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(judgement.tint)
            }
        }
    }

    private var healthJudgement: (title: String, detail: String, icon: String, tint: Color, module: Module?) {
        if monitor.diskFraction > 0.90 {
            return ("Storage needs some breathing room",
                    "Your disk is over 90% full. Review Cleanup or Space Lens before macOS starts feeling cramped.",
                    "internaldrive.fill.badge.exclamationmark", Theme.warn, .cleanup)
        }
        if monitor.memoryFraction > 0.88 {
            return ("Memory pressure is building",
                    "Active memory use is high. Free inactive memory now or inspect the apps doing the most work.",
                    "memorychip.fill", Theme.warn, .activity)
        }
        if monitor.cpuUsage > 0.88 {
            return ("Your Mac is working hard",
                    "CPU use is elevated right now. Activity can show which processes are responsible.",
                    "waveform.path.ecg", Theme.warn, .activity)
        }
        return ("Everything looks comfortably in range",
                "Geraldine is watching the useful signals. Nothing needs your attention right now.",
                "checkmark.seal.fill", Theme.good, nil)
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
                     tint: Theme.Chart.batteryLevel(level))
        } else {
            StatTile(icon: "powerplug", title: "Power",
                     value: "AC", caption: "Plugged In",
                     fraction: 1, tint: Theme.Chart.green)
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
                                chartHeight: 72,
                                showsInspection: true)
        }
        .card(tier: .raised, cornerRadius: Theme.Radius.raised)
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
                ModuleGlyph(systemImage: "memorychip", tint: Theme.accent, size: 34)
                Text("Free Up RAM").font(.rounded(14, .medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.actionableCard(padding: 12, tier: .base))
    }

    private func actionChip(_ module: Module, _ title: String) -> some View {
        Button { state.selection = module } label: {
            HStack(spacing: 10) {
                ModuleGlyph(systemImage: module.systemImage, tint: module.tint, size: 34)
                Text(title).font(.rounded(14, .medium)).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.actionableCard(padding: 12, tier: .base))
    }
}
