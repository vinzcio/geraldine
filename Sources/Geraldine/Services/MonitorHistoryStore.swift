import Foundation

protocol MonitorHistoryStoring {
    func load() -> MonitorHistorySnapshot?
    func save(_ snapshot: MonitorHistorySnapshot) throws
}

struct MonitorHistorySnapshot: Codable, Equatable {
    static let currentVersion = 1

    private struct SampleIdentity: Hashable {
        var timestamp: TimeInterval
        var sessionID: UUID?
    }

    private struct CadenceBucket: Hashable {
        var index: Int64
        var sessionID: UUID?
    }

    var version: Int = Self.currentVersion
    var savedAt: TimeInterval
    var cpu: [MetricSample]
    var memory: [MetricSample]
    var battery: [MetricSample]
    var disk: [MetricSample]
    var network: [NetworkSample]
    var thermal: [MetricSample]

    static func empty(savedAt: TimeInterval) -> Self {
        Self(savedAt: savedAt, cpu: [], memory: [], battery: [], disk: [], network: [], thermal: [])
    }

    func normalized(now: TimeInterval) -> Self {
        Self(
            savedAt: min(savedAt, now),
            cpu: Self.normalize(cpu, now: now, window: SystemMonitor.liveHistoryWindow),
            memory: Self.normalize(memory, now: now, window: SystemMonitor.liveHistoryWindow),
            battery: Self.normalize(
                battery,
                now: now,
                window: SystemMonitor.longHistoryWindow,
                minimumInterval: SystemMonitor.longHistorySampleInterval
            ),
            disk: Self.normalize(
                disk,
                now: now,
                window: SystemMonitor.longHistoryWindow,
                minimumInterval: SystemMonitor.longHistorySampleInterval
            ),
            network: Self.normalizeNetwork(network, now: now),
            thermal: Self.normalize(thermal, now: now, window: SystemMonitor.liveHistoryWindow)
        )
    }

    private static func normalize(
        _ samples: [MetricSample],
        now: TimeInterval,
        window: TimeInterval,
        minimumInterval: TimeInterval = 0
    ) -> [MetricSample] {
        let cutoff = now - window
        var byIdentity: [SampleIdentity: MetricSample] = [:]
        for sample in samples where sample.timestamp.isFinite
            && sample.value.isFinite
            && sample.timestamp >= cutoff
            && sample.timestamp <= now {
            byIdentity[SampleIdentity(timestamp: sample.timestamp, sessionID: sample.sessionID)] = MetricSample(
                timestamp: sample.timestamp,
                value: sample.value,
                sessionID: sample.sessionID
            )
        }

        let sorted = byIdentity.values.sorted(by: compareMetricSamples)
        guard minimumInterval > 0 else {
            return Array(sorted.suffix(SystemMonitor.maximumLiveHistorySamples))
        }

        // Keep one real measurement per cadence bucket. This bounds a 24-hour
        // history even if an older build persisted a value every second.
        var byBucket: [CadenceBucket: MetricSample] = [:]
        for sample in sorted {
            let bucket = Int64((sample.timestamp / minimumInterval).rounded(.down))
            byBucket[CadenceBucket(index: bucket, sessionID: sample.sessionID)] = sample
        }
        return Array(
            byBucket.values
                .sorted(by: compareMetricSamples)
                .suffix(SystemMonitor.maximumLongHistorySamples)
        )
    }

    private static func compareMetricSamples(_ lhs: MetricSample, _ rhs: MetricSample) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return (lhs.sessionID?.uuidString ?? "") < (rhs.sessionID?.uuidString ?? "")
    }

    private static func normalizeNetwork(_ samples: [NetworkSample], now: TimeInterval) -> [NetworkSample] {
        let cutoff = now - SystemMonitor.liveHistoryWindow
        var byIdentity: [SampleIdentity: NetworkSample] = [:]
        for sample in samples where sample.timestamp.isFinite
            && sample.down.isFinite
            && sample.up.isFinite
            && sample.timestamp >= cutoff
            && sample.timestamp <= now {
            byIdentity[SampleIdentity(timestamp: sample.timestamp, sessionID: sample.sessionID)] = NetworkSample(
                timestamp: sample.timestamp,
                down: sample.down,
                up: sample.up,
                sessionID: sample.sessionID
            )
        }
        return Array(
            byIdentity.values
                .sorted {
                    if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                    return ($0.sessionID?.uuidString ?? "") < ($1.sessionID?.uuidString ?? "")
                }
                .suffix(SystemMonitor.maximumLiveHistorySamples)
        )
    }
}

struct MonitorHistoryStore: MonitorHistoryStoring {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    func load() -> MonitorHistorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(MonitorHistorySnapshot.self, from: data),
              snapshot.version == MonitorHistorySnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: MonitorHistorySnapshot) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Geraldine", isDirectory: true)
            .appendingPathComponent("monitor-history-v1.json", isDirectory: false)
    }
}
