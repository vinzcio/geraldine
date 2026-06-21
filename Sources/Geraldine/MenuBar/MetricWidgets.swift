import SwiftUI

// MARK: - Grid

/// Lays out the metric widgets like iOS Home Screen widgets: two small tiles per row,
/// a large tile spanning the full width, in the user's chosen order.
struct WidgetGrid: View {
    @EnvironmentObject var layout: WidgetLayoutStore

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(packed.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.kind) { item in
                        MetricWidget(item: item).frame(maxWidth: .infinity)
                    }
                    // Keep a lone small tile at half width instead of stretching.
                    if row.count == 1, row[0].size == .small {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: layout.items)
    }

    /// Flow the ordered items into rows: a large item takes its own row; smalls pair up.
    private var packed: [[WidgetItem]] {
        var rows: [[WidgetItem]] = []
        var i = 0
        let items = layout.items
        while i < items.count {
            if items[i].size == .large {
                rows.append([items[i]]); i += 1
            } else if i + 1 < items.count, items[i + 1].size == .small {
                rows.append([items[i], items[i + 1]]); i += 2
            } else {
                rows.append([items[i]]); i += 1
            }
        }
        return rows
    }
}

// MARK: - Widget

/// One resizable, draggable metric tile. Small = compact readout; large = adds a chart.
struct MetricWidget: View {
    let item: WidgetItem
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var network: NetworkMonitor
    @EnvironmentObject var layout: WidgetLayoutStore
    @State private var freeing = false

    private var kind: MetricKind { item.kind }
    private var isSmall: Bool { item.size == .small }
    private var networkRateFontSize: CGFloat { isSmall ? 11 : 12 }
    private var networkRateIconWidth: CGFloat { isSmall ? 8 : 10 }
    private var networkRateSpacing: CGFloat { isSmall ? 2 : 5 }
    private var networkRateTextWidth: CGFloat { isSmall ? 45 : 56 }

    var body: some View {
        Group {
            if kind == .network { networkBody } else { standardBody }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: isSmall ? 100 : nil, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, let dragged = MetricKind(rawValue: raw), dragged != kind else { return false }
            withAnimation(.snappy(duration: 0.28)) { layout.move(dragged, before: kind) }
            return true
        }
    }

    // MARK: Shared chrome

    private var controls: some View {
        HStack(spacing: 6) {
            // Drag handle for reordering.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .draggable(kind.rawValue) {
                    Label(kind.title, systemImage: kind.icon)
                        .font(.caption).padding(6)
                        .background(.ultraThinMaterial, in: Capsule())
                }

            // Tap to toggle small ↔ large.
            Button {
                withAnimation(.snappy(duration: 0.28)) { layout.toggleSize(kind) }
            } label: {
                Image(systemName: isSmall ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help(isSmall ? "Expand widget" : "Shrink widget")
        }
    }

    private func headerRow(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 5) {
            Image(systemName: kind.icon).font(.caption).foregroundStyle(tint)
            Text(kind.title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
            controls
        }
    }

    private func actionButton(_ title: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if busy { ProgressView().controlSize(.mini) }
                Text(busy ? "Working…" : title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain).disabled(busy)
    }

    @ViewBuilder private func caption(_ text: String, animationValue: Double? = nil) -> some View {
        if let animationValue {
            AnimatedNumberText(text, value: animationValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Standard metrics (temperature / cpu / memory / storage / battery)

    @ViewBuilder private var standardBody: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            headerRow {
                if !isSmall {
                    animatedValueText(size: 15, weight: .semibold)
                        .foregroundStyle(kind == .temperature ? tint : .primary)
                }
            }
            if isSmall { standardSmall } else { standardLarge }
        }
    }

    @ViewBuilder private var standardSmall: some View {
        animatedValueText(size: 16, weight: .semibold)
            .foregroundStyle(kind == .temperature ? tint : .primary)
        if kind != .temperature {
            StatBar(fraction: fraction, tint: tint, height: 5)
        }
        Spacer(minLength: 0)
        smallFooter
    }

    @ViewBuilder private var smallFooter: some View {
        switch kind {
        case .temperature: caption(monitor.thermal.available ? "CPU die" : "Unavailable")
        case .cpu:         actionButton("Details") { state.open(.activity) }
        case .memory:      actionButton("Free Up", busy: freeing) { freeMemory() }
        case .storage:     actionButton("Clean Up") { state.open(.cleanup) }
        case .battery:     caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
        case .network:     EmptyView()
        }
    }

    @ViewBuilder private var standardLarge: some View {
        chart.frame(height: 66)
        largeFooter
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .temperature:
            ScaledSparkGraph(values: monitor.thermalHistory, tint: tint,
                             gradientColors: Thermal.scaleColors,
                             domain: Thermal.chartDomain,
                             valueColor: Thermal.color)
        case .cpu:
            ScaledSparkGraph(values: monitor.cpuHistory, tint: tint)
        case .memory:
            ScaledSparkGraph(values: monitor.memHistory, tint: tint)
        case .battery:
            SparkGraph(values: monitor.batteryHistory, tint: tint)
        case .storage:
            SparkGraph(values: monitor.diskHistory, tint: tint)
        case .network:
            EmptyView()
        }
    }

    @ViewBuilder private var largeFooter: some View {
        switch kind {
        case .temperature:
            let low = monitor.thermalHistory.min()
            let high = monitor.thermalHistory.max()
            HStack {
                caption("Low \(tempString(low))", animationValue: low)
                Spacer()
                caption("High \(tempString(high))", animationValue: high)
            }
        case .cpu:
            HStack { caption("Live usage"); Spacer(); actionButton("Activity") { state.open(.activity) } }
        case .memory:
            HStack {
                caption("\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal))",
                        animationValue: monitor.memoryUsed)
                Spacer()
                actionButton("Free Up", busy: freeing) { freeMemory() }
            }
        case .storage:
            HStack {
                caption("\(Fmt.size(monitor.diskUsed)) of \(Fmt.size(monitor.diskTotal))",
                        animationValue: monitor.diskUsed)
                Spacer()
                actionButton("Clean Up") { state.open(.cleanup) }
            }
        case .battery:
            HStack { caption(batteryCaption, animationValue: batteryCaptionAnimationValue); Spacer() }
        case .network:
            EmptyView()
        }
    }

    // MARK: Network widget

    @ViewBuilder private var networkBody: some View {
        if isSmall {
            VStack(alignment: .leading, spacing: 6) {
                networkHeader
                Text(network.displayName).font(.rounded(14, .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    rate("arrow.down", monitor.netDown, Theme.accent2)
                    rate("arrow.up", monitor.netUp, Theme.accent)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                networkHeader
                HStack(alignment: .firstTextBaseline) {
                    Text(network.displayName).font(.rounded(16, .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    securityPill
                }
                DualLineGraph(primary: monitor.netDownHistory, secondary: monitor.netUpHistory,
                              primaryTint: Theme.accent2, secondaryTint: Theme.accent)
                    .frame(height: 66)
                HStack(spacing: 12) {
                    rate("arrow.down", monitor.netDown, Theme.accent2)
                    rate("arrow.up", monitor.netUp, Theme.accent)
                    Spacer()
                    speedControl
                }
                if let link = network.linkRateMbps {
                    caption("\(Int(link.rounded())) Mbps link", animationValue: link)
                }
            }
        }
    }

    private var networkHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: network.connection.icon).font(.caption)
                .foregroundStyle(network.online ? Theme.accent2 : Theme.warn)
            Text("Network").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            signalGlyph
            controls
        }
    }

    @ViewBuilder private var signalGlyph: some View {
        if network.connection == .wifi, let f = network.signalFraction {
            Image(systemName: "wifi", variableValue: f)
                .font(.caption).foregroundStyle(Theme.status(for: 1 - f))
                .help("Signal \(Int((f * 100).rounded()))%")
        } else if network.connection == .offline {
            Image(systemName: "wifi.slash").font(.caption).foregroundStyle(Theme.warn)
        }
    }

    @ViewBuilder private var securityPill: some View {
        if network.connection == .wifi {
            let strong = network.security.strong
            HStack(spacing: 3) {
                Image(systemName: strong ? "lock.fill" : "lock.open.fill")
                Text(network.security.label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(strong ? Theme.good : Theme.warn)
        }
    }

    private func rate(_ icon: String, _ value: Double, _ tint: Color) -> some View {
        let animationValue = value.isFinite ? max(0, value) : 0

        return HStack(spacing: networkRateSpacing) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: networkRateIconWidth)
            AnimatedNumberText(Fmt.compactRate(value), value: animationValue)
                .font(.system(size: networkRateFontSize, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .frame(width: networkRateTextWidth, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
        .help(Fmt.rate(value))
    }

    @ViewBuilder private var speedControl: some View {
        Group {
            switch network.speedTest {
            case .idle:
                Button { network.runSpeedTest() } label: {
                    Label("Test Speed", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            case .running(let phase):
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(phase == .download ? "Testing ↓…" : "Testing ↑…")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            case .done(let down, let up):
                Button { network.runSpeedTest() } label: {
                    HStack(spacing: 6) {
                        AnimatedNumberText("↓ \(speedString(down))", value: down).foregroundStyle(Theme.accent2)
                        AnimatedNumberText("↑ \(speedString(up))", value: up).foregroundStyle(Theme.accent)
                        Text("Mbps").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }.buttonStyle(.plain).help("Tap to test again")
            case .failed:
                Button { network.runSpeedTest() } label: {
                    Label("Retry", systemImage: "exclamationmark.arrow.circlepath")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Per-metric data

    private var tint: Color {
        switch kind {
        case .temperature: return Thermal.color(monitor.thermal.cpu)
        case .cpu:         return Theme.status(for: monitor.cpuUsage)
        case .memory:      return Theme.status(for: monitor.memoryFraction)
        case .storage:     return Theme.status(for: monitor.diskFraction)
        case .battery:     return (monitor.batteryLevel ?? 1) < 0.2 ? Theme.bad : Theme.good
        case .network:     return network.online ? Theme.accent2 : Theme.warn
        }
    }

    private var fraction: Double {
        switch kind {
        case .cpu:     return monitor.cpuUsage
        case .memory:  return monitor.memoryFraction
        case .storage: return monitor.diskFraction
        case .battery: return monitor.batteryLevel ?? 1
        default:       return 0
        }
    }

    private var valueText: String {
        switch kind {
        case .temperature: return monitor.thermal.available ? "\(Int(monitor.thermal.cpu.rounded()))°C" : "—"
        case .cpu:         return Fmt.percent(monitor.cpuUsage)
        case .memory:      return Fmt.percent(monitor.memoryFraction)
        case .storage:     return Fmt.size(max(0, monitor.diskTotal - monitor.diskUsed))
        case .battery:     return monitor.batteryLevel.map(Fmt.percent) ?? "AC"
        case .network:     return network.displayName
        }
    }

    @ViewBuilder private func animatedValueText(size: CGFloat, weight: Font.Weight) -> some View {
        if let animationValue = valueAnimationValue {
            AnimatedNumberText(valueText, value: animationValue)
                .font(.rounded(size, weight))
                .monospacedDigit()
        } else {
            Text(valueText)
                .font(.rounded(size, weight))
                .monospacedDigit()
        }
    }

    private var valueAnimationValue: Double? {
        switch kind {
        case .temperature:
            return monitor.thermal.available ? monitor.thermal.cpu : nil
        case .cpu:
            return monitor.cpuUsage * 100
        case .memory:
            return monitor.memoryFraction * 100
        case .storage:
            return max(0, monitor.diskTotal - monitor.diskUsed)
        case .battery:
            return monitor.batteryLevel.map { $0 * 100 }
        case .network:
            return nil
        }
    }

    private var batteryCaption: String {
        if monitor.batteryCharging { return "Charging" }
        if let h = monitor.batteryHealth { return "Health \(Fmt.percent(h))" }
        return monitor.batteryLevel == nil ? "On AC power" : "On battery"
    }

    private var batteryCaptionAnimationValue: Double? {
        guard !monitor.batteryCharging else { return nil }
        return monitor.batteryHealth.map { $0 * 100 }
    }

    private func tempString(_ value: Double?) -> String {
        guard let value, monitor.thermal.available else { return "—" }
        return "\(Int(value.rounded()))°"
    }

    private func speedString(_ mbps: Double) -> String {
        mbps >= 100 ? "\(Int(mbps.rounded()))" : String(format: "%.1f", mbps)
    }

    private func freeMemory() {
        guard !freeing else { return }
        freeing = true
        Task {
            _ = await MemoryActions.freeUpRAM()
            monitor.refresh()
            freeing = false
        }
    }
}
