import AppKit
import Combine
import XCTest
@testable import Geraldine

@MainActor
final class SystemMonitorDisplaySleepTests: XCTestCase {
    private struct NoHistory: MonitorHistoryStoring {
        func load() -> MonitorHistorySnapshot? { nil }
        func save(_ snapshot: MonitorHistorySnapshot) throws { XCTFail("Unexpected history write") }
    }

    func testAsleepInitializationSkipsInitialRefreshAndPublishesCurrentState() throws {
        let monitor = try makeMonitor(performInitialRefresh: true, readDisplaysAsleep: { true })
        var published: [Bool] = []
        let observation = monitor.$displaysAsleep.sink { published.append($0) }
        defer { observation.cancel() }

        XCTAssertTrue(monitor.displaysAsleep)
        XCTAssertEqual(published, [true], "A new menu observer must receive the current sleep state")
        XCTAssertTrue(monitor.demand.displaysAsleep)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertFalse(monitor.isSamplingScheduled)
        monitor.setDemand(.everything)
        monitor.refresh()
        XCTAssertFalse(monitor.demand.samplesThermal)
        XCTAssertFalse(monitor.demand.samplesGPU)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertNil(monitor.lastThermalSampleAt)
        XCTAssertNil(monitor.lastGPUSampleAt)
        XCTAssertTrue(monitor.memHistory.isEmpty)
    }

    func testStartReconcilesSleepMissedSinceInitializationBeforeSchedulingWork() throws {
        var asleep = false
        let monitor = try makeMonitor(readDisplaysAsleep: { asleep })
        defer { monitor.stop() }
        monitor.setDemand(.everything)

        // No observer exists yet, so only the startup query can see this change.
        asleep = true
        monitor.start()

        XCTAssertTrue(monitor.isRunning)
        XCTAssertTrue(monitor.displaysAsleep)
        XCTAssertFalse(monitor.isSamplingScheduled)
        XCTAssertEqual(monitor.samplingInterval, 1)
        XCTAssertFalse(monitor.demand.samplesThermal)
        XCTAssertFalse(monitor.demand.samplesGPU)
        XCTAssertNil(monitor.lastRefreshAt)
        monitor.setDemand(.everything)
        XCTAssertNil(monitor.lastRefreshAt)
    }

    func testRestartReconcilesSleepNotificationMissedWhileStopped() throws {
        var asleep = false
        let center = NotificationCenter()
        let monitor = try makeMonitor(readDisplaysAsleep: { asleep }, center: center)
        defer { monitor.stop() }
        var published: [Bool] = []
        let observation = monitor.$displaysAsleep.sink { published.append($0) }
        defer { observation.cancel() }

        monitor.start()
        XCTAssertTrue(monitor.isSamplingScheduled)
        monitor.stop()
        XCTAssertFalse(monitor.isSamplingScheduled)
        asleep = true
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertFalse(monitor.displaysAsleep)

        monitor.start()

        XCTAssertTrue(monitor.displaysAsleep)
        XCTAssertTrue(monitor.demand.displaysAsleep)
        XCTAssertFalse(monitor.isSamplingScheduled)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertEqual(published, [false, true])
    }

    func testRestartReconcilesMissedWakeAndRefreshesOnceAtOriginalCadence() throws {
        var asleep = true
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let center = NotificationCenter()
        let monitor = try makeMonitor(readDisplaysAsleep: { asleep }, center: center)
        defer { monitor.stop() }
        monitor.start()
        monitor.stop()
        asleep = false
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(monitor.displaysAsleep)
        XCTAssertTrue(monitor.memHistory.isEmpty)

        monitor.start()

        XCTAssertFalse(monitor.displaysAsleep)
        XCTAssertFalse(monitor.demand.displaysAsleep)
        XCTAssertTrue(monitor.isSamplingScheduled)
        XCTAssertEqual(monitor.samplingInterval, 1)
        XCTAssertEqual(monitor.lastRefreshAt, date)
        XCTAssertEqual(monitor.memHistory.count, 1, "A missed wake should refresh exactly once")
    }

    func testWakeNotificationRecoversFromAsleepStartupAndSleepStopsWorkAgain() async throws {
        let center = NotificationCenter()
        var displayReads = 0
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let monitor = try makeMonitor(readDisplaysAsleep: {
            displayReads += 1
            return true
        }, center: center)
        defer { monitor.stop() }
        var published: [Bool] = []
        let observation = monitor.$displaysAsleep.sink { published.append($0) }
        defer { observation.cancel() }
        monitor.start()
        XCTAssertFalse(monitor.isSamplingScheduled)
        XCTAssertTrue(monitor.memHistory.isEmpty)

        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await settle { monitor.lastRefreshAt != nil }

        XCTAssertFalse(monitor.displaysAsleep)
        XCTAssertTrue(monitor.isSamplingScheduled)
        XCTAssertEqual(monitor.lastRefreshAt, date)
        XCTAssertEqual(monitor.samplingInterval, 1)
        XCTAssertEqual(monitor.memHistory.count, 1, "Wake should refresh exactly once")
        XCTAssertEqual(displayReads, 2, "Notifications should retain their existing wake semantics")

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await settle { monitor.displaysAsleep }

        XCTAssertFalse(monitor.isSamplingScheduled)
        monitor.refresh()
        XCTAssertEqual(monitor.memHistory.count, 1, "Sleep must prevent further sampling")
        XCTAssertEqual(published, [true, false, true])
    }

    func testUnknownInitialStateKeepsInitialRefreshAndTimerAvailable() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let monitor = try makeMonitor(performInitialRefresh: true, readDisplaysAsleep: { nil })
        defer { monitor.stop() }

        XCTAssertFalse(monitor.displaysAsleep)
        XCTAssertEqual(monitor.lastRefreshAt, date)
        monitor.start()
        XCTAssertTrue(monitor.isSamplingScheduled)
        XCTAssertFalse(monitor.demand.displaysAsleep)
    }

    func testUnknownRestartStateDoesNotRetainAnUnverifiedPause() throws {
        var asleep: Bool? = true
        let monitor = try makeMonitor(readDisplaysAsleep: { asleep })
        defer { monitor.stop() }
        monitor.start()
        monitor.stop()
        asleep = nil

        monitor.start()

        XCTAssertFalse(monitor.displaysAsleep)
        XCTAssertTrue(monitor.isSamplingScheduled)
        XCTAssertEqual(monitor.lastRefreshAt, Date(timeIntervalSinceReferenceDate: 100))
    }

    private func makeMonitor(
        performInitialRefresh: Bool = false,
        readDisplaysAsleep: @escaping () -> Bool?,
        center: NotificationCenter = NotificationCenter()
    ) throws -> SystemMonitor {
        let suite = "SystemMonitorDisplaySleepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SystemMonitor(
            defaults: defaults, historyStore: NoHistory(),
            now: { Date(timeIntervalSinceReferenceDate: 100) },
            performInitialRefresh: performInitialRefresh,
            readDisplaysAsleep: readDisplaysAsleep, screenSleepNotificationCenter: center
        )
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "The display sleep notification did not finish")
    }
}
