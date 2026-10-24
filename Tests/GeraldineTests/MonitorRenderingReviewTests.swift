import XCTest
import GeraldineControl
@testable import Geraldine

@MainActor
final class MonitorRenderingReviewTests: XCTestCase {
    private struct NoHistory: MonitorHistoryStoring {
        func load() -> MonitorHistorySnapshot? { nil }
        func save(_ snapshot: MonitorHistorySnapshot) throws { XCTFail("Unexpected history write") }
    }

    func testDemandReconciliationReadsCommittedLayoutAndNewBatteryValue() async throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    performInitialRefresh: false, readDisplaysAsleep: { false })
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.replaceItems([WidgetItem(.cpu, .small), WidgetItem(.gpu, .small), WidgetItem(.temperature, .small)])
        var reconciliations = 0
        let observation = MonitorDemandObservation(layout: layout, monitor: monitor) {
            reconciliations += 1
            let metric = layout.menuBarKind(hasBattery: monitor.hasBattery)
            monitor.setDemand(MonitorDemand(showsThermal: metric == .temperature, showsGPU: metric == .gpu))
        }
        layout.moveToFront(.metric(.gpu))
        layout.setShown(.metric(.cpu), false)
        await settle { reconciliations == 1 }
        XCTAssertTrue(monitor.demand.showsGPU)
        XCTAssertFalse(monitor.demand.showsThermal)
        layout.moveToFront(.metric(.temperature))
        await settle { reconciliations == 2 }
        XCTAssertTrue(monitor.demand.showsThermal)
        XCTAssertFalse(monitor.demand.showsGPU)
        layout.replaceItems([WidgetItem(.battery, .small), WidgetItem(.gpu, .small)])
        await settle { reconciliations == 3 }
        XCTAssertTrue(monitor.demand.showsGPU)
        monitor.hasBattery = true
        await settle { reconciliations == 4 }
        XCTAssertFalse(monitor.demand.showsGPU)
        XCTAssertFalse(monitor.demand.showsThermal)
        XCTAssertNil(monitor.lastRefreshAt, "Demand changes must not refresh a stopped monitor")
        XCTAssertTrue(monitor.memHistory.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testSelectedThermalCadenceDoesNotCreateFalseChartGaps() throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    now: { Date(timeIntervalSinceReferenceDate: 100) },
                                    performInitialRefresh: false, readDisplaysAsleep: { false })
        let interval = monitor.samplingInterval
        XCTAssertEqual(interval, 1)
        for index in 0..<10 {
            var reading = Thermal.Reading.empty
            reading.cpu = 50 + Double(index)
            monitor.applyThermal(reading, sampledAt: Date(timeIntervalSinceReferenceDate: 100 + Double(index) * interval))
        }
        let segments = TimelineChartRendering.segments(
            samples: monitor.thermalHistory, timeline: TimelineWindow(end: 100 + 9 * interval, duration: 60),
            gapThreshold: SystemMonitor.chartSampleGapThreshold, maximumPointCount: 60
        )
        XCTAssertEqual(segments.map(\.count), [10])
    }

    func testDragCommitReconcilesDemandAfterStagedReconciliationHasFinished() async throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    performInitialRefresh: false, readDisplaysAsleep: { false })
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.replaceItems([WidgetItem(.temperature, .small), WidgetItem(.gpu, .small)])
        monitor.setDemand(MonitorDemand(showsThermal: true))
        var reconciliations = 0
        let observation = MonitorDemandObservation(layout: layout, monitor: monitor) {
            reconciliations += 1
            let metric = layout.menuBarKind(hasBattery: monitor.hasBattery)
            monitor.setDemand(MonitorDemand(showsThermal: metric == .temperature, showsGPU: metric == .gpu))
        }

        layout.stageMove(.metric(.gpu), toIndexOf: .metric(.temperature))
        await settle { reconciliations == 1 }
        XCTAssertEqual(layout.visibleItems(hasBattery: false, calendarInPopover: false).first?.kind, .metric(.gpu))
        XCTAssertEqual(layout.menuBarKind(hasBattery: false), .temperature)
        XCTAssertEqual(monitor.demand, MonitorDemand(showsThermal: true))

        // A real drag can stay staged across many main-actor turns before drop.
        layout.persistNow()
        await settle { reconciliations == 2 }
        XCTAssertEqual(layout.menuBarKind(hasBattery: false), .gpu)
        XCTAssertEqual(monitor.demand, MonitorDemand(showsGPU: true))
        XCTAssertEqual(WidgetLayoutStore(defaults: defaults).menuBarKind(hasBattery: false), .gpu)
        XCTAssertNil(monitor.lastRefreshAt, "A stopped monitor must not sample on commit")
        withExtendedLifetime(observation) {}
    }

    func testCancelledDragPreservesCommittedDemandAndRestoresPopoverOrder() async throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    performInitialRefresh: false, readDisplaysAsleep: { false })
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.replaceItems([WidgetItem(.temperature, .small), WidgetItem(.gpu, .small)])
        monitor.setDemand(MonitorDemand(showsThermal: true))
        let originalOrder = layout.items
        var reconciliations = 0
        let observation = MonitorDemandObservation(layout: layout, monitor: monitor) {
            reconciliations += 1
            let metric = layout.menuBarKind(hasBattery: monitor.hasBattery)
            monitor.setDemand(MonitorDemand(showsThermal: metric == .temperature, showsGPU: metric == .gpu))
        }
        layout.stageMove(.metric(.gpu), toIndexOf: .metric(.temperature))
        await settle { reconciliations == 1 }
        XCTAssertEqual(layout.visibleItems(hasBattery: false, calendarInPopover: false).first?.kind, .metric(.gpu))
        XCTAssertEqual(monitor.demand, MonitorDemand(showsThermal: true))

        layout.revertStagedChanges()
        await settle { reconciliations == 2 }
        XCTAssertEqual(layout.items, originalOrder)
        XCTAssertEqual(layout.visibleItems(hasBattery: false, calendarInPopover: false).first?.kind, .metric(.temperature))
        XCTAssertEqual(layout.menuBarKind(hasBattery: false), .temperature)
        XCTAssertEqual(monitor.demand, MonitorDemand(showsThermal: true))
        XCTAssertEqual(WidgetLayoutStore(defaults: defaults).items, originalOrder)
        withExtendedLifetime(observation) {}
    }

    func testMonitorStartPreservesCallerIntervalWithoutAChangedMinimum() throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    performInitialRefresh: false, readDisplaysAsleep: { true })
        defer { monitor.stop() }
        // Keep the timer paused so this checks the selected cadence without
        // reading hardware or waiting for a real timer to fire.
        monitor.start(interval: 0.05)
        XCTAssertEqual(monitor.samplingInterval, 0.05)
        XCTAssertNil(monitor.lastRefreshAt)
    }

    func testCachedStatsDistinguishNeverSampledAndSleepWithoutHardwareRefresh() async throws {
        let suite = "MonitorRenderingReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = SystemMonitor(defaults: defaults, historyStore: NoHistory(),
                                    performInitialRefresh: false, readDisplaysAsleep: { false })
        let host = ControlHost(defaults: defaults, monitor: { monitor })
        let first = await host.handle(ControlRequest(command: "stats", arguments: ["gpu"]))
        XCTAssertEqual(first.result?["gpu"]?["samplingState"], .string("neverSampled"))
        XCTAssertEqual(first.result?["gpu"]?["sampledAt"], .null)
        XCTAssertEqual(first.result?["gpu"]?["pauseReason"], .string("monitorStopped"))
        monitor.setDemand(.everything)
        monitor.setDisplaysAsleep(true)
        let asleep = await host.handle(ControlRequest(command: "stats", arguments: ["thermal"]))
        XCTAssertEqual(asleep.result?["thermal"]?["samplingState"], .string("neverSampled"))
        XCTAssertEqual(asleep.result?["thermal"]?["samplingPaused"], .bool(true))
        XCTAssertEqual(asleep.result?["thermal"]?["pauseReason"], .string("displaysAsleep"))
        XCTAssertEqual(asleep.result?["thermal"]?["cpuCelsius"], .null)
        XCTAssertTrue(asleep.warnings.contains { $0.contains("never sampled") })
        XCTAssertTrue(asleep.text?.contains("Temperature: not sampled") == true)
        monitor.setDisplaysAsleep(false)
        XCTAssertNil(monitor.lastRefreshAt)
        XCTAssertNil(monitor.lastThermalSampleAt)
        XCTAssertNil(monitor.lastGPUSampleAt)
        // Complete an already-started fake hardware read after sleep. Preserve
        // its original collection time while labeling the retained value paused.
        let collectedAt = Date(timeIntervalSinceReferenceDate: 100)
        monitor.setDisplaysAsleep(true)
        var thermal = Thermal.Reading.empty
        thermal.cpu = 52
        thermal.peak = 55
        thermal.cpuSource = "Fixture"
        monitor.applyThermal(thermal, sampledAt: collectedAt)
        monitor.applyGPU([GPUReading(id: 7, name: "Fixture GPU", activity: 0.4,
                                     counter: .device, poweredOff: false)], sampledAt: collectedAt)
        let cached = await host.handle(ControlRequest(command: "stats", arguments: ["all"]))
        for metric in ["gpu", "thermal"] {
            XCTAssertEqual(cached.result?[metric]?["samplingState"], .string("paused"))
            XCTAssertEqual(cached.result?[metric]?["sampledAt"], .string(ControlFormat.iso(collectedAt)))
            XCTAssertEqual(cached.result?[metric]?["pauseReason"], .string("displaysAsleep"))
        }
        XCTAssertEqual(cached.result?["thermal"]?["cpuCelsius"], .double(52))
        XCTAssertTrue(cached.warnings.contains { $0.contains("cached sample") })
        XCTAssertNil(monitor.lastRefreshAt, "A control request must never force a hardware refresh")
    }

    func testRenderCacheRequiresAFinalImageInTheCurrentContext() {
        let signature = StatusRenderSignature(kind: "storage", label: "100 GB", widthSample: "999 GB", colorToken: "fixture")
        var cache = StatusRenderCache()
        XCTAssertFalse(cache.canReuse(signature, hasImage: true))
        cache.record(signature)
        XCTAssertTrue(cache.canReuse(signature, hasImage: true))
        XCTAssertFalse(cache.canReuse(signature, hasImage: false))
        // Status-item replacement, sleep/wake and appearance changes all use this invalidation.
        cache.invalidate()
        XCTAssertFalse(cache.canReuse(signature, hasImage: true))
        cache.record(signature)
        XCTAssertTrue(cache.canReuse(signature, hasImage: true))
        var continuityChanged = signature
        continuityChanged.samples = [.init(timestamp: 1, value: 0.5, sessionID: UUID())]
        cache.record(continuityChanged)
        var nextTick = continuityChanged
        nextTick.timelineEnd = 2
        XCTAssertFalse(cache.canReuse(nextTick, hasImage: true), "Retained history must advance with the existing monitor tick")
        continuityChanged.samples[0].sessionID = UUID()
        XCTAssertFalse(cache.canReuse(continuityChanged, hasImage: true), "Chart session boundaries change the rendered line")
    }

    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "Deferred demand reconciliation did not finish")
    }
}
