import SwiftUI

enum MetricChartStyle {
    static let usageGradient: [Color] = [Theme.Chart.red, Theme.Chart.amber, Theme.Chart.green]
    static let batteryGradient: [Color] = [Theme.Chart.green, Theme.Chart.amber, Theme.Chart.red]
    static let normalizedDomain: ClosedRange<Double> = 0...1
    static let expandedWindow: TimeInterval = 24 * 60 * 60
    static let smallWindow: TimeInterval = 6 * 60 * 60
    static let expandedMaxPoints = 720
    static let smallMaxPoints = 240

    static func gradient(for metric: MetricKind) -> [Color]? {
        switch metric {
        case .cpu, .memory, .storage:
            return usageGradient
        case .battery:
            return batteryGradient
        case .temperature, .network:
            return nil
        }
    }

    static func chartColor(for metric: MetricKind) -> Color {
        switch metric {
        case .cpu:
            return Theme.Chart.purple
        case .memory, .network:
            return Theme.Chart.blue
        case .storage:
            return Theme.Chart.mint
        case .battery, .temperature:
            return Theme.Chart.green
        }
    }

    /// Slow histories are sampled once per minute. Gap detection happens before
    /// rendering reduction, so it should follow that source cadence rather than the
    /// chart's eventual point spacing.
    static func gapThreshold(window: TimeInterval, maximumPointCount: Int) -> TimeInterval {
        _ = window
        _ = maximumPointCount
        return max(SystemMonitor.chartSampleGapThreshold,
                   SystemMonitor.longHistorySampleInterval * 2.5)
    }
}
