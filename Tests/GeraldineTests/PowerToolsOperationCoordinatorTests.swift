import Dispatch
import Foundation
import XCTest
@testable import Geraldine

private final class PowerToolsEffectProbe: @unchecked Sendable {
    let effectEntered: XCTestExpectation
    let mainActorRan: XCTestExpectation
    let releaseEffect = DispatchSemaphore(value: 0)

    init(testCase: XCTestCase) {
        effectEntered = testCase.expectation(description: "Detached effect entered")
        mainActorRan = testCase.expectation(description: "Main actor remained responsive")
    }
}

final class PowerToolsOperationCoordinatorTests: XCTestCase {
    func testBeginPublishesExactActionAndRejectsOverlap() {
        var coordinator = PowerToolsOperationCoordinator()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let ownership = coordinator.begin(actionID: "copyHash", identifier: firstID)

        XCTAssertEqual(ownership?.identifier, firstID)
        XCTAssertEqual(ownership?.actionID, "copyHash")
        XCTAssertEqual(coordinator.runningActionID, "copyHash")
        XCTAssertNil(coordinator.latestResult)
        XCTAssertNil(coordinator.begin(actionID: "emptyTrash"))
        XCTAssertEqual(coordinator.runningActionID, "copyHash")
    }

    func testOwningCompletionPublishesResultAndReturnsIdle() {
        var coordinator = PowerToolsOperationCoordinator()
        let ownership = coordinator.begin(actionID: "copyTo")!
        let result = PowerToolResult.warning("Copied 1 item; 1 failed.")

        XCTAssertTrue(coordinator.finish(ownership, result: result))
        XCTAssertNil(coordinator.runningActionID)
        XCTAssertEqual(coordinator.latestResult, result)
        XCTAssertEqual(coordinator.latestResultOwnership, ownership)
    }

    func testStaleCompletionCannotReplaceNewerOwnershipOrResult() {
        var coordinator = PowerToolsOperationCoordinator()
        let stale = coordinator.begin(
            actionID: "copyHash",
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )!
        coordinator.invalidate()
        let current = coordinator.begin(
            actionID: "emptyTrash",
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )!

        XCTAssertFalse(coordinator.finish(stale, result: .failure("stale")))
        XCTAssertEqual(coordinator.runningActionID, "emptyTrash")
        XCTAssertNil(coordinator.latestResult)

        let currentResult = PowerToolResult.success("Emptied 2 Trash items.")
        XCTAssertTrue(coordinator.finish(current, result: currentResult))
        XCTAssertFalse(coordinator.finish(stale, result: .failure("late stale")))
        XCTAssertNil(coordinator.runningActionID)
        XCTAssertEqual(coordinator.latestResult, currentResult)
        XCTAssertEqual(coordinator.latestResultOwnership, current)
    }

    func testClearingResultDoesNotOrphanActiveOwnership() {
        var coordinator = PowerToolsOperationCoordinator()
        let displayedOwnership = coordinator.begin(actionID: "copyHash")!
        let displayedResult = PowerToolResult.success("Copied SHA-256 for 1 file.")
        XCTAssertTrue(coordinator.finish(displayedOwnership, result: displayedResult))
        XCTAssertEqual(coordinator.latestResult, displayedResult)
        XCTAssertEqual(coordinator.latestResultOwnership, displayedOwnership)

        let ownership = coordinator.begin(actionID: "moveTo")!
        XCTAssertNil(coordinator.latestResult)
        XCTAssertNil(coordinator.latestResultOwnership)

        coordinator.clearResult()

        XCTAssertEqual(coordinator.ownership, ownership)
        XCTAssertEqual(coordinator.runningActionID, "moveTo")
        XCTAssertNil(coordinator.latestResult)
        XCTAssertTrue(coordinator.finish(ownership, result: .success("Moved 1 item.")))
    }

    func testOlderSameActionTokenCannotMatchNewerSuccess() {
        var coordinator = PowerToolsOperationCoordinator()
        let older = coordinator.begin(
            actionID: "copyHash",
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )!
        XCTAssertTrue(coordinator.finish(older, result: .success("Older success")))

        let newer = coordinator.begin(
            actionID: "copyHash",
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )!
        let newerResult = PowerToolResult.success("Newer success")
        XCTAssertTrue(coordinator.finish(newer, result: newerResult))

        XCTAssertFalse(coordinator.isLatestResult(ownedBy: older))
        XCTAssertEqual(coordinator.latestResult, newerResult)
        XCTAssertEqual(coordinator.latestResultOwnership, newer)

        XCTAssertTrue(coordinator.isLatestResult(ownedBy: newer))
        XCTAssertEqual(coordinator.latestResult, newerResult)
        XCTAssertEqual(coordinator.latestResultOwnership, newer)
    }

    @MainActor
    func testDetachedRunnerDoesNotBlockMainActor() async {
        let probe = PowerToolsEffectProbe(testCase: self)
        let watchdog = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            probe.releaseEffect.signal()
        }

        let operation = Task {
            await PowerToolsEffectRunner.run {
                let ranOnMainThread = Thread.isMainThread
                probe.effectEntered.fulfill()
                probe.releaseEffect.wait()
                return ranOnMainThread
            }
        }

        await fulfillment(of: [probe.effectEntered], timeout: 2)
        Task { @MainActor in
            probe.mainActorRan.fulfill()
        }
        await fulfillment(of: [probe.mainActorRan], timeout: 2)
        probe.releaseEffect.signal()

        let ranOnMainThread = await operation.value
        watchdog.cancel()
        await watchdog.value
        XCTAssertFalse(ranOnMainThread)
    }
}
