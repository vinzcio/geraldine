import SwiftUI

/// Renderer-neutral metric state. Every Geraldine surface asks this policy for
/// state first, then chooses the semantic or chart-strength color for that state.
enum MetricVisualState: Equatable {
    case unknown
    case good
    case warning
    case hot
    case bad
    case critical
}

struct MetricGradientStop {
    let color: Color
    /// Unit-space position from the top of a vertically rendered chart.
    let location: CGFloat
}

struct MetricGradientSpec {
    let stops: [MetricGradientStop]

    var swiftUI: Gradient {
        Gradient(stops: stops.map { .init(color: $0.color, location: $0.location) })
    }

    func opacity(_ opacity: Double) -> MetricGradientSpec {
        MetricGradientSpec(stops: stops.map {
            MetricGradientStop(color: $0.color.opacity(opacity), location: $0.location)
        })
    }
}

/// One source of truth for scalar chart domains, thresholds, and colors.
enum MetricPresentationPolicy {
    static let usageDomain: ClosedRange<Double> = 0...1
    static let temperatureDomain: ClosedRange<Double> = 40...105

    static let usageGradient = MetricGradientSpec(stops: [
        .init(color: Theme.Chart.red, location: 0),
        .init(color: Theme.Chart.red, location: 0.15),       // 85%
        .init(color: Theme.Chart.amber, location: 0.40),     // 60%
        .init(color: Theme.Chart.green, location: 1)
    ])

    static let temperatureGradient = MetricGradientSpec(stops: [
        .init(color: Theme.Chart.plum, location: 0),
        .init(color: Theme.Chart.plum, location: 5.0 / 65.0),    // 100 C
        .init(color: Theme.Chart.red, location: 20.0 / 65.0),    // 85 C
        .init(color: Theme.Chart.orange, location: 35.0 / 65.0), // 70 C
        .init(color: Theme.Chart.amber, location: 50.0 / 65.0),  // 55 C
        .init(color: Theme.Chart.green, location: 1)
    ])

    /// Charge is inverse severity: a high point is healthy green and the bottom
    /// 20% transitions through warning into the critical 10% band.
    static let batteryChargeGradient = MetricGradientSpec(stops: [
        .init(color: Theme.Chart.green, location: 0),
        .init(color: Theme.Chart.amber, location: 0.80),  // 20%
        .init(color: Theme.Chart.red, location: 0.90),    // 10%
        .init(color: Theme.Chart.red, location: 1)
    ])

    static func usageState(_ fraction: Double) -> MetricVisualState {
        switch fraction {
        case ..<0.60: .good
        case ..<0.85: .warning
        default: .bad
        }
    }

    static func temperatureState(_ celsius: Double) -> MetricVisualState {
        switch celsius {
        case ..<55: .good
        case ..<70: .warning
        case ..<85: .hot
        case ..<100: .bad
        default: .critical
        }
    }

    /// Battery magnitude is intentionally level-only. Charging is a separate
    /// state communicated by the bolt/status copy; folding it into this color
    /// would make a 5% charging battery green while its 5% chart point is red.
    static func batteryChargeState(level: Double?) -> MetricVisualState {
        guard let level else { return .unknown }
        if level <= 0.10 { return .bad }
        if level <= 0.20 { return .warning }
        return .good
    }

    static func batteryHealthState(_ health: Double?) -> MetricVisualState {
        guard let health else { return .unknown }
        if health >= 0.80 { return .good }
        return health >= 0.60 ? .warning : .bad
    }

    static func semanticColor(for state: MetricVisualState) -> Color {
        switch state {
        case .unknown: Color.secondary
        case .good: Theme.good
        case .warning: Theme.warn
        case .hot: Theme.orange
        case .bad: Theme.bad
        case .critical: Theme.plum
        }
    }

    static func chartColor(for state: MetricVisualState) -> Color {
        switch state {
        case .unknown: Color.secondary
        case .good: Theme.Chart.green
        case .warning: Theme.Chart.amber
        case .hot: Theme.Chart.orange
        case .bad: Theme.Chart.red
        case .critical: Theme.Chart.plum
        }
    }

    /// Live numeric readouts deliberately use the visualization palette itself.
    /// A readout and its chart endpoint must resolve to the exact same color, not
    /// merely to two different palette colors that represent the same state.
    static func readoutColor(for state: MetricVisualState) -> Color {
        chartColor(for: state)
    }

    static func usageSemanticColor(_ fraction: Double) -> Color {
        semanticColor(for: usageState(fraction))
    }

    static func usageChartColor(_ fraction: Double) -> Color {
        chartColor(for: usageState(fraction))
    }

    static func usageReadoutColor(_ fraction: Double) -> Color {
        readoutColor(for: usageState(fraction))
    }

    static func temperatureSemanticColor(_ celsius: Double) -> Color {
        semanticColor(for: temperatureState(celsius))
    }

    static func temperatureChartColor(_ celsius: Double) -> Color {
        chartColor(for: temperatureState(celsius))
    }

    static func temperatureReadoutColor(_ celsius: Double) -> Color {
        readoutColor(for: temperatureState(celsius))
    }

    static func batterySemanticColor(level: Double?) -> Color {
        semanticColor(for: batteryChargeState(level: level))
    }

    static func batteryChartColor(level: Double?) -> Color {
        chartColor(for: batteryChargeState(level: level))
    }

    static func batteryReadoutColor(level: Double?) -> Color {
        readoutColor(for: batteryChargeState(level: level))
    }

    static func batteryHealthReadoutColor(_ health: Double?) -> Color {
        readoutColor(for: batteryHealthState(health))
    }
}

/// Attention is intentionally separate from visual state. A red chart does not
/// automatically mean Geraldine should interrupt the user.
enum MetricAttentionPolicy {
    static let cpuUsage = 0.88
    static let memoryUsage = 0.85
    static let storageUsage = 0.90
    static let lowBattery = 0.20
}
