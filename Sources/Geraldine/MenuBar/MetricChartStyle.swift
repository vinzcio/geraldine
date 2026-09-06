import SwiftUI

enum MetricChartStyle {
    static let normalizedDomain = MetricPresentationPolicy.usageDomain
    static let expandedWindow: TimeInterval = 24 * 60 * 60
    static let smallWindow: TimeInterval = 6 * 60 * 60
    static let expandedMaxPoints = 720
    static let smallMaxPoints = 240

    static func gradient(for metric: MetricKind) -> MetricGradientSpec? {
        switch metric {
        case .cpu, .gpu, .memory, .storage:
            return MetricPresentationPolicy.usageGradient
        case .battery:
            return MetricPresentationPolicy.batteryChargeGradient
        case .temperature:
            return MetricPresentationPolicy.temperatureGradient
        case .network:
            return nil
        }
    }

    static func chartColor(for metric: MetricKind) -> Color {
        switch metric {
        case .cpu, .gpu:
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
