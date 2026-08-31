import XCTest
@testable import Geraldine

@MainActor
final class IdleActivitySimulationServiceTests: XCTestCase {
    func testMainRunLoopTimerCallbackCannotRunAgainstRestartedSession() {
        var sessionID = 1
        var pulsedSessionIDs: [Int] = []

        IdleActivitySimulationService.deliverMainRunLoopTimerCallback {
            pulsedSessionIDs.append(sessionID)
        }
        sessionID = 2

        XCTAssertEqual(pulsedSessionIDs, [1])
    }

    func testInitialPulseFailureIsTerminalWithoutAnAutomaticRetry() {
        var attempts = 0
        var snapshots: [IdleActivitySimulationSnapshot] = []
        let service = makeService {
            attempts += 1
            return false
        }
        service.onSnapshotChange = { snapshots.append($0) }
        defer { service.stop() }

        service.start()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(snapshots.last?.phase, .failed)
        XCTAssertEqual(snapshots.last?.errorMessage, "Could Not Post Input Events")
        XCTAssertFalse(service.hasScheduledTimer)

        service.performPulseCycle()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(snapshots.last?.phase, .failed)
        XCTAssertFalse(service.hasScheduledTimer)
    }

    func testExplicitRestartCanRecoverAfterPulseFailure() {
        var shouldSucceed = false
        var attempts = 0
        var snapshots: [IdleActivitySimulationSnapshot] = []
        let service = makeService {
            attempts += 1
            return shouldSucceed
        }
        service.onSnapshotChange = { snapshots.append($0) }
        defer { service.stop() }

        service.start()
        XCTAssertEqual(snapshots.last?.phase, .failed)
        XCTAssertFalse(service.hasScheduledTimer)

        shouldSucceed = true
        service.start()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(snapshots.last?.phase, .pulsing)
        XCTAssertNil(snapshots.last?.errorMessage)
        XCTAssertNotNil(snapshots.last?.lastPulse)
        XCTAssertTrue(service.hasScheduledTimer)
    }

    func testSuccessfulInitialPulsePublishesAndSchedulesOneNextCycle() {
        var attempts = 0
        var snapshots: [IdleActivitySimulationSnapshot] = []
        let service = makeService {
            attempts += 1
            return true
        }
        service.onSnapshotChange = { snapshots.append($0) }
        defer { service.stop() }

        service.start()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(snapshots.last?.phase, .pulsing)
        XCTAssertNotNil(snapshots.last?.lastPulse)
        XCTAssertNil(snapshots.last?.errorMessage)
        XCTAssertTrue(service.hasScheduledTimer)
    }

    func testAlreadyPulsingCycleDoesNotRescheduleAfterFailure() {
        var shouldSucceed = true
        var attempts = 0
        var snapshots: [IdleActivitySimulationSnapshot] = []
        let service = makeService {
            attempts += 1
            return shouldSucceed
        }
        service.onSnapshotChange = { snapshots.append($0) }
        defer { service.stop() }

        service.start()
        XCTAssertTrue(service.hasScheduledTimer)

        shouldSucceed = false
        service.performPulseCycle()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(snapshots.last?.phase, .failed)
        XCTAssertEqual(snapshots.last?.errorMessage, "Could Not Post Input Events")
        XCTAssertFalse(service.hasScheduledTimer)
    }

    func testManualPulseCycleIsInertUnlessEnabledAndPulsing() {
        var attempts = 0
        var snapshots: [IdleActivitySimulationSnapshot] = []
        let service = makeService(currentIdleDuration: 0) {
            attempts += 1
            return true
        }
        service.onSnapshotChange = { snapshots.append($0) }
        defer { service.stop() }

        service.performPulseCycle()
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(service.hasScheduledTimer)

        service.start()
        XCTAssertEqual(snapshots.last?.phase, .waiting)
        XCTAssertTrue(service.hasScheduledTimer)

        service.performPulseCycle()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(snapshots.last?.phase, .waiting)
        XCTAssertTrue(service.hasScheduledTimer)

        service.stop()
        service.performPulseCycle()
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(snapshots.last?.phase, .off)
        XCTAssertFalse(service.hasScheduledTimer)
    }

    private func makeService(
        currentIdleDuration: TimeInterval = 10,
        pulsePoster: @escaping () -> Bool
    ) -> IdleActivitySimulationService {
        IdleActivitySimulationService(
            idleDelay: 1,
            pulseInterval: 30,
            accessibilityAvailable: { true },
            currentIdleDuration: { currentIdleDuration },
            pulsePoster: pulsePoster
        )
    }
}
