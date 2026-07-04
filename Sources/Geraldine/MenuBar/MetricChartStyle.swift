import SwiftUI

enum MetricChartStyle {
    static let usageGradient: [Color] = [Theme.bad, Theme.warn, Theme.good]
    static let batteryGradient: [Color] = [Theme.good, Theme.warn, Theme.bad]
    static let normalizedDomain: ClosedRange<Double> = 0...1
    static let expandedWindowSeconds = 24 * 60 * 60
    static let smallWindowSeconds = 6 * 60 * 60
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
            return Color(red: 0.20, green: 0.70, blue: 0.62)
        case .battery:
            return Theme.good
        case .network:
            return Theme.accent2
        case .temperature:
            return Theme.good
        }
    }

    static func chartValues(_ values: [Double], seconds: Int, maxPoints: Int) -> [Double] {
        guard values.count > seconds else {
            return downsample(values, maxPoints: maxPoints)
        }
        return downsample(Array(values.suffix(seconds)), maxPoints: maxPoints)
    }

    private static func downsample(_ values: [Double], maxPoints: Int) -> [Double] {
        guard maxPoints > 1, values.count > maxPoints else { return values }
        let step = Double(values.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { index in
            let sourceIndex = min(values.count - 1, Int((Double(index) * step).rounded()))
            return values[sourceIndex]
        }
    }
}
