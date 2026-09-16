import XCTest
import CoreGraphics
@testable import Geraldine

@MainActor
final class IdleActivitySimulationServiceTests: XCTestCase {
    func testKeyboardPulseIsPairedControlAndNeverAnArrowKey() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let events = try XCTUnwrap(IdleActivitySimulationService.makeControlKeyPulse(source: source))
        // macOS represents a modifier press/release as flagsChanged events.
        XCTAssertEqual(events.down.type, .flagsChanged)
        XCTAssertEqual(events.up.type, .flagsChanged)
        XCTAssertTrue(events.down.flags.contains(.maskControl))
        XCTAssertFalse(events.up.flags.contains(.maskControl))
        for event in [events.down, events.up] {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            XCTAssertEqual(key, 59)
            XCTAssertFalse((123...126).contains(key))
        }
    }

    func testDynamicCadenceKeepsEveryRollingMinuteBetween24And30ActiveSeconds() throws {
        // Count distinct one-second intervals, not the number of events inside
        // each nudge. Exercise the real service's scheduling and input detection.
        for intervals in [[2.0], [2.4], [2.0, 2.3, 2.1, 2.4, 2.2]] {
            for lateness in [0.0, 0.05, 0.1] {
                var intervalIndex = 0
                var selectedInterval = 0.0
                var now: TimeInterval = 0
                var lastPost: TimeInterval = -60
                var posts: [TimeInterval] = []
                let service = IdleActivitySimulationService(
                    idleDelay: 60,
                    accessibilityAvailable: { true },
                    currentIdleDuration: { now - lastPost },
                    pulsePoster: { posts.append(now); lastPost = now; return true },
                    uptime: { now },
                    nextPulseInterval: {
                        selectedInterval = intervals[intervalIndex % intervals.count]
                        intervalIndex += 1
                        return selectedInterval
                    }
                )
                defer { service.stop() }
                service.start()
                while now < 180 {
                    let delay = try XCTUnwrap(service.nextFireDate).timeIntervalSinceNow
                    XCTAssertEqual(delay, selectedInterval, accuracy: 0.1)
                    now += selectedInterval + lateness
                    service.timerFired()
                }
                for start in stride(from: 0.0, through: 120.0, by: 0.5) {
                    let activeSeconds = Set(posts.filter { $0 >= start && $0 < start + 60 }
                        .map { Int(floor($0 - start)) })
                    XCTAssertGreaterThanOrEqual(activeSeconds.count, 24,
                        "Window starting at \(start), callback lateness \(lateness)")
                    XCTAssertLessThanOrEqual(activeSeconds.count, 30)
                }
            }
        }
    }

    func testRealInputRestartsIdleDelayAndStopPreventsFurtherPulses() throws {
        var now: TimeInterval = 0
        var lastInput: TimeInterval = -60
        var posts = 0
        let service = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { true },
            currentIdleDuration: { now - lastInput },
            pulsePoster: { posts += 1; lastInput = now; return true },
            uptime: { now }
        )
        defer { service.stop() }
        service.start()
        XCTAssertEqual(posts, 1)
        now = 2
        lastInput = 1 // Real input since the previous generated pulse.
        service.timerFired()
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(try XCTUnwrap(service.nextFireDate).timeIntervalSinceNow, 59, accuracy: 0.1)
        now = 61
        service.timerFired()
        XCTAssertEqual(posts, 2)
        service.stop()
        now = 63
        service.timerFired()
        XCTAssertEqual(posts, 2)
        XCTAssertFalse(service.hasScheduledTimer)
    }

    func testPermissionLossStopsCadence() {
        var allowed = true
        var now: TimeInterval = 0
        var lastPost: TimeInterval = -60
        var posts = 0
        let service = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { allowed },
            currentIdleDuration: { now - lastPost },
            pulsePoster: { posts += 1; lastPost = now; return true },
            uptime: { now }
        )
        defer { service.stop() }
        service.start()
        allowed = false
        now = 2
        service.timerFired()
        XCTAssertEqual(posts, 1)
        XCTAssertFalse(service.hasScheduledTimer)
    }

    func testRealRunLoopProduces40To50PercentActivityInOneMinute() async {
        let start = ProcessInfo.processInfo.systemUptime
        var lastPost = start - 60
        var posts: [TimeInterval] = []
        let service = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { true },
            currentIdleDuration: { ProcessInfo.processInfo.systemUptime - lastPost },
            pulsePoster: {
                lastPost = ProcessInfo.processInfo.systemUptime
                posts.append(lastPost - start)
                return true
            }
        )
        defer { service.stop() }
        service.start()
        try? await Task.sleep(for: .seconds(60))
        service.stop()
        let activeSeconds = Set(posts.filter { $0 < 60 }.map { Int(floor($0)) })
        XCTAssertGreaterThanOrEqual(activeSeconds.count, 24)
        XCTAssertLessThanOrEqual(activeSeconds.count, 30)
        XCTAssertGreaterThan(Set(zip(posts, posts.dropFirst()).map { Int((($1 - $0) * 100).rounded()) }).count, 1)
        print("Stay Active real timer: \(activeSeconds.count)/60 seconds contained a successful pulse")
    }

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
            accessibilityAvailable: { true },
            currentIdleDuration: { currentIdleDuration },
            pulsePoster: pulsePoster
        )
    }
}
