import XCTest
import SwiftUI
@testable import Geraldine

final class MetricPresentationPolicyTests: XCTestCase {
    func testUsageThresholdBoundariesHaveOneSharedState() {
        XCTAssertEqual(MetricPresentationPolicy.usageState(0.5999), .good)
        XCTAssertEqual(MetricPresentationPolicy.usageState(0.60), .warning)
        XCTAssertEqual(MetricPresentationPolicy.usageState(0.8499), .warning)
        XCTAssertEqual(MetricPresentationPolicy.usageState(0.85), .bad)
    }

    func testTemperatureThresholdBoundariesHaveOneSharedState() {
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(54.9), .good)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(55), .warning)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(69.9), .warning)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(70), .hot)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(74), .hot)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(84.9), .hot)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(85), .bad)
        XCTAssertEqual(MetricPresentationPolicy.temperatureState(100), .critical)
    }

    func testBatteryChargeThresholdsFollowThePlottedLevel() {
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeState(level: 0.05), .bad)
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeState(level: 0.10), .bad)
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeState(level: 0.20), .warning)
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeState(level: 0.21), .good)
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeState(level: nil), .unknown)
    }

    func testEveryLiveReadoutUsesTheExactChartColorForItsState() {
        for usage in [0.20, 0.60, 0.84, 0.85, 0.93] {
            XCTAssertEqual(MetricPresentationPolicy.usageReadoutColor(usage),
                           MetricPresentationPolicy.usageChartColor(usage))
        }
        for temperature in [45.0, 55, 69, 74, 85, 100] {
            XCTAssertEqual(MetricPresentationPolicy.temperatureReadoutColor(temperature),
                           MetricPresentationPolicy.temperatureChartColor(temperature))
        }
        for level: Double? in [nil, 0.05, 0.15, 0.75] {
            XCTAssertEqual(MetricPresentationPolicy.batteryReadoutColor(level: level),
                           MetricPresentationPolicy.batteryChartColor(level: level))
        }
    }

    func testGradientStopsMatchTheNumericThresholds() {
        XCTAssertEqual(MetricPresentationPolicy.usageGradient.stops.map(\.location), [0, 0.15, 0.40, 1])
        XCTAssertEqual(
            MetricPresentationPolicy.temperatureGradient.stops.map(\.location),
            [0, 5.0 / 65.0, 20.0 / 65.0, 35.0 / 65.0, 50.0 / 65.0, 1]
        )
        XCTAssertEqual(MetricPresentationPolicy.batteryChargeGradient.stops.map(\.location), [0, 0.80, 0.90, 1])
    }
}
