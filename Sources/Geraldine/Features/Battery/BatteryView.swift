import SwiftUI

struct BatteryView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var vm = BatteryViewModel()
    @State private var range: HistoryRange = .day

    private var tint: Color { Module.battery.tint }
    private var level: Double { monitor.batteryLevel ?? vm.detail.healthFraction ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ModuleHeader(module: .battery)
                    .padding(.horizontal, -26)

                if monitor.batteryLevel == nil && !vm.detail.hasBattery {
                    EmptyState(icon: "powerplug",
                               title: "No battery detected",
                               message: "This Mac runs on AC power, so there's no battery to report on.",
                               tint: tint)
                        .frame(minHeight: 320)
                } else {
                    hero
                    historyCard
                    consumersCard
                    healthCard
                }
            }
            .padding(26)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 18) {
            BatteryGlyph(level: level, charging: monitor.batteryCharging)
            VStack(alignment: .leading, spacing: 4) {
                AnimatedNumberText(Fmt.percent(level), value: level * 100)
                    .font(.rounded(40, .bold))
                    .foregroundStyle(BatteryGlyph.color(level: level, charging: monitor.batteryCharging))
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
        .card()
    }

    private var statusText: String {
        let charging = monitor.batteryCharging
        if vm.detail.fullyCharged || (charging && level >= 0.995) { return "Fully charged" }
        if charging {
            if let m = vm.detail.minutesToFull { return "Charging · \(BatteryInfo.durationString(m)) until full" }
            return "Charging"
        }
        if vm.detail.externalConnected { return "Plugged in · Not charging" }
        if let m = vm.detail.minutesToEmpty { return "On battery · \(BatteryInfo.durationString(m)) remaining" }
        return "On battery"
    }

    private var adapterLabel: String? {
        if let name = vm.detail.adapterName, !name.isEmpty { return name }
        if let w = vm.detail.adapterWatts { return "\(w)W Power Adapter" }
        return nil
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
                placeholder { ProgressView() }
            } else if vm.history.isEmpty {
                placeholder {
                    Text("No battery history available yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ChargeHistoryChart(samples: vm.history, range: range, tint: tint,
                                   currentLevel: monitor.batteryLevel,
                                   currentOnAC: monitor.batteryCharging || vm.detail.externalConnected)
                    .frame(height: 168)
                HStack(spacing: 16) {
                    legendSwatch(tint.opacity(0.18), "Charging / plugged in")
                    legendSwatch(tint, "Battery level")
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .card()
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

    // MARK: Consumers

    private var consumersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader("Battery Consumers", subtitle: "Apps using the most energy")
                Spacer()
                if vm.sampling && vm.consumers.isEmpty { ProgressView().controlSize(.small) }
            }
            let maxImpact = max(vm.consumers.map(\.impact).max() ?? 1, 1)
            VStack(spacing: 0) {
                if vm.consumers.isEmpty {
                    Text(vm.sampling ? "Measuring energy use…" : "No significant energy use right now.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(vm.consumers.enumerated()), id: \.element.id) { idx, c in
                        HStack(spacing: 12) {
                            Text(c.name).lineLimit(1)
                            Spacer(minLength: 12)
                            StatBar(fraction: c.impact / maxImpact, tint: tint, height: 6)
                                .frame(width: 90)
                            AnimatedNumberText(String(format: "%.1f", c.impact), value: c.impact)
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                        .padding(.vertical, 7)
                        if idx < vm.consumers.count - 1 { Divider() }
                    }
                }
            }
            .card()
        }
    }

    // MARK: Health / lifecycle

    @ViewBuilder private var healthCard: some View {
        let d = vm.detail
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Battery Health")
            HStack(spacing: 20) {
                GaugeRing(value: d.healthFraction ?? 0, tint: healthColor(d)) {
                    VStack(spacing: 1) {
                        Text(d.maxCapacityPercent.map { "\($0)%" } ?? "—")
                            .font(.rounded(22, .bold))
                        Text("capacity").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)

                VStack(alignment: .leading, spacing: 9) {
                    infoRow("Condition", d.condition ?? "Unknown", color: conditionColor(d.condition))
                    infoRow("Cycle count", d.cycleCount.map(String.init) ?? "—")
                    if let t = d.temperatureC {
                        infoRow("Temperature", "\(String(format: "%.1f", t))°C", color: Thermal.color(t))
                    }
                }
                Spacer()
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)], spacing: 12) {
                if let cur = d.currentMaxCapacity { cell("Current capacity", "\(cur) mAh") }
                if let des = d.designCapacity { cell("Design capacity", "\(des) mAh") }
                if let v = d.voltageV { cell("Voltage", "\(String(format: "%.2f", v)) V") }
                if let adapter = adapterLabel, d.adapterConnected { cell("Power adapter", adapter) }
            }
        }
        .card()
    }

    private func healthColor(_ d: BatteryDetail) -> Color {
        guard let h = d.healthFraction else { return tint }
        return h >= 0.8 ? Theme.good : (h >= 0.6 ? Theme.warn : Theme.bad)
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
    var level: Double
    var charging: Bool

    static func color(level: Double, charging: Bool) -> Color {
        if charging || level > 0.2 { return Theme.good }
        if level > 0.1 { return Theme.warn }
        return Theme.bad
    }

    private let bodyWidth: CGFloat = 62
    private let bodyHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
                    .frame(width: bodyWidth, height: bodyHeight)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Self.color(level: level, charging: charging).gradient)
                        .frame(width: max(4, (bodyWidth - 8) * min(1, max(0, level))), height: bodyHeight - 8)
                        .animation(.easeInOut(duration: 0.5), value: level)
                    Spacer(minLength: 0)
                }
                .frame(width: bodyWidth - 8, height: bodyHeight - 8)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            Capsule()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 3, height: 11)
        }
    }
}

// MARK: - Charge history chart

/// Reconstructs the macOS Battery-settings graph: charge level over time with
/// shaded charging/plugged-in windows behind the level curve.
struct ChargeHistoryChart: View {
    var samples: [ChargeSample]
    var range: HistoryRange
    var tint: Color
    var currentLevel: Double?
    var currentOnAC: Bool

    var body: some View {
        Canvas { ctx, size in
            let rightAxis: CGFloat = 36
            let bottomAxis: CGFloat = 18
            let plotW = max(1, size.width - rightAxis)
            let plotH = max(1, size.height - bottomAxis)

            let end = Date()
            let start = end.addingTimeInterval(-range.seconds)
            let span = max(1, end.timeIntervalSince(start))
            let pts = plotPoints(start: start, end: end)

            func x(_ date: Date) -> CGFloat {
                CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1)) * plotW
            }
            func y(_ level: Double) -> CGFloat { (1 - CGFloat(min(max(level, 0), 1))) * plotH }

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

            guard pts.count >= 2 else { return }

            // Shaded windows where the Mac was on AC / charging.
            for i in 0..<(pts.count - 1) where pts[i].onAC {
                let rect = CGRect(x: x(pts[i].date), y: 0,
                                  width: max(0.5, x(pts[i + 1].date) - x(pts[i].date)), height: plotH)
                ctx.fill(Path(rect), with: .color(tint.opacity(0.16)))
            }

            // Area under the level curve.
            var area = Path()
            area.move(to: CGPoint(x: x(pts[0].date), y: plotH))
            for p in pts { area.addLine(to: CGPoint(x: x(p.date), y: y(p.level))) }
            area.addLine(to: CGPoint(x: x(pts[pts.count - 1].date), y: plotH))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.38), tint.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: plotH)))

            // Level line.
            var line = Path()
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: x(p.date), y: y(p.level))
                i == 0 ? line.move(to: pt) : line.addLine(to: pt)
            }
            ctx.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // X-axis time labels.
            for tick in axisTicks(start: start, end: end) {
                ctx.draw(Text(tick.label).font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: x(tick.date), y: size.height - 7), anchor: .center)
            }
        }
    }

    /// Window-clipped samples, anchored at both edges so the curve spans the full width.
    private func plotPoints(start: Date, end: Date) -> [ChargeSample] {
        let within = samples.filter { $0.date >= start && $0.date <= end }
        var pts: [ChargeSample] = []
        let prior = samples.last { $0.date < start }
        if let first = within.first, first.date > start {
            let anchor = prior ?? first
            pts.append(ChargeSample(date: start, level: anchor.level, onAC: anchor.onAC))
        } else if within.isEmpty, let prior {
            pts.append(ChargeSample(date: start, level: prior.level, onAC: prior.onAC))
        }
        pts.append(contentsOf: within)
        if let lastLevel = currentLevel ?? pts.last?.level {
            pts.append(ChargeSample(date: end, level: lastLevel, onAC: currentOnAC))
        }
        return pts
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
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "MMM d"
            while t <= end {
                ticks.append((t, df.string(from: t)))
                guard let next = cal.date(byAdding: .day, value: 2, to: t) else { break }
                t = next
            }
        }
        return ticks
    }

    private func hourLabel(_ date: Date, _ cal: Calendar) -> String {
        let h = cal.component(.hour, from: date)
        if h == 0 { return "12A" }
        if h == 12 { return "12P" }
        return h < 12 ? "\(h)" : "\(h - 12)"
    }
}
