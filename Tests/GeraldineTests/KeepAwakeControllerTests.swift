import XCTest
@testable import Geraldine

@MainActor
final class KeepAwakeControllerTests: XCTestCase {
    func testLegacyIdleActivityDelaysAreRepairedToSupportedOptions() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cases = [
            (stored: Int.min, expected: 1),
            (stored: 1, expected: 1),
            (stored: 3, expected: 2),
            (stored: 10, expected: 5),
            (stored: 120, expected: 5),
            (stored: Int.max, expected: 5)
        ]

        for item in cases {
            defaults.set(item.stored, forKey: "keepAwake.idleActivityDelayMinutes")
            do {
                let controller = KeepAwakeController(defaults: defaults)
                defer { controller.shutdown() }

                XCTAssertEqual(controller.idleActivityDelayMinutes, item.expected)
                XCTAssertEqual(
                    defaults.integer(forKey: "keepAwake.idleActivityDelayMinutes"),
                    item.expected
                )
            }
        }
    }

    func testActiveDurationIsOwnedByRunningSessionRatherThanNextDefault() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = KeepAwakeController(defaults: defaults)
        defer { controller.shutdown() }

        controller.activate(duration: 4 * 60)

        XCTAssertEqual(controller.activeDuration ?? 0, 4 * 60, accuracy: 0.01)

        controller.defaultDuration = .twelveHours
        XCTAssertEqual(controller.activeDuration ?? 0, 4 * 60, accuracy: 0.01)

        controller.extend(by: 60)
        XCTAssertEqual(controller.activeDuration ?? 0, 5 * 60, accuracy: 0.01)
    }

    func testSelectingDurationRestartsTheCurrentSessionAtThatDuration() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = KeepAwakeController(defaults: defaults)
        defer { controller.shutdown() }

        controller.activate(option: .indefinitely)
        controller.selectDuration(.twelveHours)

        XCTAssertEqual(controller.defaultDuration, .twelveHours)
        XCTAssertEqual(controller.activeDuration ?? 0, 12 * 60 * 60, accuracy: 0.01)
        XCTAssertNotNil(controller.remaining)

        controller.selectDuration(.indefinitely)

        XCTAssertEqual(controller.defaultDuration, .indefinitely)
        XCTAssertNil(controller.activeDuration)
        XCTAssertNil(controller.remaining)
        XCTAssertTrue(controller.isActive)
    }

    func testURLDurationOverrideReportsTheMatchingActiveHoneycombOption() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = KeepAwakeController(defaults: defaults)
        defer { controller.shutdown() }

        controller.defaultDuration = .oneHour
        XCTAssertTrue(controller.handle(url: URL(string: "geraldine:activate?minutes=10")!))

        XCTAssertEqual(controller.activeDurationOption, .tenMinutes)
        XCTAssertEqual(controller.defaultDuration, .oneHour)

        XCTAssertTrue(controller.handle(url: URL(string: "geraldine:activate?minutes=15")!))
        XCTAssertNil(controller.activeDurationOption)
        XCTAssertEqual(controller.defaultDuration, .oneHour)
    }

    func testBatteryPolicyAllowsACAndAllowsBatteryWhenDisabled() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var onBattery = false
        let controller = KeepAwakeController(
            defaults: defaults,
            currentPowerSourceIsBattery: { onBattery }
        )
        defer { controller.shutdown() }

        controller.deactivateOnBattery = true
        controller.activate(duration: 60)
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.lastError)

        controller.deactivate()
        controller.deactivateOnBattery = false
        onBattery = true
        controller.activate(duration: 60)
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.lastError)
    }

    func testBatteryPolicyBlocksEveryActivationSurfaceButKeepsURLsRecognized() {
        func runBlockedCase(
            _ name: String,
            recognized: Bool? = nil,
            action: (KeepAwakeController) -> Bool?
        ) {
            let suiteName = "KeepAwakeControllerTests.\(name).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.set(true, forKey: "keepAwake.deactivateOnBattery")
            let controller = KeepAwakeController(
                defaults: defaults,
                currentPowerSourceIsBattery: { true }
            )
            defer {
                controller.shutdown()
                defaults.removePersistentDomain(forName: suiteName)
            }

            let result = action(controller)
            if let recognized {
                XCTAssertEqual(result, Optional(recognized), name)
            } else {
                XCTAssertNil(result, name)
            }
            XCTAssertFalse(controller.isActive, name)
            XCTAssertEqual(controller.statusLine, "Off", name)
            XCTAssertNil(controller.activeUntil, name)
            XCTAssertNil(controller.remaining, name)
            XCTAssertEqual(
                controller.lastError,
                KeepAwakeController.batteryPolicyRefusalMessage,
                name
            )
        }

        runBlockedCase("direct duration") { controller in
            controller.activate(duration: 60)
            return nil
        }
        runBlockedCase("default duration") { controller in
            controller.activateDefault()
            return nil
        }
        runBlockedCase("duration option") { controller in
            controller.activate(option: .tenMinutes)
            return nil
        }
        runBlockedCase("inactive toggle") { controller in
            controller.toggle()
            return nil
        }
        runBlockedCase("URL activate", recognized: true) { controller in
            controller.handle(url: URL(string: "geraldine:activate?minutes=10")!)
        }
        runBlockedCase("URL toggle", recognized: true) { controller in
            controller.handle(url: URL(string: "geraldine:toggle?minutes=10")!)
        }
    }

    func testBatteryPolicyEndsAReplacementSessionAndLaterAllowedActivationRecovers() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "keepAwake.deactivateOnBattery")
        var onBattery = false
        let controller = KeepAwakeController(
            defaults: defaults,
            currentPowerSourceIsBattery: { onBattery }
        )
        defer { controller.shutdown() }

        controller.activate(duration: 60)
        XCTAssertTrue(controller.isActive)

        onBattery = true
        controller.activate(duration: 120)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.activeUntil)
        XCTAssertNil(controller.remaining)
        XCTAssertEqual(controller.lastError, KeepAwakeController.batteryPolicyRefusalMessage)

        onBattery = false
        controller.activate(duration: 120)
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.lastError)
    }

    func testEnablingBatteryPolicyStillDeactivatesAnExistingBatterySession() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var onBattery = false
        let controller = KeepAwakeController(
            defaults: defaults,
            currentPowerSourceIsBattery: { onBattery }
        )
        defer { controller.shutdown() }

        controller.activate(duration: 60)
        XCTAssertTrue(controller.isActive)

        onBattery = true
        controller.deactivateOnBattery = true
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.lastError)
    }

    func testStaleExpirationCannotDeactivateAReplacementSession() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = KeepAwakeController(defaults: defaults)
        defer { controller.shutdown() }

        controller.activate(duration: 60)
        let replacedSessionToken = controller.expirationSessionToken

        controller.activate(duration: 120)
        let replacementSessionToken = controller.expirationSessionToken
        XCTAssertNotEqual(replacedSessionToken, replacementSessionToken)

        controller.expireSession(ifCurrent: replacedSessionToken)

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.activeDuration ?? 0, 120, accuracy: 0.01)

        controller.expireSession(ifCurrent: replacementSessionToken)
        XCTAssertFalse(controller.isActive)
    }

    func testStaleExpirationCannotClearABatteryPolicyRefusal() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "keepAwake.deactivateOnBattery")
        var onBattery = false
        let controller = KeepAwakeController(
            defaults: defaults,
            currentPowerSourceIsBattery: { onBattery }
        )
        defer { controller.shutdown() }

        controller.activate(duration: 60)
        let refusedSessionToken = controller.expirationSessionToken

        onBattery = true
        controller.activate(duration: 120)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.lastError, KeepAwakeController.batteryPolicyRefusalMessage)

        controller.expireSession(ifCurrent: refusedSessionToken)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(controller.lastError, KeepAwakeController.batteryPolicyRefusalMessage)
    }

    func testIdleActivitySnapshotsPublishSynchronouslyInSourceOrder() {
        let suiteName = "KeepAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var pulseSucceeds = true
        let simulator = IdleActivitySimulationService(
            idleDelay: 1,
            accessibilityAvailable: { true },
            currentIdleDuration: { 10 },
            pulsePoster: { pulseSucceeds }
        )
        let controller = KeepAwakeController(
            defaults: defaults,
            idleActivitySimulator: simulator
        )
        defer { controller.shutdown() }

        simulator.start(idleDelay: 1)

        XCTAssertEqual(controller.idleActivityPhase, .pulsing)
        XCTAssertNotNil(controller.idleActivityLastPulse)
        XCTAssertNil(controller.idleActivityError)

        pulseSucceeds = false
        simulator.performPulseCycle()

        XCTAssertEqual(controller.idleActivityPhase, .failed)
        XCTAssertEqual(controller.idleActivityError, "Could Not Post Input Events")
    }

    func testTimeMarkerLabelsPreserveHalfMinuteQuarterPoints() {
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 0), "0s")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 1), "1s")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 2.5 * 60), "2:30")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 7.5 * 60), "7:30")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 15 * 60), "15m")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 3 * 60 * 60), "3:00")
    }
}
