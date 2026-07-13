import XCTest
@testable import Geraldine

final class TimelineWindowTests: XCTestCase {
    func testFreshSamplesStayAtTheRightEdgeOfAFixedWindow() {
        let timeline = TimelineWindow(end: 300, duration: 300)

        XCTAssertEqual(timeline.fraction(for: 299), 299.0 / 300.0, accuracy: 0.000_001)
        XCTAssertEqual(timeline.fraction(for: 300), 1, accuracy: 0.000_001)
    }

    func testSamplesLeaveTheChartOnlyWhenTheirActualAgeExceedsTheWindow() {
        let timeline = TimelineWindow(end: 300, duration: 300)
        let samples = [
            MetricSample(timestamp: -0.01, value: 0.1),
            MetricSample(timestamp: 0, value: 0.2),
            MetricSample(timestamp: 299, value: 0.3)
        ]

        XCTAssertEqual(timeline.visible(samples).map(\.timestamp), [0, 299])
        XCTAssertEqual(timeline.fraction(for: 0), 0, accuracy: 0.000_001)
    }

    func testSamplingGapsBecomeSeparateLineSegments() {
        let timeline = TimelineWindow(end: 300, duration: 300)
        let samples = [
            MetricSample(timestamp: 290, value: 0.1),
            MetricSample(timestamp: 291, value: 0.2),
            MetricSample(timestamp: 297, value: 0.3)
        ]

        let segments = timeline.segments(samples, gapThreshold: 4)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map { $0.map(\.timestamp) }, [[290, 291], [297]])
    }

    func testDownsamplingKeepsTheTimelineEndpoints() {
        let timeline = TimelineWindow(end: 300, duration: 300)
        let samples = (0...300).map { MetricSample(timestamp: Double($0), value: Double($0)) }

        let downsampled = timeline.downsample(samples, maximumCount: 4)

        XCTAssertEqual(downsampled.map(\.timestamp), [0, 100, 200, 300])
    }
}
