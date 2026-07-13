import SwiftUI

enum MetricChartStyle {
    static let usageGradient: [Color] = [Theme.bad, Theme.warn, Theme.good]
    static let batteryGradient: [Color] = [Theme.good, Theme.warn, Theme.bad]
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

    static func readoutColor(for metric: MetricKind) -> Color {
        switch metric {
        case .cpu:
            return Theme.accent
        case .memory:
            return Theme.accent2
        case .storage:
            return Theme.mint
        case .battery:
            return Theme.good
        case .network:
            return Theme.accent2
        case .temperature:
            return Theme.good
        }
    }

    /// A rendered point may stand in for several raw samples on long windows. Allow
    /// that expected spacing while still breaking genuinely missing periods.
    static func gapThreshold(window: TimeInterval, maximumPointCount: Int) -> TimeInterval {
        let renderedSpacing = window / Double(max(maximumPointCount - 1, 1))
        return max(SystemMonitor.chartSampleGapThreshold, renderedSpacing * 2.5)
    }
}
