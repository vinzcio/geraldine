import XCTest
@testable import Geraldine

/// An update restart must not end a running Keep Awake session or reset Stay
/// Active's place in the current idle stretch.
@MainActor
final class AppUpdateRelaunchKeepAwakeTests: XCTestCase {
    private struct Fixture {
        let controller: KeepAwakeController
        let assertions: AppReviewPowerAssertions
        let cleanup: () -> Void
    }

    private func makeController(
        onBattery: Bool = false,
        simulator: IdleActivitySimulationService? = nil
    ) -> Fixture {
        let suite = "AppUpdateRelaunchKeepAwakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let assertions = AppReviewPowerAssertions()
        let controller = KeepAwakeController(
            defaults: defaults,
            currentPowerSourceIsBattery: { onBattery },
            idleActivitySimulator: simulator ?? IdleActivitySimulationService(
                accessibilityAvailable: { false }, currentIdleDuration: { 0 },
                pulsePoster: { XCTFail("Unexpected activity pulse"); return false }
            ),
            createAssertion: assertions.create,
            releaseAssertion: assertions.release
        )
        return Fixture(controller: controller, assertions: assertions) {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testHandoffCapturesTheRunningSessionOnly() throws {
        let controllerFixture = makeController()
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        XCTAssertNil(controller.relaunchHandoff())

        controller.activate(duration: 2 * 60 * 60)
        let timed = try XCTUnwrap(controller.relaunchHandoff())
        XCTAssertEqual(timed.activeUntil?.timeIntervalSince(timed.activeSince) ?? 0, 2 * 60 * 60, accuracy: 0.01)
        XCTAssertFalse(timed.wasPaused)
        XCTAssertNil(timed.stayActivePulseUptime, "Stay Active is off")

        controller.activate(duration: nil)
        XCTAssertNil(try XCTUnwrap(controller.relaunchHandoff()).activeUntil)

        controller.deactivate()
        XCTAssertNil(controller.relaunchHandoff())
    }

    func testResumeKeepsTheOriginalStartAndEnd() throws {
        let controllerFixture = makeController()
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        let assertions = controllerFixture.assertions
        let now = Date()
        let session = KeepAwakeSessionHandoff(
            activeSince: now.addingTimeInterval(-600), activeUntil: now.addingTimeInterval(1_800),
            wasPaused: false, stayActivePulseUptime: nil, stayActiveLastUserInput: nil
        )

        XCTAssertTrue(controller.resume(session, now: now, sessionIsOnConsole: true))

        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(controller.activeUntil, session.activeUntil)
        XCTAssertEqual(controller.activeDuration ?? 0, 2_400, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(controller.remaining), 1_800, accuracy: 2)
        XCTAssertEqual(assertions.held.count, 2, "System and display sleep are both held again")
        XCTAssertFalse(controller.resume(session, now: now, sessionIsOnConsole: true),
                       "A session that is already running is never replaced")
    }

    func testIndefiniteSessionResumesIndefinitely() {
        let controllerFixture = makeController()
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        let assertions = controllerFixture.assertions
        let now = Date()
        let session = KeepAwakeSessionHandoff(
            activeSince: now.addingTimeInterval(-86_400), activeUntil: nil,
            wasPaused: false, stayActivePulseUptime: nil, stayActiveLastUserInput: nil
        )
        XCTAssertTrue(controller.resume(session, now: now, sessionIsOnConsole: true))
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.activeUntil)
        XCTAssertEqual(controller.statusLine, "On · Indefinitely")
        XCTAssertEqual(assertions.held.count, 2)
    }

    func testSessionThatEndedDuringTheRelaunchStaysOff() {
        let controllerFixture = makeController()
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        let assertions = controllerFixture.assertions
        let now = Date()
        let session = KeepAwakeSessionHandoff(
            activeSince: now.addingTimeInterval(-600), activeUntil: now.addingTimeInterval(0.5),
            wasPaused: false, stayActivePulseUptime: nil, stayActiveLastUserInput: nil
        )
        XCTAssertFalse(controller.resume(session, now: now, sessionIsOnConsole: true))
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(assertions.held.isEmpty)
    }

    func testBatteryPolicyStillAppliesToAResumedSession() {
        let controllerFixture = makeController(onBattery: true)
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        let assertions = controllerFixture.assertions
        controller.deactivateOnBattery = true
        let session = KeepAwakeSessionHandoff(
            activeSince: Date().addingTimeInterval(-60), activeUntil: nil,
            wasPaused: false, stayActivePulseUptime: nil, stayActiveLastUserInput: nil
        )
        XCTAssertFalse(controller.resume(session, sessionIsOnConsole: true))
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.lastError, KeepAwakeController.batteryPolicyRefusalMessage)
        XCTAssertTrue(assertions.held.isEmpty)
    }

    func testPausedSessionStaysPausedOnlyWhileAwayFromTheConsole() {
        let session = KeepAwakeSessionHandoff(
            activeSince: Date().addingTimeInterval(-60), activeUntil: nil,
            wasPaused: true, stayActivePulseUptime: nil, stayActiveLastUserInput: nil
        )

        let awayFixture = makeController()
        defer { awayFixture.cleanup() }
        let away = awayFixture.controller
        let awayAssertions = awayFixture.assertions
        away.pauseWhenScreenLocked = true
        XCTAssertTrue(away.resume(session, sessionIsOnConsole: false))
        XCTAssertTrue(away.isActive)
        XCTAssertTrue(away.isPaused)
        XCTAssertEqual(away.pauseReason, "Screen Locked")
        XCTAssertTrue(awayAssertions.held.isEmpty, "A paused session holds no assertions")

        let backFixture = makeController()
        defer { backFixture.cleanup() }
        let back = backFixture.controller
        let backAssertions = backFixture.assertions
        back.pauseWhenScreenLocked = true
        XCTAssertTrue(back.resume(session, sessionIsOnConsole: true))
        XCTAssertFalse(back.isPaused, "The unlock it waited for already happened")
        XCTAssertEqual(backAssertions.held.count, 2)
    }

    func testStayActiveContinuesPulsingWhenNobodyCameBackDuringTheRelaunch() throws {
        var now: TimeInterval = 10_000
        var lastEvent: TimeInterval = 9_997.5 // The old process's final pulse.
        var posts: [TimeInterval] = []
        let simulator = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { true },
            currentIdleDuration: { now - lastEvent },
            pulsePoster: { posts.append(now); lastEvent = now; return true },
            uptime: { now },
            nextPulseInterval: { 2.2 }
        )
        let controllerFixture = makeController(simulator: simulator)
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        controller.idleActivityDelayMinutes = 1
        controller.simulateIdleActivity = true
        let away = Date().addingTimeInterval(-900)
        let session = KeepAwakeSessionHandoff(
            activeSince: Date().addingTimeInterval(-3_600), activeUntil: nil, wasPaused: false,
            stayActivePulseUptime: 9_997.5, stayActiveLastUserInput: away
        )

        XCTAssertTrue(controller.resume(session, sessionIsOnConsole: true))

        XCTAssertEqual(posts, [10_000], "No fresh one-minute wait after the relaunch")
        XCTAssertEqual(controller.idleActivityPhase, .pulsing)
        XCTAssertEqual(controller.idleActivityLastUserInput, away)
        let handedOn = try XCTUnwrap(controller.relaunchHandoff())
        XCTAssertEqual(handedOn.stayActivePulseUptime, 10_000)
        now += 2.2
        simulator.timerFired()
        XCTAssertEqual(posts.count, 2)
    }

    func testStayActiveWaitsAgainWhenSomeoneCameBackDuringTheRelaunch() {
        let now: TimeInterval = 10_000
        var lastEvent: TimeInterval = 9_999 // Real input after the old process's final pulse.
        let simulator = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { true },
            currentIdleDuration: { now - lastEvent },
            pulsePoster: { XCTFail("Pulsed while the person was back"); lastEvent = now; return true },
            uptime: { now }
        )
        let controllerFixture = makeController(simulator: simulator)
        defer { controllerFixture.cleanup() }
        let controller = controllerFixture.controller
        controller.idleActivityDelayMinutes = 1
        controller.simulateIdleActivity = true
        let session = KeepAwakeSessionHandoff(
            activeSince: Date().addingTimeInterval(-3_600), activeUntil: nil, wasPaused: false,
            stayActivePulseUptime: 9_997.5, stayActiveLastUserInput: nil
        )

        XCTAssertTrue(controller.resume(session, sessionIsOnConsole: true))

        XCTAssertEqual(controller.idleActivityPhase, .waiting)
        XCTAssertNil(controller.relaunchHandoff()?.stayActivePulseUptime)
    }

    func testPulseStampFromAnotherBootIsIgnored() {
        var posts = 0
        let simulator = IdleActivitySimulationService(
            idleDelay: 60,
            accessibilityAvailable: { true },
            currentIdleDuration: { 3 },
            pulsePoster: { posts += 1; return true },
            uptime: { 40 } // Uptime restarted below the old stamp.
        )
        defer { simulator.stop() }

        simulator.start(resumingPulseAt: 9_997.5)

        XCTAssertEqual(posts, 0)
        XCTAssertNil(simulator.pulsingSinceUptime)
    }
}
