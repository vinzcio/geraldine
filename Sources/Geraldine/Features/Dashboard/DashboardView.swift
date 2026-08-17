import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @State private var showFreeRAM = false
    @AppStorage("networkRateUnit") private var networkRateUnitRawValue = NetworkRateUnit.bytesPerSecond.rawValue

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

    /// Debug-only section toggles for CPU bisection (`--no-tiles` etc.).
    private func debugHidden(_ flag: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flag)
        #else
        return false
        #endif
    }

    var body: some View {
        ModulePage(
            module: .dashboard,
            title: greeting,
            subtitle: "Here's how your \(state.hardware.displayName) is doing right now.",
            headerStyle: .data,
            widthRole: .fluid,
            showsHeaderGlyph: false,
            trailing: { if !debugHidden("--no-badge") { machineBadge } }
        ) {
            if !debugHidden("--no-hero") {
                healthHero
                    .geraldineEntrance(delay: 0)
            }
            PermissionsBanner()

            if !debugHidden("--no-tiles") {
                statTiles
                    .geraldineEntrance(delay: 0.07)
            }

            if !debugHidden("--no-network") {
                networkCard
            }
            if !debugHidden("--no-actions") {
                quickActions
                    .geraldineEntrance(delay: 0.14)
            }
        }
        .sheet(isPresented: $showFreeRAM) {
            FreeRAMView().environmentObject(monitor)
        }
        .onAppear { state.refreshFullDiskAccess() }
    }

    // MARK: - Machine identity

    /// Quiet trailing capsule so the greeting's empty right side carries the
    /// machine's identity instead of dead space.
    private var machineBadge: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(state.hardware.displayName) · macOS \(osVersion)")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .adaptiveMaterialBackground(.ultraThin, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.separator, lineWidth: 1) }

            Text("Up \(SystemMonitor.uptimeString(monitor.uptime))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
        .accessibilityElement(children: .combine)
    }

    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0
            ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: - Health hero

    @ViewBuilder private var healthHero: some View {
        let judgement = healthJudgement
        if let module = judgement.module {
            Button { state.selection = module } label: {
                healthHeroContent(judgement)
            }
            .buttonStyle(.actionableCard(
                padding: Theme.Spacing.lg,
                tier: .hero(judgement.tint),
                cornerRadius: Theme.Radius.hero
            ))
        } else {
            healthHeroContent(judgement)
                .card(padding: Theme.Spacing.lg,
                      tier: .hero(judgement.tint),
                      cornerRadius: Theme.Radius.hero)
        }
    }

    private func healthHeroContent(_ judgement: HealthJudgement) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            heroGauge(judgement)
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
                    .frame(width: 32, height: 32)
                    .background(Theme.decorativeFill(judgement.tint), in: Circle())
            }
        }
    }

    /// The hero's focal point. All clear: the brand aperture inside a full
    /// brand-gradient ring. Flagged: a live gauge of the metric that needs
    /// attention, in exactly the color its stat ring shows below.
    @ViewBuilder private func heroGauge(_ judgement: HealthJudgement) -> some View {
        if let fraction = judgement.gaugeFraction {
            GaugeRing(value: fraction, lineWidth: 8, tint: judgement.gaugeTint) {
                AnimatedNumberText(Fmt.percent(fraction), value: fraction * 100)
                    .font(.rounded(19, .semibold))
                    .foregroundStyle(judgement.gaugeTint)
            }
            .frame(width: 84, height: 84)
        } else {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [Theme.accent2, Theme.accent, Theme.accent2],
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(270)
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                GeraldineMark(size: 44, showsPlate: false)
            }
            .frame(width: 84, height: 84)
        }
    }

    private struct HealthJudgement {
        let title: String
        let detail: String
        let tint: Color
        let module: Module?
        let gaugeFraction: Double?
        let gaugeTint: Color
    }

    /// One story per screen: the hero flags a metric exactly when its stat ring
    /// below turns red (`MetricPresentationPolicy.usageState == .bad`), so a red
    /// ring can never sit under a green "all clear" banner.
    private var healthJudgement: HealthJudgement {
        if MetricPresentationPolicy.usageState(monitor.diskFraction) == .bad {
            return HealthJudgement(
                title: "Storage needs some breathing room",
                detail: "Your disk is over 85% full. Review Cleanup or Large & Old Files before macOS starts feeling cramped.",
                tint: MetricPresentationPolicy.usageSemanticColor(monitor.diskFraction),
                module: .cleanup,
                gaugeFraction: monitor.diskFraction,
                gaugeTint: MetricPresentationPolicy.usageReadoutColor(monitor.diskFraction)
            )
        }
        if MetricPresentationPolicy.usageState(monitor.memoryFraction) == .bad {
            return HealthJudgement(
                title: "Memory use is elevated",
                detail: "Active memory use is high. Free inactive memory now or inspect the apps doing the most work.",
                tint: MetricPresentationPolicy.usageSemanticColor(monitor.memoryFraction),
                module: .activity,
                gaugeFraction: monitor.memoryFraction,
                gaugeTint: MetricPresentationPolicy.usageReadoutColor(monitor.memoryFraction)
            )
        }
        if MetricPresentationPolicy.usageState(monitor.cpuUsage) == .bad {
            return HealthJudgement(
                title: "Your Mac is working hard",
                detail: "CPU use is elevated right now. Activity can show which processes are responsible.",
                tint: MetricPresentationPolicy.usageSemanticColor(monitor.cpuUsage),
                module: .activity,
                gaugeFraction: monitor.cpuUsage,
                gaugeTint: MetricPresentationPolicy.usageReadoutColor(monitor.cpuUsage)
            )
        }
        return HealthJudgement(
            title: "Everything looks comfortably in range",
            detail: "Geraldine is watching the useful signals. Nothing needs your attention right now.",
            tint: Theme.accent,
            module: nil,
            gaugeFraction: nil,
            gaugeTint: Theme.accent
        )
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
            StatTile(icon: "cpu", title: "CPU",
                     value: Fmt.percent(monitor.cpuUsage),
                     valueAnimationValue: monitor.cpuUsage * 100,
                     caption: "In Use",
                     fraction: monitor.cpuUsage,
                     tint: Theme.Chart.status(for: monitor.cpuUsage),
                     valueTint: MetricPresentationPolicy.usageReadoutColor(monitor.cpuUsage))

            StatTile(icon: "memorychip", title: "Memory",
                     value: Fmt.percent(monitor.memoryFraction),
                     valueAnimationValue: monitor.memoryFraction * 100,
                     caption: Fmt.size(monitor.memoryUsed),
                     captionAnimationValue: monitor.memoryUsed,
                     fraction: monitor.memoryFraction,
                     tint: Theme.Chart.status(for: monitor.memoryFraction),
                     valueTint: MetricPresentationPolicy.usageReadoutColor(monitor.memoryFraction))

            StatTile(icon: "internaldrive", title: "Storage",
                     value: Fmt.percent(monitor.diskFraction),
                     valueAnimationValue: monitor.diskFraction * 100,
                     caption: "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) Free",
                     captionAnimationValue: max(0, monitor.diskTotal - monitor.diskUsed),
                     fraction: monitor.diskFraction,
                     tint: Theme.Chart.status(for: monitor.diskFraction),
                     valueTint: MetricPresentationPolicy.usageReadoutColor(monitor.diskFraction))

            batteryTile
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
                     tint: Theme.Chart.batteryLevel(level),
                     valueTint: MetricPresentationPolicy.batteryReadoutColor(level: level))
        } else if monitor.hasBattery {
            StatTile(icon: "questionmark.circle", title: "Battery",
                     value: "—", caption: "Level Unavailable",
                     fraction: 0, tint: .secondary, valueTint: .secondary)
        } else {
            acPowerTile
        }
    }

    /// Desktop Macs get an honest steady-state tile instead of a gauge
    /// pretending 100% of something is being consumed.
    private var acPowerTile: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Power", systemImage: "powerplug")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: Theme.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(Theme.decorativeFill(Theme.green, strength: .standard))
                    Image(systemName: "powerplug.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.green)
                }
                .frame(width: 56, height: 56)
                Text("AC Power")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(.primary)
                Text("Plugged In")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 104)
        }
        .frame(maxWidth: .infinity)
        .card(tier: .quiet)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Power: plugged in to AC")
    }

    // MARK: - Network

    private var networkCard: some View {
        // Computed once per render: each NetworkThroughputStats init maps the
        // full sample history, and this card reads it in half a dozen places.
        let stats = networkStats
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Network", systemImage: state.network.online ? "wifi" : "wifi.slash")
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.network.online {
                    currentRateReadout(stats)
                }
            }

            if state.network.online {
                NetworkTimelineGraph(samples: monitor.networkHistory,
                                     window: SystemMonitor.liveHistoryWindow,
                                     now: Date(),
                                     downTint: Theme.Chart.blue,
                                     upTint: Theme.Chart.mint,
                                     downReference: stats.averageDown,
                                     upReference: stats.averageUp,
                                     showsInspection: true,
                                     rateUnit: networkRateUnit,
                                     maximumPointCount: 160)
                    .frame(height: 76)
                    .accessibilityLabel("Network throughput history")

                if stats.hasSamples {
                    historyFootnote(stats)
                }
            } else {
                Label("Network Offline", systemImage: "wifi.slash")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76)
            }
        }
        .card(tier: .quiet, cornerRadius: Theme.Radius.raised)
    }

    /// The live rates are the headline; history stats stay a quiet footnote.
    private func currentRateReadout(_ stats: NetworkThroughputStats) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            rateReadout(icon: "arrow.down", value: stats.currentDown, tint: Theme.Chart.blue,
                        label: "Download")
            rateReadout(icon: "arrow.up", value: stats.currentUp, tint: Theme.Chart.mint,
                        label: "Upload")
        }
    }

    private func rateReadout(icon: String, value: Double, tint: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.rounded(11, .bold))
                .foregroundStyle(tint)
            AnimatedNumberText(Fmt.compactRate(value, unit: networkRateUnit),
                               value: networkRateUnit.displayValue(for: value))
                .font(.rounded(16, .semibold))
                .foregroundStyle(tint)
        }
        // Fixed-width slot: rates change every second, and without this the
        // readout's width jiggle re-laid-out the whole card and page each tick.
        .frame(minWidth: 100, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(Fmt.rate(value, unit: networkRateUnit))")
    }

    private func historyFootnote(_ stats: NetworkThroughputStats) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            footnoteCluster("Avg 5m", down: stats.averageDown, up: stats.averageUp)
            footnoteCluster("Peak 5m", down: stats.peakDown, up: stats.peakUp)
            Spacer()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(footnoteAccessibility(stats))
    }

    private func footnoteCluster(_ label: String, down: Double, up: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.rounded(9.5, .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Text("↓ \(Fmt.compactRate(down, unit: networkRateUnit))  ↑ \(Fmt.compactRate(up, unit: networkRateUnit))")
                .font(.rounded(11, .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func footnoteAccessibility(_ stats: NetworkThroughputStats) -> String {
        "Average download \(Fmt.rate(stats.averageDown, unit: networkRateUnit)), " +
        "average upload \(Fmt.rate(stats.averageUp, unit: networkRateUnit)), " +
        "peak download \(Fmt.rate(stats.peakDown, unit: networkRateUnit)), " +
        "peak upload \(Fmt.rate(stats.peakUp, unit: networkRateUnit))"
    }

    private var networkStats: NetworkThroughputStats {
        NetworkThroughputStats(samples: monitor.networkHistory,
                               currentDown: monitor.netDown,
                               currentUp: monitor.netUp)
    }

    private var networkRateUnit: NetworkRateUnit {
        NetworkRateUnit(rawValue: networkRateUnitRawValue) ?? .bytesPerSecond
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Quick Actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                actionChip(icon: "memorychip", tint: Theme.accent,
                           title: "Free Up RAM",
                           caption: "\(Fmt.size(monitor.memoryUsed)) in use",
                           captionValue: monitor.memoryUsed) {
                    showFreeRAM = true
                }
                actionChip(icon: Module.cleanup.systemImage, tint: Module.cleanup.tint,
                           title: "Run Cleanup",
                           caption: "Caches, logs & junk") {
                    state.selection = .cleanup
                }
                actionChip(icon: Module.largeFiles.systemImage, tint: Module.largeFiles.tint,
                           title: "Find Large Files",
                           caption: "\(Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))) free now",
                           captionValue: max(0, monitor.diskTotal - monitor.diskUsed)) {
                    state.selection = .largeFiles
                }
                actionChip(icon: Module.uninstaller.systemImage, tint: Module.uninstaller.tint,
                           title: "Uninstall An App",
                           caption: "Leftovers included") {
                    state.selection = .uninstaller
                }
            }
        }
    }

    private func actionChip(icon: String, tint: Color, title: String,
                            caption: String, captionValue: Double? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ModuleGlyph(systemImage: icon, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.rounded(13.5, .medium))
                        .foregroundStyle(.primary)
                    if let captionValue {
                        AnimatedNumberText(caption, value: captionValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.actionableCard(padding: 12, tier: .quiet))
    }
}
