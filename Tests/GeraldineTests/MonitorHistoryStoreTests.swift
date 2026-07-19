import XCTest
@testable import Geraldine

final class MonitorHistoryStoreTests: XCTestCase {
    func testSaveCreatesApplicationSupportStyleDirectoryAndRoundTripsSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root
            .appendingPathComponent("Application Support/Geraldine", isDirectory: true)
            .appendingPathComponent("monitor-history-v1.json")
        let store = MonitorHistoryStore(fileURL: fileURL)
        let sessionID = UUID()
        let snapshot = MonitorHistorySnapshot(
            savedAt: 1_000,
            cpu: [MetricSample(timestamp: 999, value: 0.4, sessionID: sessionID)],
            memory: [],
            battery: [],
            disk: [],
            network: [NetworkSample(timestamp: 999, down: 12, up: 3, sessionID: sessionID)],
            thermal: []
        )

        try store.save(snapshot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(store.load(), snapshot)
    }

    func testCorruptOrUnsupportedSnapshotsAreIgnored() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("monitor-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MonitorHistoryStore(fileURL: fileURL)

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(store.load())

        try Data("{\"version\":999,\"savedAt\":0,\"cpu\":[],\"memory\":[],\"battery\":[],\"disk\":[],\"network\":[],\"thermal\":[]}".utf8)
            .write(to: fileURL)
        XCTAssertNil(store.load())
    }

    func testNormalizationPrunesSortsDeduplicatesAndBoundsLongHistory() {
        let now: TimeInterval = 100_000
        let sessionID = UUID()
        var snapshot = MonitorHistorySnapshot.empty(savedAt: now + 30)
        snapshot.cpu = [
            MetricSample(timestamp: now - 10, value: 0.2, sessionID: sessionID),
            MetricSample(timestamp: now - 301, value: 0.9),
            MetricSample(timestamp: now - 10, value: 0.7, sessionID: sessionID),
            MetricSample(timestamp: now + 1, value: 0.8)
        ]
        snapshot.battery = (0..<3_600).map {
            MetricSample(timestamp: now - Double($0), value: Double($0 % 100) / 100)
        }

        let normalized = snapshot.normalized(now: now)

        XCTAssertEqual(normalized.savedAt, now)
        XCTAssertEqual(normalized.cpu, [MetricSample(timestamp: now - 10, value: 0.7, sessionID: sessionID)])
        XCTAssertLessThanOrEqual(normalized.battery.count, 61)
        XCTAssertEqual(normalized.battery.map(\.timestamp), normalized.battery.map(\.timestamp).sorted())
    }

    func testNormalizationPreservesBothSessionsInsideOneCadenceBucket() {
        let firstSession = UUID()
        let secondSession = UUID()
        var snapshot = MonitorHistorySnapshot.empty(savedAt: 1_300)
        snapshot.battery = [
            MetricSample(timestamp: 1_200, value: 0.4, sessionID: firstSession),
            MetricSample(timestamp: 1_220, value: 0.5, sessionID: firstSession),
            MetricSample(timestamp: 1_230, value: 0.6, sessionID: secondSession)
        ]

        let normalized = snapshot.normalized(now: 1_300)

        XCTAssertEqual(normalized.battery.map(\.timestamp), [1_220, 1_230])
        XCTAssertEqual(normalized.battery.map(\.sessionID), [firstSession, secondSession])
    }

    @MainActor
    func testLegacyNetworkDefaultsMigrateWithoutSessionID() throws {
        let suiteName = "MonitorHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now: TimeInterval = 200_000
        let legacyJSON = """
        [
          {"timestamp": \(now - 2), "down": 20, "up": 4},
          {"timestamp": \(now - 3), "down": 10, "up": 2}
        ]
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "geraldine.networkHistory.v1")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MonitorHistoryStore(fileURL: root.appendingPathComponent("nested/history.json"))

        let monitor = SystemMonitor(
            defaults: defaults,
            historyStore: store,
            now: { Date(timeIntervalSinceReferenceDate: now) },
            performInitialRefresh: false
        )

        XCTAssertEqual(monitor.networkHistory.map(\.timestamp), [now - 3, now - 2])
        XCTAssertTrue(monitor.networkHistory.allSatisfy { $0.sessionID == nil })
        XCTAssertNil(defaults.data(forKey: "geraldine.networkHistory.v1"))
        XCTAssertEqual(store.load()?.network, monitor.networkHistory)
    }

    @MainActor
    func testSystemMonitorRestoresEveryHistoryBeforeInitialRefresh() throws {
        let now: TimeInterval = 300_000
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MonitorHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let metric = MetricSample(timestamp: now - 10, value: 0.4, sessionID: UUID())
        let network = NetworkSample(timestamp: now - 10, down: 20, up: 5, sessionID: UUID())
        try store.save(MonitorHistorySnapshot(
            savedAt: now - 1,
            cpu: [metric],
            memory: [metric],
            battery: [metric],
            disk: [metric],
            network: [network],
            thermal: [metric]
        ))

        let monitor = SystemMonitor(
            historyStore: store,
            now: { Date(timeIntervalSinceReferenceDate: now) },
            performInitialRefresh: false
        )

        XCTAssertEqual(monitor.cpuHistory, [metric])
        XCTAssertEqual(monitor.memHistory, [metric])
        XCTAssertEqual(monitor.batteryHistory, [metric])
        XCTAssertEqual(monitor.diskHistory, [metric])
        XCTAssertEqual(monitor.networkHistory, [network])
        XCTAssertEqual(monitor.thermalHistory, [metric])
    }

    @MainActor
    func testBatteryRenderHistoryEndsAtCurrentHeadlineWithoutChangingStoredCadence() {
        let now: TimeInterval = 350_000
        let restoredSession = UUID()
        let monitor = SystemMonitor(
            historyStore: MonitorHistoryStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("unused-\(UUID().uuidString).json")
            ),
            now: { Date(timeIntervalSinceReferenceDate: now) },
            performInitialRefresh: false
        )
        monitor.hasBattery = true
        monitor.batteryLevel = 0.08
        monitor.batteryHistory = [
            MetricSample(timestamp: now - 30, value: 0.22, sessionID: restoredSession)
        ]

        let rendered = monitor.batteryHistoryIncludingCurrent(
            at: Date(timeIntervalSinceReferenceDate: now)
        )

        XCTAssertEqual(rendered.map(\.value), [0.22, 0.08])
        XCTAssertEqual(rendered.last?.timestamp, now)
        XCTAssertNotEqual(rendered.last?.sessionID, restoredSession,
                          "a render-only endpoint must not bridge a restored session")
        XCTAssertEqual(monitor.batteryHistory.map(\.value), [0.22],
                       "render parity must not increase persisted sampling cadence")

        monitor.batteryLevel = nil
        XCTAssertEqual(
            monitor.batteryHistoryIncludingCurrent(at: Date(timeIntervalSinceReferenceDate: now)),
            monitor.batteryHistory,
            "an unavailable current level must not fabricate a fresh chart endpoint"
        )
    }

    func testUnknownValuesAreNotAppendedAndLongHistoryUsesLowerCadence() {
        var history: [MetricSample] = []
        let firstSession = UUID()
        let secondSession = UUID()

        XCTAssertFalse(SystemMonitor.appendMetricSample(
            &history,
            value: nil,
            timestamp: 1_000,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: firstSession
        ))
        XCTAssertTrue(SystemMonitor.appendMetricSample(
            &history,
            value: 0.5,
            timestamp: 1_000,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: firstSession
        ))
        XCTAssertFalse(SystemMonitor.appendMetricSample(
            &history,
            value: 0.6,
            timestamp: 1_030,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: firstSession
        ))
        XCTAssertTrue(SystemMonitor.appendMetricSample(
            &history,
            value: 0.7,
            timestamp: 1_031,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: secondSession
        ))
        XCTAssertFalse(SystemMonitor.appendMetricSample(
            &history,
            value: 0.8,
            timestamp: 1_060,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: secondSession
        ))
        XCTAssertTrue(SystemMonitor.appendMetricSample(
            &history,
            value: 0.9,
            timestamp: 1_091,
            retaining: SystemMonitor.longHistoryWindow,
            minimumInterval: SystemMonitor.longHistorySampleInterval,
            sessionID: secondSession
        ))
        XCTAssertEqual(history.map(\.timestamp), [1_000, 1_031, 1_091])
    }

    @MainActor
    func testFailedCheckpointBacksOffButExplicitFlushStillAttempts() throws {
        let suiteName = "MonitorHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let launchTime: TimeInterval = 400_000
        defaults.set(legacyNetworkData(timestamp: launchTime - 1),
                     forKey: "geraldine.networkHistory.v1")
        let store = ScriptedHistoryStore(saveResults: [.failure, .failure, .failure, .failure])
        var currentTime = launchTime
        let monitor = SystemMonitor(
            defaults: defaults,
            historyStore: store,
            now: { Date(timeIntervalSinceReferenceDate: currentTime) },
            performInitialRefresh: false
        )
        XCTAssertEqual(store.saveCount, 1)

        monitor.checkpointIfNeeded(now: launchTime + SystemMonitor.checkpointInterval)
        XCTAssertEqual(store.saveCount, 2)
        monitor.checkpointIfNeeded(now: launchTime + SystemMonitor.checkpointInterval + 1)
        XCTAssertEqual(store.saveCount, 2, "a failed checkpoint must not retry every monitor tick")
        monitor.checkpointIfNeeded(now: launchTime + (SystemMonitor.checkpointInterval * 2))
        XCTAssertEqual(store.saveCount, 3)

        currentTime = launchTime + (SystemMonitor.checkpointInterval * 2)
        monitor.flushHistory()
        XCTAssertEqual(store.saveCount, 4, "termination flush must attempt even inside the retry window")
    }

    @MainActor
    func testSuccessfulRetryRemovesLegacyDefaultsAfterInitialMigrationFailure() throws {
        let suiteName = "MonitorHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let timestamp: TimeInterval = 500_000
        defaults.set(legacyNetworkData(timestamp: timestamp - 1),
                     forKey: "geraldine.networkHistory.v1")
        let store = ScriptedHistoryStore(saveResults: [.failure, .success])
        let monitor = SystemMonitor(
            defaults: defaults,
            historyStore: store,
            now: { Date(timeIntervalSinceReferenceDate: timestamp) },
            performInitialRefresh: false
        )

        XCTAssertNotNil(defaults.data(forKey: "geraldine.networkHistory.v1"))
        monitor.checkpointIfNeeded(now: timestamp + SystemMonitor.checkpointInterval)

        XCTAssertEqual(store.saveCount, 2)
        XCTAssertNil(defaults.data(forKey: "geraldine.networkHistory.v1"))
    }

    func testSessionChangeCreatesGapEvenWhenRestartWasQuick() {
        let firstSession = UUID()
        let secondSession = UUID()
        let timeline = TimelineWindow(end: 100, duration: 300)
        let samples = [
            MetricSample(timestamp: 98, value: 0.2, sessionID: firstSession),
            MetricSample(timestamp: 99, value: 0.3, sessionID: secondSession)
        ]

        XCTAssertEqual(timeline.segments(samples, gapThreshold: 4), [[samples[0]], [samples[1]]])
    }

    private func legacyNetworkData(timestamp: TimeInterval) -> Data {
        Data("[{\"timestamp\":\(timestamp),\"down\":10,\"up\":2}]".utf8)
    }
}

private final class ScriptedHistoryStore: MonitorHistoryStoring {
    enum SaveResult {
        case success
        case failure
    }

    private var saveResults: [SaveResult]
    private(set) var saveCount = 0

    init(saveResults: [SaveResult]) {
        self.saveResults = saveResults
    }

    func load() -> MonitorHistorySnapshot? { nil }

    func save(_ snapshot: MonitorHistorySnapshot) throws {
        saveCount += 1
        let result = saveResults.isEmpty ? .success : saveResults.removeFirst()
        if case .failure = result { throw SaveFailure.expected }
    }

    private enum SaveFailure: Error {
        case expected
    }
}
