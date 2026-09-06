import XCTest
@testable import Geraldine

final class GPUHistoryTests: XCTestCase {
    private func reading(_ id: UInt64, _ activity: Double?, off: Bool = false,
                         counter: GPUReading.Counter = .device) -> GPUReading {
        GPUReading(id: id, name: "Same Model", activity: activity, counter: counter, poweredOff: off)
    }

    func testReorderingAndChangingBusiestPreserveDeviceHistories() {
        var history = GPUHistory()
        history.apply([reading(10, 0.8), reading(20, 0.2)], at: 100)
        history.apply([reading(20, 0.7), reading(10, 0.1)], at: 101)
        XCTAssertEqual(history.devices.map(\.id), [10, 20])
        XCTAssertEqual(history.devices[0].samples.map(\.value), [0.8, 0.1])
        XCTAssertEqual(history.devices[1].samples.map(\.value), [0.2, 0.7])
        XCTAssertEqual(history.devices[0].samples.first?.sessionID, history.devices[0].samples.last?.sessionID)
    }

    func testFailedReadIsNotDisconnectionOrZeroAndBreaksChart() {
        var history = GPUHistory()
        history.apply([reading(10, 0.8)], at: 100)
        history.apply(nil, at: 101)
        XCTAssertEqual(history.devices[0].state, .unavailable)
        XCTAssertNil(history.devices[0].activity)
        XCTAssertEqual(history.devices[0].samples.count, 1)
        history.apply([reading(10, 0.2)], at: 102)
        let segments = TimelineChartRendering.segments(
            samples: history.devices[0].samples,
            timeline: TimelineWindow(end: 102, duration: 300), gapThreshold: 4, maximumPointCount: 300)
        XCTAssertEqual(segments.map(\.count), [1, 1])
    }

    func testMissingCounterAndPoweredOffKeepHistoryButNoCurrentReading() {
        for off in [false, true] {
            var history = GPUHistory()
            history.apply([reading(10, 0.8)], at: 100)
            history.apply([reading(10, off ? 0.8 : nil, off: off)], at: 101)
            XCTAssertEqual(history.devices[0].state, off ? .poweredOff : .unavailable)
            XCTAssertNil(history.devices[0].activity)
            XCTAssertEqual(history.devices[0].samples.count, 1)
            history.apply([reading(10, 0)], at: 102)
            XCTAssertEqual(history.devices[0].activity, 0)
            XCTAssertNotEqual(history.devices[0].samples.first?.sessionID, history.devices[0].samples.last?.sessionID)
        }
    }

    func testRemovalAndReplacementDoNotReuseHistoryEvenWithSameName() {
        var history = GPUHistory()
        history.apply([reading(10, 0.8)], at: 100)
        history.apply([], at: 101)
        XCTAssertEqual(history.devices[0].state, .disconnected)
        history.apply([reading(20, 0.1)], at: 102)
        XCTAssertEqual(history.devices.map(\.id), [10, 20])
        XCTAssertEqual(history.devices[1].samples.map(\.value), [0.1])
        let replacementName = history.devices[1].displayName
        history.apply([reading(20, 0.3)], at: 401)
        XCTAssertEqual(history.devices.map(\.id), [20])
        XCTAssertEqual(history.devices[0].displayName, replacementName)
    }

    func testCounterChangeAndSleepGapSplitSegments() {
        var history = GPUHistory()
        history.apply([reading(10, 0.8)], at: 100)
        history.apply([reading(10, 0.2, counter: .activity)], at: 101)
        history.apply([reading(10, 0.3, counter: .activity)], at: 120)
        let segments = TimelineChartRendering.segments(
            samples: history.devices[0].samples,
            timeline: TimelineWindow(end: 120, duration: 300), gapThreshold: 4, maximumPointCount: 300)
        XCTAssertEqual(segments.map(\.count), [1, 1, 1])
    }

    func testExistingLiveWindowAndSampleBoundApplyPerDevice() {
        var history = GPUHistory()
        for i in 0...650 {
            history.apply([reading(10, 0.5)], at: Double(i) / 10)
        }
        XCTAssertEqual(history.devices[0].samples.count, SystemMonitor.maximumLiveHistorySamples)
        history.apply([reading(10, nil)], at: 400)
        XCTAssertTrue(history.devices[0].samples.isEmpty)
        XCTAssertEqual(history.devices[0].state, .unavailable)
    }
    func testCompactSelectionStaysPinnedAcrossLoadChangesAndRemoval() {
        var history = GPUHistory()
        history.apply([reading(10, 0.2), reading(20, 0.8)], at: 100)
        XCTAssertEqual(history.selectedDeviceID, 10)
        history.apply([reading(20, 0.9), reading(10, 0.1)], at: 101)
        XCTAssertEqual(history.selectedDeviceID, 10)
        history.apply([reading(20, 0.9)], at: 402)
        XCTAssertEqual(history.selectedDeviceID, 10)
        XCTAssertNil(history.selectedDevice)
        history.selectDevice(20)
        XCTAssertEqual(history.selectedDevice?.id, 20)
        history.selectDevice(999)
        XCTAssertEqual(history.selectedDeviceID, 20)
    }

}
