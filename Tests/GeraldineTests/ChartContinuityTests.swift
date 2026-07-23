import XCTest
@testable import Geraldine

final class ChartContinuityTests: XCTestCase {
    func testSlowChartGapThresholdTracksRawSamplingCadence() {
        XCTAssertEqual(
            MetricChartStyle.gapThreshold(window: 24 * 60 * 60, maximumPointCount: 720),
            SystemMonitor.longHistorySampleInterval * 2.5
        )
    }

    func testTimelineDownsamplesEachRawContinuitySegmentIndependently() {
        let timeline = TimelineWindow(end: 300, duration: 300)
        let beforeRestart = (0...100).map {
            MetricSample(timestamp: Double($0), value: Double($0))
        }
        let afterRestart = (200...300).map {
            MetricSample(timestamp: Double($0), value: Double($0))
        }

        let segments = TimelineChartRendering.segments(
            samples: beforeRestart + afterRestart,
            timeline: timeline,
            gapThreshold: 4,
            maximumPointCount: 4
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.count), [4, 4])
        XCTAssertEqual(segments[0].map(\.timestamp), [0, 33, 67, 100])
        XCTAssertEqual(segments[1].map(\.timestamp), [200, 233, 267, 300])
    }

    func testMetricRenderingKeepsNewestSingletonAsTheLatestSegment() {
        let restoredSession = UUID()
        let currentSession = UUID()
        let timeline = TimelineWindow(end: 100, duration: 60)
        let samples = [
            MetricSample(timestamp: 96, value: 0.2, sessionID: restoredSession),
            MetricSample(timestamp: 97, value: 0.3, sessionID: restoredSession),
            MetricSample(timestamp: 99, value: 0.4, sessionID: currentSession)
        ]

        let segments = TimelineChartRendering.segments(
            samples: samples,
            timeline: timeline,
            gapThreshold: 4,
            maximumPointCount: 60
        )

        XCTAssertEqual(segments.map(\.count), [2, 1])
        XCTAssertEqual(segments.last?.last?.timestamp, 99)
        XCTAssertEqual(segments.last?.last?.sessionID, currentSession)
    }

    func testNetworkRenderingKeepsNewestSingletonAsTheLatestSegment() {
        let restoredSession = UUID()
        let currentSession = UUID()
        let timeline = TimelineWindow(end: 100, duration: 60)
        let samples = [
            NetworkSample(timestamp: 96, down: 10, up: 2, sessionID: restoredSession),
            NetworkSample(timestamp: 97, down: 12, up: 3, sessionID: restoredSession),
            NetworkSample(timestamp: 99, down: 15, up: 4, sessionID: currentSession)
        ]

        let segments = TimelineChartRendering.segments(
            samples: samples,
            timeline: timeline,
            gapThreshold: 4,
            maximumPointCount: nil
        )

        XCTAssertEqual(segments.map(\.count), [2, 1])
        XCTAssertEqual(segments.last?.last?.timestamp, 99)
        XCTAssertEqual(segments.last?.last?.sessionID, currentSession)
    }

    func testBatteryMergeIsSortedAndLiveWinsExactTimestampCollision() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        let duplicate = Date(timeIntervalSinceReferenceDate: 200)
        let last = Date(timeIntervalSinceReferenceDate: 300)
        let pmset = [
            ChargeSample(date: duplicate, level: 0.4, onAC: false),
            ChargeSample(date: first, level: 0.3, onAC: false)
        ]
        let live = [
            ChargeSample(date: last, level: 0.6, onAC: true),
            ChargeSample(date: duplicate, level: 0.5, onAC: true)
        ]

        let merged = BatteryHistoryPolicy.merge(pmset: pmset, live: live)

        XCTAssertEqual(merged.map(\.date), [first, duplicate, last])
        XCTAssertEqual(merged[1], live[1])
    }

    func testBatteryHistoryParserRequiresACompleteChargeToken() {
        XCTAssertEqual(
            BatteryInfo.chargeMatch(in: "Using Batt(Charge: 82)")?.pct,
            82
        )
        XCTAssertEqual(
            BatteryInfo.chargeMatch(in: "Using BATT (Charge:68%)")?.pct,
            68
        )
        XCTAssertNil(BatteryInfo.chargeMatch(in: "Using Batt(Charge: 8"))
        XCTAssertNil(BatteryInfo.chargeMatch(in: "Using AC(Charge: 101)"))
    }

    func testBatteryPolicyKeepsNormalSparsePmsetReadingsConnected() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            ChargeSample(date: start, level: 0.8, onAC: false),
            ChargeSample(date: start.addingTimeInterval(60 * 60), level: 0.7, onAC: false)
        ]

        let segments = BatteryHistoryPolicy.segments(
            normalizedSamples: samples,
            start: start,
            end: start.addingTimeInterval(2 * 60 * 60)
        )

        XCTAssertEqual(segments, [samples])
    }

    func testBatteryChartSuppressesBaselineAreaFillAcrossDiscontinuousHistory() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let firstSegment = [
            ChargeSample(date: start, level: 0.8, onAC: false),
            ChargeSample(date: start.addingTimeInterval(60), level: 0.7, onAC: false)
        ]
        let secondSegment = [
            ChargeSample(date: start.addingTimeInterval(2 * 60 * 60), level: 0.6, onAC: true),
            ChargeSample(date: start.addingTimeInterval(2 * 60 * 60 + 60), level: 0.65, onAC: true)
        ]

        XCTAssertTrue(BatteryHistoryRenderPolicy.showsAreaFill(for: [firstSegment]))
        XCTAssertFalse(BatteryHistoryRenderPolicy.showsAreaFill(for: [firstSegment, secondSegment]))
        XCTAssertFalse(BatteryHistoryRenderPolicy.showsAreaFill(for: [[firstSegment[0]]]))
    }

    func testBatteryPolicyDisconnectsStalePmsetHistoryFromCurrentEndpoint() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let source = ChargeSample(date: start, level: 0.8, onAC: false)
        let current = ChargeSample(
            date: start.addingTimeInterval(BatteryHistoryPolicy.maximumContinuousGap + 1),
            level: 0.6,
            onAC: true
        )

        let segments = BatteryHistoryPolicy.segments(
            normalizedSamples: [source, current],
            start: start,
            end: current.date
        )

        XCTAssertEqual(segments, [[source], [current]])
    }

    func testBatteryPolicyConnectsRecentSourceToCurrentEndpoint() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let source = ChargeSample(date: start, level: 0.8, onAC: false)
        let current = ChargeSample(
            date: start.addingTimeInterval(BatteryHistoryPolicy.maximumContinuousGap),
            level: 0.6,
            onAC: true
        )

        let segments = BatteryHistoryPolicy.segments(
            normalizedSamples: [source, current],
            start: start,
            end: current.date
        )

        XCTAssertEqual(segments, [[source, current]])
    }

    func testBatterySegmentationPreservesOwnerNormalizedInput() {
        let first = Date(timeIntervalSinceReferenceDate: 100)
        let second = Date(timeIntervalSinceReferenceDate: 200)
        let normalizedByOwner = [
            ChargeSample(date: first, level: 0.4, onAC: false),
            ChargeSample(date: second, level: 0.5, onAC: true)
        ]

        let segments = BatteryHistoryPolicy.segments(
            normalizedSamples: normalizedByOwner,
            start: first,
            end: second
        )

        XCTAssertEqual(segments.flatMap { $0 }, normalizedByOwner)
    }

    @MainActor
    func testBatteryViewModelPublishesNormalizedChartHistoryAtTheUpdateBoundary() {
        let vm = BatteryViewModel()
        let later = Date(timeIntervalSinceReferenceDate: 200)
        let earlier = Date(timeIntervalSinceReferenceDate: 100)

        vm.recordLiveReading(level: 0.6, onAC: true, at: later)
        vm.recordLiveReading(level: 0.5, onAC: false, at: earlier)

        XCTAssertEqual(vm.chartHistory.map(\.date), [earlier, later])
        XCTAssertEqual(vm.chartHistory, vm.liveHistory)
    }
}
