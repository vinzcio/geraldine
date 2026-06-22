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
                        widget(for: item).frame(maxWidth: .infinity)
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

    @ViewBuilder private func widget(for item: WidgetItem) -> some View {
        switch item.kind {
        case .metric(let metric): MetricWidget(kind: metric, size: item.size)
        case .keepAwake:          KeepAwakeWidget(size: item.size)
        }
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

// MARK: - Shared widget chrome

/// Drag-to-reorder handle + size toggle, shared by every widget tile so Keep Awake
/// behaves exactly like the metric widgets.
struct WidgetControls: View {
    @EnvironmentObject var layout: WidgetLayoutStore
    let kind: WidgetKind
    let size: WidgetSize

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .help("Drag to reorder")
                .draggable(kind.id) { dragPreview }

            Button {
                withAnimation(.snappy(duration: 0.28)) { layout.toggleSize(kind) }
            } label: {
                Image(systemName: size == .small ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help(size == .small ? "Expand widget" : "Shrink widget")
        }
    }

    @ViewBuilder private var dragPreview: some View {
        HStack(spacing: 5) {
            switch kind {
            case .metric(let metric): Image(systemName: metric.icon)
            case .keepAwake:          EyeView(isActive: false, size: 16)
            }
            Text(kind.title)
        }
        .font(.caption).padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Accept a dropped widget id and reorder it before `target`.
private struct WidgetDropTarget: ViewModifier {
    @EnvironmentObject var layout: WidgetLayoutStore
    let target: WidgetKind

    func body(content: Content) -> some View {
        content.dropDestination(for: String.self) { dropped, _ in
            guard let raw = dropped.first, let dragged = WidgetKind(id: raw), dragged != target else { return false }
            withAnimation(.snappy(duration: 0.28)) { layout.move(dragged, before: target) }
            return true
        }
    }
}

extension View {
    func widgetDropTarget(_ target: WidgetKind) -> some View {
        modifier(WidgetDropTarget(target: target))
    }
}

// MARK: - Widget

/// One resizable, draggable metric tile. Small = compact readout; large = adds a chart.
struct MetricWidget: View {
    let kind: MetricKind
    let size: WidgetSize
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject var network: NetworkMonitor
    @State private var freeing = false

    private var isSmall: Bool { size == .small }
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
        .widgetDropTarget(.metric(kind))
    }

    // MARK: Shared chrome

    private var controls: some View { WidgetControls(kind: .metric(kind), size: size) }

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
            HStack {
                caption(batteryCaption, animationValue: batteryCaptionAnimationValue)
                Spacer()
                if let health = monitor.batteryHealth {
                    caption("Health \(Fmt.percent(health))", animationValue: health * 100)
                }
            }
        case .network:
            EmptyView()
        }
    }

    // MARK: Network widget

    @ViewBuilder private var networkBody: some View {
        if isSmall {
            VStack(alignment: .leading, spacing: 6) {
                networkHeader
                networkName(size: 14)
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
                    networkName(size: 16)
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
            Text(network.connection.label).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            signalGlyph
            controls
        }
    }

    /// The headline name: the Wi-Fi SSID when macOS will give it to us, otherwise a
    /// state that isn't a redundant "Wi-Fi" — including a tap to reveal a hidden name.
    @ViewBuilder private func networkName(size: CGFloat) -> some View {
        if let ssid = network.ssid, !ssid.isEmpty {
            Text(ssid)
                .font(.rounded(size, .semibold))
                .lineLimit(1).truncationMode(.middle)
        } else if network.connection == .wifi, !network.canShowName {
            Button { network.requestNameAccess() } label: {
                Text("Show Name")
                    .font(.rounded(size, .semibold))
                    .foregroundStyle(Theme.accent2)
            }
            .buttonStyle(.plain)
            .help("Allow Location so macOS reveals the Wi-Fi network name")
        } else if !network.online {
            Text("Not Connected")
                .font(.rounded(size, .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text(network.connection.label)
                .font(.rounded(size, .semibold))
                .lineLimit(1)
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
        // Desktop / no battery.
        guard monitor.batteryLevel != nil else { return "Plugged In" }
        // Unplugged — running on the battery.
        guard monitor.batteryOnAC else {
            if let m = monitor.batteryMinutesToEmpty { return "On Battery · \(BatteryInfo.durationString(m)) Left" }
            return "On Battery"
        }
        // Plugged in, but the adapter can't keep up so the battery is still draining.
        if monitor.batteryDraining { return "On Battery · Adapter Can't Keep Up" }
        // Plugged in, on wall power.
        if monitor.batteryFull { return "Plugged In · Fully Charged" }
        if monitor.batteryCharging {
            if let m = monitor.batteryMinutesToFull { return "Plugged In · \(BatteryInfo.durationString(m)) To Full" }
            return "Plugged In · Charging"
        }
        // On wall power, deliberately holding the charge to protect the battery.
        return "Plugged In · Optimized Charging"
    }

    private var batteryCaptionAnimationValue: Double? {
        guard monitor.batteryLevel != nil else { return nil }
        if !monitor.batteryOnAC { return monitor.batteryMinutesToEmpty.map(Double.init) }
        if monitor.batteryCharging, !monitor.batteryFull, !monitor.batteryDraining {
            return monitor.batteryMinutesToFull.map(Double.init)
        }
        return nil
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

// MARK: - Keep Awake widget

/// The Keep Awake control as a draggable, resizable tile. The eye is the toggle;
/// the duration strip scrolls to start a timed session. Lives in the same layout as
/// the metric widgets but never drives the menu-bar status item (see `menuBarKind`).
struct KeepAwakeWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var keepAwake: KeepAwakeController

    private var isSmall: Bool { size == .small }
    private var active: Bool { keepAwake.isActive }

    var body: some View {
        Group { if isSmall { small } else { large } }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isSmall ? 100 : nil, alignment: .topLeading)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.bad.opacity(active ? 0.10 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.bad.opacity(active ? 0.35 : 0), lineWidth: 1))
            }
            .animation(.easeInOut(duration: 0.4), value: active)
            .widgetDropTarget(.keepAwake)
    }

    private var large: some View {
        HStack(alignment: .center, spacing: 12) {
            eye(46)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    titleAndStatus
                    Spacer(minLength: 4)
                    WidgetControls(kind: .keepAwake, size: size)
                }
                DurationStrip(compact: false)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                eye(26)
                Text("Keep Awake")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                WidgetControls(kind: .keepAwake, size: size)
            }
            Text(keepAwake.statusLine)
                .font(.caption2)
                .foregroundStyle(active ? Theme.bad : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            DurationStrip(compact: true)
        }
    }

    private var titleAndStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keep Awake").font(.caption.weight(.semibold))
            Text(keepAwake.statusLine)
                .font(.caption2)
                .foregroundStyle(active ? Theme.bad : .secondary)
                .lineLimit(1)
        }
    }

    private func eye(_ eyeSize: CGFloat) -> some View {
        Button { keepAwake.toggle() } label: {
            EyeView(isActive: active, size: eyeSize)
        }
        .buttonStyle(.plain)
        .help(active ? "Stop keeping your Mac awake" : "Keep your Mac awake")
    }
}

/// Horizontal, scrollable row of durations. It quietly recedes until hovered, then
/// brightens into a scrollable track; tapping a duration starts a timed session.
private struct DurationStrip: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController
    var compact: Bool
    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    pill(duration)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .background(Color.primary.opacity(hovering ? 0.06 : 0.03), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(hovering ? 0.10 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }

    private func pill(_ duration: KeepAwakeDuration) -> some View {
        let selected = keepAwake.defaultDuration == duration
        let running = keepAwake.isActive && selected
        let fill: Color = running ? Theme.bad
            : selected ? Theme.bad.opacity(0.16)
            : Color.primary.opacity(0.06)

        return Button {
            keepAwake.defaultDuration = duration
            keepAwake.activate(option: duration)
        } label: {
            Text(duration.shortLabel)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(running ? .white : (selected ? Theme.bad : .secondary))
                .padding(.horizontal, compact ? 7 : 9)
                .padding(.vertical, compact ? 3 : 5)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(selected && !running ? Theme.bad.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .opacity(hovering || selected ? 1 : 0.7)
        .help("Keep awake for \(duration.label)")
    }
}
