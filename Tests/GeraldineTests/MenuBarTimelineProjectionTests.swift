import XCTest
@testable import Geraldine

final class MenuBarTimelineProjectionTests: XCTestCase {
    func testCompactMetricSamplesKeepTheirElapsedTimePositionInTheSixtySecondWindow() {
        let timeline = TimelineWindow(end: 100, duration: 60)

        XCTAssertEqual(timeline.fraction(for: 41), 1.0 / 60.0, accuracy: 0.000_001)
        XCTAssertEqual(timeline.fraction(for: 99), 59.0 / 60.0, accuracy: 0.000_001)
    }

    func testRestartSessionCreatesSeparateCompactSparklineSegments() {
        let restoredSession = UUID()
        let currentSession = UUID()
        let timeline = TimelineWindow(end: 100, duration: 60)
        let samples = [
            MetricSample(timestamp: 96, value: 0.2, sessionID: restoredSession),
            MetricSample(timestamp: 97, value: 0.3, sessionID: restoredSession),
            MetricSample(timestamp: 98, value: 0.4, sessionID: currentSession),
            MetricSample(timestamp: 99, value: 0.5, sessionID: currentSession)
        ]

        let segments = MenuBarTimelineRendering.segments(
            samples: samples,
            timeline: timeline,
            gapThreshold: 4,
            maximumPointCount: 60
        )

        XCTAssertEqual(segments.map { $0.map(\.timestamp) }, [[96, 97], [98, 99]])
    }

    func testLatestRestartSessionSingletonIsPreservedForEndpointRendering() {
        let restoredSession = UUID()
        let currentSession = UUID()
        let timeline = TimelineWindow(end: 100, duration: 60)
        let samples = [
            MetricSample(timestamp: 96, value: 0.2, sessionID: restoredSession),
            MetricSample(timestamp: 97, value: 0.3, sessionID: restoredSession),
            MetricSample(timestamp: 99, value: 0.5, sessionID: currentSession)
        ]

        let segments = MenuBarTimelineRendering.segments(
            samples: samples,
            timeline: timeline,
            gapThreshold: 4,
            maximumPointCount: 60
        )

        XCTAssertEqual(segments.map { $0.map(\.timestamp) }, [[96, 97], [99]])
    }
}
