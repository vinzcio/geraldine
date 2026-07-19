import SwiftUI

struct BatteryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @StateObject private var vm = BatteryViewModel()
    @State private var range: HistoryRange = .day

    private var tint: Color { Module.battery.tint }
    // Charge only — never health or a stale history point. A temporarily unavailable
    // live reading stays nil (shown as an em dash) rather than impersonating "now."
    private var knownLevel: Double? { monitor.batteryLevel }
    private var level: Double { knownLevel ?? 0 }
    private var chargeTint: Color {
        MetricPresentationPolicy.batteryReadoutColor(level: knownLevel)
    }
    private var hardwareName: String { state.hardware.displayName }
    private var hasInternalBattery: Bool { monitor.hasBattery || vm.detail.hasBattery }
    private var chargeHistory: [ChargeSample] {
        vm.chartHistory
    }

    var body: some View {
        ModulePage(
            module: .battery,
            title: hasInternalBattery ? nil : "Power",
            subtitle: hasInternalBattery ? nil : "AC power status for \(hardwareName)",
            systemImage: hasInternalBattery ? nil : "powerplug",
            headerStyle: .data,
            widthRole: .fluid
        ) {
            if !hasInternalBattery {
                powerStatusCard
                consumersCard(title: "Power Consumers", subtitle: "Apps using the most energy")
            } else {
                hero
                historyCard
                consumersCard(title: "Battery Consumers", subtitle: "Apps using the most energy")
                healthCard
            }
        }
        .onAppear {
            guard surfaceActive else { return }
            vm.start()
            recordCurrentBatteryReading()
        }
        .onDisappear { vm.stop() }
        .onChange(of: surfaceActive) { _, isActive in
            if isActive {
                vm.start()
                recordCurrentBatteryReading()
            } else {
                vm.stop()
            }
        }
        .onChange(of: monitor.batteryHistory.last?.timestamp) { _, _ in
            guard surfaceActive, let sample = monitor.batteryHistory.last else { return }
            vm.recordLiveReading(
                level: sample.value,
                onAC: monitor.batteryOnAC,
                at: sample.date
            )
        }
        .onChange(of: monitor.batteryOnAC) { _, _ in
            guard surfaceActive else { return }
            recordCurrentBatteryReading()
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 18) {
            BatteryGlyph(level: level, charging: monitor.batteryCharging, tint: chargeTint)
            VStack(alignment: .leading, spacing: 4) {
                AnimatedNumberText(knownLevel.map(Fmt.percent) ?? "—", value: level * 100)
                    .font(.rounded(40, .bold))
                    .foregroundStyle(chargeTint)
                Text(statusText)
                    .font(.callout).foregroundStyle(.secondary)
                if vm.detail.adapterConnected, let adapter = adapterLabel {
                    Label(adapter, systemImage: "powerplug.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .card(tier: .tinted(chargeTint),
              cornerRadius: Theme.Radius.hero)
    }

    // Mirrors the menu-bar widget's battery language ("Plugged In · Optimized
    // Charging", never a worrying "not charging") so the two never disagree.
    private var statusText: String {
        let charging = monitor.batteryCharging
        if vm.detail.fullyCharged || (charging && level >= 0.995) { return "Fully Charged" }
        if charging {
            if let m = vm.detail.minutesToFull { return "Charging · \(BatteryInfo.durationString(m)) To Full" }
            return "Charging"
        }
        if vm.detail.externalConnected { return "Plugged In · Optimized Charging" }
        if let m = vm.detail.minutesToEmpty { return "On Battery · \(BatteryInfo.durationString(m)) Left" }
        return "On Battery"
    }

    private var adapterLabel: String? {
        if let name = vm.detail.adapterName, !name.isEmpty { return name }
        if let w = vm.detail.adapterWatts { return "\(w)W Power Adapter" }
        return nil
    }

    // MARK: Power-only status

    private var powerStatusCard: some View {
        HStack(spacing: 18) {
            IconBadge(icon: "powerplug.fill", tint: tint, size: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text("Plugged In")
                    .font(.rounded(32, .bold))
                Text(adapterLabel ?? "Running On AC Power")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if monitor.loadAverage > 0 {
                    AnimatedNumberText("System Load \(String(format: "%.2f", monitor.loadAverage))",
                                       value: monitor.loadAverage)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
        .card(tier: .tinted(tint), cornerRadius: Theme.Radius.hero)
    }

    // MARK: Charge history

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("Battery Level", subtitle: "Charge over \(range == .day ? "the last 24 hours" : "the last 10 days")")
                Picker("", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }

            if !vm.loadedHistory {
                placeholder { BrandSpinner(tint: tint, icon: "battery.100", size: 48) }
            } else if chargeHistory.isEmpty && monitor.batteryLevel == nil {
                placeholder {
                    Text("No battery history available yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ChargeHistoryChart(samples: chargeHistory, range: range, tint: Theme.Chart.green,
                                   currentLevel: monitor.batteryLevel,
                                   currentOnAC: monitor.batteryOnAC)
                    .frame(height: 168)
                    .id(range)
                    .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                HStack(spacing: 16) {
                    legendSwatch(Theme.Chart.green.opacity(0.18), "Charging / Plugged In")
                    batteryLevelLegend
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion), value: range)
        .card(tier: .raised, cornerRadius: Theme.Radius.raised)
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack { content() }
            .frame(maxWidth: .infinity).frame(height: 168)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(label)
        }
    }

    private var batteryLevelLegend: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(
                    gradient: MetricPresentationPolicy.batteryChargeGradient.swiftUI,
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 12, height: 12)
            Text("Battery Level")
        }
    }

    private func recordCurrentBatteryReading() {
        guard let level = monitor.batteryLevel else { return }
        vm.recordLiveReading(
            level: level,
            onAC: monitor.batteryOnAC
        )
    }

    // MARK: Consumers

    private func consumersCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title, subtitle: subtitle)
                Spacer()
                if vm.sampling && vm.consumers.isEmpty { ProgressView().controlSize(.small) }
            }
            let maxImpact = max(vm.consumers.map(\.impact).max() ?? 1, 1)
            VStack(spacing: 0) {
                if vm.consumers.isEmpty {
                    Text(vm.sampling ? "Measuring Energy Use…" : "No significant energy use right now.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(vm.consumers.enumerated()), id: \.element.id) { idx, c in
                        HStack(spacing: 12) {
                            ProcessIconPlate(pid: Int32(c.pid), tint: tint)
                            Text(c.name).lineLimit(1)
                            Spacer(minLength: 12)
                            StatBar(fraction: c.impact / maxImpact, tint: Theme.Chart.green, height: 6)
                                .frame(width: 90)
                            AnimatedNumberText(String(format: "%.1f", c.impact), value: c.impact)
                                .font(.callout.monospacedDigit()).foregroundStyle(Theme.Chart.green)
                                .frame(width: 42, alignment: .trailing)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                        if idx < vm.consumers.count - 1 { Divider() }
                    }
                }
            }
            .card(tier: .base)
        }
    }

    // MARK: Health / lifecycle

    @ViewBuilder private var healthCard: some View {
        let d = vm.detail
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Battery Health")
            HStack(spacing: 20) {
                GaugeRing(value: d.healthFraction ?? 0, tint: healthColor(d)) {
                    VStack(spacing: 1) {
                        Text(d.maxCapacityPercent.map { "\($0)%" } ?? "—")
                            .font(.rounded(22, .bold))
                            .foregroundStyle(MetricPresentationPolicy.batteryHealthReadoutColor(
                                d.healthFraction
                            ))
                        Text("Capacity").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    infoRow("Condition", d.condition ?? "Unknown", color: conditionColor(d.condition))
                    infoRow("Cycle Count", d.cycleCount.map(String.init) ?? "—")
                    if let t = d.temperatureC {
                        infoRow("Temperature", "\(String(format: "%.1f", t))°C", color: .secondary)
                    }
                }
                Spacer()
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                if let cur = d.currentMaxCapacity { cell("Current Capacity", "\(cur) mAh") }
                if let des = d.designCapacity { cell("Design Capacity", "\(des) mAh") }
                if let v = d.voltageV { cell("Voltage", "\(String(format: "%.2f", v)) V") }
                if let adapter = adapterLabel, d.adapterConnected { cell("Power Adapter", adapter) }
            }
        }
        .card(tier: .raised, cornerRadius: Theme.Radius.raised)
    }

    private func healthColor(_ d: BatteryDetail) -> Color {
        Theme.Chart.batteryHealth(d.healthFraction)
    }

    private func conditionColor(_ condition: String?) -> Color {
        guard let c = condition else { return .primary }
        return c == "Normal" ? Theme.good : Theme.warn
    }

    private func infoRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.rounded(15, .semibold)).foregroundStyle(color)
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.rounded(16, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: - Battery glyph

/// A horizontal battery icon whose inner bar fills to `level`, with a charging bolt.
struct BatteryGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var level: Double
    var charging: Bool
    var tint: Color

    @State private var plugHaloProgress: CGFloat = 1

    private let bodyWidth: CGFloat = 62
    private let bodyHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                Capsule()
                    .stroke(
                        tint
                            .opacity((1 - plugHaloProgress) * 0.46),
                        lineWidth: 2
                    )
                    .frame(width: bodyWidth + 16, height: bodyHeight + 16)
                    .scaleEffect(0.90 + (0.38 * plugHaloProgress))
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                    .frame(width: bodyWidth, height: bodyHeight)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(4, (bodyWidth - 8) * min(1, max(0, level))), height: bodyHeight - 8)
                        .animation(GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion), value: level)
                    Spacer(minLength: 0)
                }
                .frame(width: bodyWidth - 8, height: bodyHeight - 8)
                if charging {
                    ContextualSymbol(
                        inactive: "bolt",
                        active: "bolt.fill",
                        isActive: charging,
                        tint: .white,
                        size: 14
                    )
                    .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 3, height: 11)
        }
        .onChange(of: charging) { oldValue, newValue in
            guard !oldValue, newValue, !reduceMotion else { return }
            plugHaloProgress = 0
            withAnimation(GeraldineMotion.animation(.emphasis, reduceMotion: false)) {
                plugHaloProgress = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(charging ? "Battery charging" : "Battery")
        .accessibilityValue(Fmt.percent(level))
    }
}

// MARK: - Charge history chart

/// Reconstructs the macOS Battery-settings graph: charge level over time with
/// shaded charging/plugged-in windows behind the level curve.
struct ChargeHistoryChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @FocusState private var accessibilityFocused: Bool
    @State private var endpointReveal: CGFloat = 0
    @State private var inspectionLocation: CGPoint?
    @State private var accessibilityIndex: Int?

    var samples: [ChargeSample]
    var range: HistoryRange
    var tint: Color
    var currentLevel: Double?
    var currentOnAC: Bool

    var body: some View {
        ZStack {
            Canvas { ctx, size in
            let rightAxis: CGFloat = 36
            let bottomAxis: CGFloat = 18
            let plotW = max(1, size.width - rightAxis)
            let plotH = max(1, size.height - bottomAxis)

            let end = Date()
            let start = end.addingTimeInterval(-range.seconds)
            let span = max(1, end.timeIntervalSince(start))
            let segments = plotSegments(start: start, end: end)

            func x(_ date: Date) -> CGFloat {
                CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1)) * plotW
            }
            func y(_ level: Double) -> CGFloat { (1 - CGFloat(min(max(level, 0), 1))) * plotH }

            // A whisper of low-charge context, kept behind the actual data.
            let lowChargeY = y(0.20)
            ctx.fill(
                Path(CGRect(x: 0, y: lowChargeY, width: plotW, height: plotH - lowChargeY)),
                with: .color(Theme.Chart.red.opacity(0.035))
            )

            // Horizontal gridlines + % labels (100 / 50 / 0).
            for frac in [0.0, 0.5, 1.0] {
                let gy = y(frac)
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: gy))
                grid.addLine(to: CGPoint(x: plotW, y: gy))
                ctx.stroke(grid, with: .color(.primary.opacity(0.10)), lineWidth: 1)
                ctx.draw(Text("\(Int(frac * 100))%").font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: plotW + 6, y: gy), anchor: .leading)
            }

            for points in segments where points.count >= 2 {
                // Shading is limited to intervals supported by adjacent readings;
                // it never spans a sleep, shutdown, or missing-log gap.
                for i in 0..<(points.count - 1) where points[i].onAC {
                    let rect = CGRect(x: x(points[i].date), y: 0,
                                      width: max(0.5, x(points[i + 1].date) - x(points[i].date)),
                                      height: plotH)
                    ctx.fill(Path(rect), with: .color(tint.opacity(0.16)))
                }

                var area = Path()
                area.move(to: CGPoint(x: x(points[0].date), y: plotH))
                for point in points {
                    area.addLine(to: CGPoint(x: x(point.date), y: y(point.level)))
                }
                area.addLine(to: CGPoint(x: x(points[points.count - 1].date), y: plotH))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    MetricPresentationPolicy.batteryChargeGradient.opacity(0.24).swiftUI,
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: plotH)))

                var line = Path()
                for (index, point) in points.enumerated() {
                    let chartPoint = CGPoint(x: x(point.date), y: y(point.level))
                    index == 0 ? line.move(to: chartPoint) : line.addLine(to: chartPoint)
                }
                ctx.stroke(
                    line,
                    with: .linearGradient(
                        MetricPresentationPolicy.batteryChargeGradient.swiftUI,
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: plotH)
                    ),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            // Isolated, valid readings remain visible without implying a measured
            // interval on either side.
            for points in segments where points.count == 1 {
                let point = CGPoint(x: x(points[0].date), y: y(points[0].level))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                    with: .color(chargeColor(level: points[0].level))
                )
            }

            if currentLevel != nil, let last = segments.last?.last, endpointReveal > 0 {
                let point = CGPoint(x: x(last.date), y: y(last.level))
                let endpointColor = chargeColor(level: last.level)
                let haloRadius = 7 * endpointReveal
                ctx.fill(Path(ellipseIn: CGRect(x: point.x - haloRadius,
                                                y: point.y - haloRadius,
                                                width: haloRadius * 2,
                                                height: haloRadius * 2)),
                         with: .color(endpointColor.opacity(0.18 * Double(endpointReveal))))
                let dotRadius = 3 * endpointReveal
                ctx.fill(Path(ellipseIn: CGRect(x: point.x - dotRadius,
                                                y: point.y - dotRadius,
                                                width: dotRadius * 2,
                                                height: dotRadius * 2)),
                         with: .color(endpointColor))
            }

            // X-axis time labels.
            for tick in axisTicks(start: start, end: end) {
                ctx.draw(Text(tick.label).font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: x(tick.date), y: size.height - 7), anchor: .center)
            }
            }

            GeometryReader { proxy in
                if let inspection = displayedInspection(size: proxy.size) {
                    Path { path in
                        path.move(to: CGPoint(x: inspection.point.x, y: 0))
                        path.addLine(to: CGPoint(x: inspection.point.x, y: max(0, proxy.size.height - 18)))
                    }
                    .stroke(Theme.focusRing.opacity(0.46),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    Circle()
                        .fill(chargeColor(level: inspection.sample.level))
                        .frame(width: 8, height: 8)
                        .position(inspection.point)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.percent(inspection.sample.level))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(chargeColor(level: inspection.sample.level))
                        Text(inspection.sample.onAC ? "Plugged in" : "On battery")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(inspection.sample.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .adaptiveMaterialBackground(
                        .regular,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(Theme.separator))
                    .position(x: min(max(inspection.point.x, 58), proxy.size.width - 84), y: 31)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .strokeBorder(accessibilityFocused ? Theme.focusRing : .clear,
                              lineWidth: 2)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($accessibilityFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: moveAccessibilitySelection)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): inspectionLocation = point
            case .ended: inspectionLocation = nil
            }
        }
        .onChange(of: accessibilityFocused) { _, isFocused in
            if isFocused, accessibilityIndex == nil {
                accessibilityIndex = accessibilitySamples.indices.last
            } else if !isFocused {
                accessibilityIndex = nil
            }
        }
        .onChange(of: accessibilitySamples.count) { _, _ in clampAccessibilitySelection() }
        .onAppear {
            guard surfaceActive,
                  !reduceMotion,
                  let animation = GeraldineMotion.animation(.emphasis, reduceMotion: false) else {
                endpointReveal = 1
                return
            }
            withAnimation(animation) { endpointReveal = 1 }
        }
        .onDisappear {
            endpointReveal = 0
            inspectionLocation = nil
            accessibilityIndex = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery charge history")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Use left and right arrow keys, or increment and decrement, to inspect samples.")
        .accessibilityAdjustableAction(adjustAccessibilitySelection)
    }

    private func chargeColor(level: Double) -> Color {
        MetricPresentationPolicy.batteryChartColor(level: level)
    }

    private struct Inspection {
        let sample: ChargeSample
        let point: CGPoint
    }

    private func inspection(at location: CGPoint?, size: CGSize) -> Inspection? {
        guard let location else { return nil }
        let rightAxis: CGFloat = 36
        let plotWidth = max(1, size.width - rightAxis)
        let end = Date()
        let start = end.addingTimeInterval(-range.seconds)
        let points = plotSegments(start: start, end: end).flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let fraction = Double(min(max(location.x / plotWidth, 0), 1))
        let target = start.addingTimeInterval(range.seconds * fraction)
        guard let sample = points.min(by: {
            abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target))
        }) else { return nil }
        return inspection(for: sample, start: start, end: end, size: size)
    }

    private func displayedInspection(size: CGSize) -> Inspection? {
        if let hoverInspection = inspection(at: inspectionLocation, size: size) {
            return hoverInspection
        }
        guard let accessibilityIndex,
              accessibilitySamples.indices.contains(accessibilityIndex) else { return nil }
        let end = Date()
        let start = end.addingTimeInterval(-range.seconds)
        return inspection(for: accessibilitySamples[accessibilityIndex],
                          start: start,
                          end: end,
                          size: size)
    }

    private func inspection(for sample: ChargeSample, start: Date, end: Date, size: CGSize) -> Inspection {
        let rightAxis: CGFloat = 36
        let bottomAxis: CGFloat = 18
        let plotWidth = max(1, size.width - rightAxis)
        let plotHeight = max(1, size.height - bottomAxis)
        let x = CGFloat(min(max(sample.date.timeIntervalSince(start) / max(range.seconds, 1), 0), 1)) * plotWidth
        let y = (1 - CGFloat(min(max(sample.level, 0), 1))) * plotHeight
        return Inspection(sample: sample, point: CGPoint(x: x, y: y))
    }

    private var accessibilityValue: String {
        if let accessibilityIndex,
           accessibilitySamples.indices.contains(accessibilityIndex) {
            let sample = accessibilitySamples[accessibilityIndex]
            return "\(Fmt.percent(sample.level)), \(sample.onAC ? "plugged in" : "on battery"), \(Self.accessibilityDateFormatter.string(from: sample.date)), sample \(accessibilityIndex + 1) of \(accessibilitySamples.count)"
        }
        guard let latest = accessibilitySamples.last else {
            if let currentLevel { return "Current level \(Fmt.percent(currentLevel)); collecting history" }
            return "Collecting history"
        }
        return "Latest level \(Fmt.percent(currentLevel ?? latest.level)), \(currentOnAC ? "plugged in" : "on battery")"
    }

    private var accessibilitySamples: [ChargeSample] {
        let end = Date()
        return plotSegments(start: end.addingTimeInterval(-range.seconds), end: end).flatMap { $0 }
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: stepAccessibilitySelection(by: 1)
        case .decrement: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func moveAccessibilitySelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .right, .down: stepAccessibilitySelection(by: 1)
        case .left, .up: stepAccessibilitySelection(by: -1)
        @unknown default: break
        }
    }

    private func stepAccessibilitySelection(by offset: Int) {
        let samples = accessibilitySamples
        guard !samples.isEmpty else { return }
        let current = accessibilityIndex ?? (samples.count - 1)
        accessibilityIndex = min(max(current + offset, 0), samples.count - 1)
    }

    private func clampAccessibilitySelection() {
        guard let accessibilityIndex else { return }
        let count = accessibilitySamples.count
        if count == 0 {
            self.accessibilityIndex = nil
        } else {
            self.accessibilityIndex = min(accessibilityIndex, count - 1)
        }
    }

    /// Uses only measured points. The current reading is a real endpoint, but it
    /// remains a separate dot when the last source event is too old to support a line.
    private func plotSegments(start: Date, end: Date) -> [[ChargeSample]] {
        var visible: [ChargeSample] = []
        for sample in samples {
            if sample.date < start { continue }
            if sample.date > end { break }
            visible.append(sample)
        }
        if let currentLevel {
            let current = ChargeSample(date: end, level: currentLevel, onAC: currentOnAC)
            if visible.last?.date == end {
                visible[visible.count - 1] = current
            } else {
                visible.append(current)
            }
        }
        return BatteryHistoryPolicy.segments(
            normalizedSamples: visible,
            start: start,
            end: end
        )
    }

    private func axisTicks(start: Date, end: Date) -> [(date: Date, label: String)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var ticks: [(date: Date, label: String)] = []

        if range == .day {
            var t = cal.startOfDay(for: start)
            while t < start { t = cal.date(byAdding: .hour, value: 3, to: t) ?? end.addingTimeInterval(1) }
            while t <= end {
                ticks.append((t, hourLabel(t, cal)))
                guard let next = cal.date(byAdding: .hour, value: 3, to: t) else { break }
                t = next
            }
        } else {
            var t = cal.startOfDay(for: start)
            while t < start { t = cal.date(byAdding: .day, value: 1, to: t) ?? end.addingTimeInterval(1) }
            while t <= end {
                ticks.append((t, Self.dayTickFormatter.string(from: t)))
                guard let next = cal.date(byAdding: .day, value: 2, to: t) else { break }
                t = next
            }
        }
        return ticks
    }

    /// The chart redraws on every monitor tick; don't rebuild a DateFormatter each time.
    private static let dayTickFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d"
        return df
    }()

    private static let accessibilityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func hourLabel(_ date: Date, _ cal: Calendar) -> String {
        let h = cal.component(.hour, from: date)
        if h == 0 { return "12A" }
        if h == 12 { return "12P" }
        return h < 12 ? "\(h)" : "\(h - 12)"
    }
}
