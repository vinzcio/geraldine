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

struct NetworkTrafficChart<StatsAccessory: View>: View {
    let samples: [NetworkSample]
    let stats: NetworkThroughputStats
    let chartHeight: CGFloat
    let showsInspection: Bool
    let rateUnit: NetworkRateUnit
    /// When true the Now/Avg/Peak columns stretch to fill the width beside the accessory,
    /// so they don't hug the left with a cavernous gap. The dashboard (no accessory) keeps
    /// the compact fixed-width table.
    let distributesColumns: Bool
    private let statsAccessory: StatsAccessory

    init(samples: [NetworkSample],
         stats: NetworkThroughputStats,
         chartHeight: CGFloat = 60,
         showsInspection: Bool = false,
         rateUnit: NetworkRateUnit = .bytesPerSecond,
         distributesColumns: Bool = true,
         @ViewBuilder statsAccessory: () -> StatsAccessory) {
        self.samples = samples
        self.stats = stats
        self.chartHeight = chartHeight
        self.showsInspection = showsInspection
        self.rateUnit = rateUnit
        self.distributesColumns = distributesColumns
        self.statsAccessory = statsAccessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NetworkTimelineGraph(samples: samples,
                                 window: SystemMonitor.liveHistoryWindow,
                                 now: Date(),
                                 downTint: Theme.Chart.blue,
                                 upTint: Theme.Chart.mint,
                                 downReference: stats.averageDown,
                                 upReference: stats.averageUp,
                                 showsInspection: showsInspection,
                                 rateUnit: rateUnit)
                .frame(height: chartHeight)
                .accessibilityLabel("Network throughput history")
            HStack(alignment: .top, spacing: 12) {
                if distributesColumns {
                    NetworkThroughputStatsTable(stats: stats, rateUnit: rateUnit,
                                                distributesColumns: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statsAccessory
                } else {
                    NetworkThroughputStatsTable(stats: stats, rateUnit: rateUnit,
                                                distributesColumns: false)
                    Spacer(minLength: 8)
                    statsAccessory
                }
            }
        }
    }
}

extension NetworkTrafficChart where StatsAccessory == EmptyView {
    init(samples: [NetworkSample],
         stats: NetworkThroughputStats,
         chartHeight: CGFloat = 60,
         showsInspection: Bool = false,
         rateUnit: NetworkRateUnit = .bytesPerSecond) {
        self.init(samples: samples,
                  stats: stats,
                  chartHeight: chartHeight,
                  showsInspection: showsInspection,
                  rateUnit: rateUnit,
                  distributesColumns: false) {
            EmptyView()
        }
    }
}

private struct NetworkThroughputStatsTable: View {
    let stats: NetworkThroughputStats
    let rateUnit: NetworkRateUnit
    var distributesColumns: Bool = false

    private let labelWidth: CGFloat = 54
    private let valueWidth: CGFloat = 58

    /// Fixed-width columns keep the compact dashboard table; distributed columns stretch to
    /// evenly fill the popover's wider row so the values aren't bunched on the left.
    @ViewBuilder private func columnFrame<V: View>(_ view: V) -> some View {
        if distributesColumns {
            view.frame(minWidth: valueWidth, maxWidth: .infinity, alignment: .trailing)
        } else {
            view.frame(width: valueWidth, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow
            statRow("arrow.down", "Down", iconTint: Theme.Chart.blue, textTint: Theme.Chart.blue,
                    now: stats.currentDown,
                    average: stats.hasSamples ? stats.averageDown : nil,
                    peak: stats.hasSamples ? stats.peakDown : nil)
            statRow("arrow.up", "Up", iconTint: Theme.Chart.mint, textTint: Theme.Chart.mint,
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
        columnFrame(
            Text(text)
                .font(.rounded(10, .semibold))
                .foregroundStyle(.secondary)
        )
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
            statValue(average, tint: textTint)
            statValue(peak, tint: textTint)
        }
    }

    @ViewBuilder private func statValue(_ value: Double?, tint: Color) -> some View {
        if let value {
            columnFrame(
                AnimatedNumberText(Fmt.compactRate(value, unit: rateUnit),
                                   value: rateUnit.displayValue(for: value))
                    .font(.rounded(11, .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.76)
            )
        } else {
            columnFrame(
                Text("-")
                    .font(.rounded(11, .semibold).monospacedDigit())
                    .foregroundStyle(.tertiary)
            )
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
