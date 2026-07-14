import SwiftUI

struct NetworkThroughputStats {
    let currentDown: Double
    let currentUp: Double
    let peakDown: Double
    let peakUp: Double
    let averageDown: Double
    let averageUp: Double
    let hasSamples: Bool

    init(samples: [NetworkSample], currentDown: Double, currentUp: Double) {
        let downSamples = samples.map(\.down)
        let upSamples = samples.map(\.up)

        self.currentDown = Self.rate(currentDown)
        self.currentUp = Self.rate(currentUp)
        peakDown = downSamples.max() ?? 0
        peakUp = upSamples.max() ?? 0
        averageDown = Self.average(downSamples)
        averageUp = Self.average(upSamples)
        hasSamples = downSamples.count >= 2 || upSamples.count >= 2
    }

    private static func rate(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct NetworkTrafficChart: View {
    let samples: [NetworkSample]
    let stats: NetworkThroughputStats
    var chartHeight: CGFloat = 60
    var showsInspection = false
    var rateUnit: NetworkRateUnit = .bytesPerSecond

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NetworkTimelineGraph(samples: samples,
                                 window: SystemMonitor.liveHistoryWindow,
                                 now: Date(),
                                 downTint: Theme.Chart.blue,
                                 upTint: Theme.Chart.purple,
                                 downReference: stats.averageDown,
                                 upReference: stats.averageUp,
                                 showsInspection: showsInspection,
                                 rateUnit: rateUnit)
                .frame(height: chartHeight)
                .accessibilityLabel("Network throughput history")
            NetworkThroughputStatsTable(stats: stats, rateUnit: rateUnit)
        }
    }
}

private struct NetworkThroughputStatsTable: View {
    let stats: NetworkThroughputStats
    let rateUnit: NetworkRateUnit

    private let labelWidth: CGFloat = 54
    private let valueWidth: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
            statRow("arrow.down", "Down", iconTint: Theme.Chart.blue, textTint: Theme.accent2,
                    now: stats.currentDown,
                    average: stats.hasSamples ? stats.averageDown : nil,
                    peak: stats.hasSamples ? stats.peakDown : nil)
            statRow("arrow.up", "Up", iconTint: Theme.Chart.purple, textTint: Theme.accent,
                    now: stats.currentUp,
                    average: stats.hasSamples ? stats.averageUp : nil,
                    peak: stats.hasSamples ? stats.peakUp : nil)
        }
        .lineLimit(1)
        .padding(.top, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network throughput statistics")
        .accessibilityValue(accessibilityValue)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("")
                .frame(width: labelWidth, alignment: .leading)
            header("Now")
            header("Avg 5m")
            header("Peak 5m")
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.rounded(10, .semibold))
            .foregroundStyle(.secondary)
            .frame(width: valueWidth, alignment: .trailing)
    }

    private func statRow(_ icon: String, _ label: String, iconTint: Color, textTint: Color,
                         now: Double, average: Double?, peak: Double?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.rounded(10, .bold))
                    .foregroundStyle(iconTint)
                    .frame(width: 9)
                Text(label)
                    .font(.rounded(10, .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: labelWidth, alignment: .leading)

            statValue(now, tint: textTint)
            statValue(average, tint: textTint.opacity(0.88))
            statValue(peak, tint: textTint)
        }
    }

    @ViewBuilder private func statValue(_ value: Double?, tint: Color) -> some View {
        if let value {
            AnimatedNumberText(Fmt.compactRate(value, unit: rateUnit),
                               value: rateUnit.displayValue(for: value))
                .font(.rounded(11, .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .minimumScaleFactor(0.76)
                .frame(width: valueWidth, alignment: .trailing)
        } else {
            Text("-")
                .font(.rounded(11, .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private var accessibilityValue: String {
        guard stats.hasSamples else {
            return "Current download \(Fmt.rate(stats.currentDown, unit: rateUnit)), current upload \(Fmt.rate(stats.currentUp, unit: rateUnit)), collecting history for averages and peaks"
        }

        return [
            "Current download \(Fmt.rate(stats.currentDown, unit: rateUnit))",
            "current upload \(Fmt.rate(stats.currentUp, unit: rateUnit))",
            "average download \(Fmt.rate(stats.averageDown, unit: rateUnit))",
            "average upload \(Fmt.rate(stats.averageUp, unit: rateUnit))",
            "peak download \(Fmt.rate(stats.peakDown, unit: rateUnit))",
            "peak upload \(Fmt.rate(stats.peakUp, unit: rateUnit))"
        ].joined(separator: ", ")
    }
}
