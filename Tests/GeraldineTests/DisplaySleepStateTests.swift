import CoreGraphics
import XCTest
@testable import Geraldine

final class DisplaySleepStateTests: XCTestCase {
    func testQueriesExactOnlineCountAndRequiresEveryDisplayToBeAsleep() {
        let ids: [CGDirectDisplayID] = [2, 7, 11]
        var capacities: [UInt32] = []
        var checked: [CGDirectDisplayID] = []
        let asleep = DisplaySleepState.read(onlineDisplays: { capacity, displays, count in
            capacities.append(capacity)
            count.pointee = UInt32(ids.count)
            if let displays {
                XCTAssertEqual(capacity, UInt32(ids.count))
                for (index, id) in ids.enumerated() { displays[index] = id }
            }
            return .success
        }, isAsleep: { id in
            checked.append(id)
            return true
        })

        XCTAssertEqual(asleep, true)
        XCTAssertEqual(capacities, [0, 3])
        XCTAssertEqual(checked, ids)
    }

    func testOneAwakeOnlineDisplayKeepsMonitoringAvailable() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 2, ids: [2, 7]),
            isAsleep: { $0 == 2 }
        )
        XCTAssertEqual(asleep, false)
    }

    func testDisconnectedDisplaysDoNotLeaveUnusedIDsInTheSleepDecision() {
        var checked: [CGDirectDisplayID] = []
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 3, ids: [7]),
            isAsleep: { id in
                checked.append(id)
                return id == 7
            }
        )
        XCTAssertEqual(asleep, true)
        XCTAssertEqual(checked, [7])
    }

    func testFailedCountIsUnknown() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 2, ids: [2, 7], countError: .failure),
            isAsleep: unexpectedSleepRead
        )
        XCTAssertNil(asleep)
    }

    func testFailedListIsUnknown() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 2, ids: [2, 7], listError: .failure),
            isAsleep: unexpectedSleepRead
        )
        XCTAssertNil(asleep)
    }

    func testNoOnlineDisplaysIsUnknownInsteadOfVacuouslyAsleep() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 0, ids: []),
            isAsleep: unexpectedSleepRead
        )
        XCTAssertNil(asleep)
    }

    func testAllDisplaysDisconnectingBeforeListIsUnknown() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 2, ids: []),
            isAsleep: unexpectedSleepRead
        )
        XCTAssertNil(asleep)
    }

    func testCountGrowingBeyondTheQueriedCapacityDoesNotPauseOnAPartialList() {
        let asleep = DisplaySleepState.read(
            onlineDisplays: query(count: 1, ids: [2], returnedCount: 2),
            isAsleep: unexpectedSleepRead
        )
        XCTAssertNil(asleep)
    }

    private func query(
        count: UInt32,
        ids: [CGDirectDisplayID],
        returnedCount: UInt32? = nil,
        countError: CGError = .success,
        listError: CGError = .success
    ) -> (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError {
        { capacity, displays, resultCount in
            guard let displays else {
                resultCount.pointee = count
                return countError
            }
            for (index, id) in ids.prefix(Int(capacity)).enumerated() { displays[index] = id }
            resultCount.pointee = returnedCount ?? UInt32(ids.count)
            return listError
        }
    }

    private func unexpectedSleepRead(_ id: CGDirectDisplayID) -> Bool {
        XCTFail("An unknown display list must not query sleep for display \(id)")
        return true
    }
}
