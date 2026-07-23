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

    func testTimeMarkerLabelsPreserveHalfMinuteQuarterPoints() {
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 0), "0s")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 1), "1s")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 2.5 * 60), "2:30")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 7.5 * 60), "7:30")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 15 * 60), "15m")
        XCTAssertEqual(KeepAwakeTimeMarkerFormatter.string(seconds: 3 * 60 * 60), "3:00")
    }
}
