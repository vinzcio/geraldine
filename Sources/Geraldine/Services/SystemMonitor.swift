import Foundation
import Darwin
import IOKit
import IOKit.ps

struct NetworkSample: Codable, Equatable, Identifiable, TimelineSample {
    var timestamp: TimeInterval
    var down: Double
    var up: Double
    var sessionID: UUID?

    var id: TimeInterval { timestamp }
    var date: Date { Date(timeIntervalSinceReferenceDate: timestamp) }

    init(timestamp: TimeInterval, down: Double, up: Double, sessionID: UUID? = nil) {
        self.timestamp = timestamp
        self.down = Self.rate(down)
        self.up = Self.rate(up)
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, down, up, sessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        down = Self.rate(try container.decode(Double.self, forKey: .down))
        up = Self.rate(try container.decode(Double.self, forKey: .up))
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }

    private static func rate(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Samples live system vitals on a timer. Drives both the menu bar and the dashboard.
@MainActor
final class SystemMonitor: ObservableObject {
    nonisolated static let liveHistoryWindow: TimeInterval = 5 * 60
    nonisolated static let longHistoryWindow: TimeInterval = 24 * 60 * 60
    nonisolated static let longHistorySampleInterval: TimeInterval = 60
    nonisolated static let checkpointInterval: TimeInterval = 12
    nonisolated static let maximumLiveHistorySamples = 600
    nonisolated static let maximumLongHistorySamples = 1_500
    nonisolated static let chartSampleGapThreshold: TimeInterval = 4

    @Published var cpuUsage: Double = 0          // 0…1
    @Published var memoryUsed: Double = 0        // bytes
    @Published var memoryTotal: Double = 0       // bytes
    @Published var diskUsed: Double = 0          // bytes
    @Published var diskTotal: Double = 0         // bytes
    @Published var hasBattery: Bool = false      // true only for an installed internal battery
    @Published var batteryLevel: Double? = nil   // 0…1, nil if no battery
    @Published var batteryCharging: Bool = false
    @Published var batteryHealth: Double? = nil  // 0…1
    @Published var batteryCycles: Int? = nil
    @Published var batteryMinutesToEmpty: Int? = nil  // nil while macOS is still estimating
    @Published var batteryMinutesToFull: Int? = nil
    @Published var batteryOnAC: Bool = true           // system is drawing from the wall adapter
    @Published var batteryDraining: Bool = false      // plugged in yet net-discharging (adapter can't keep up)
    @Published var batteryFull: Bool = false
    @Published var netDown: Double = 0           // bytes/sec
    @Published var netUp: Double = 0             // bytes/sec

    // Every live history keeps its measurement timestamp. Charts use those timestamps
    // for x-positioning, so a few seconds of activity stays at the right edge of a
    // fixed window instead of being stretched across the entire chart.
    @Published var cpuHistory: [MetricSample] = []
    @Published var memHistory: [MetricSample] = []
    @Published var batteryHistory: [MetricSample] = []
    @Published var diskHistory: [MetricSample] = []
    @Published var networkHistory: [NetworkSample] = []
    @Published var thermalHistory: [MetricSample] = []
    @Published var thermal: Thermal.Reading = .empty
    private let legacyNetworkHistoryKey = "geraldine.networkHistory.v1"
    private let defaults: UserDefaults
    private let historyStore: any MonitorHistoryStoring
    private let now: () -> Date
    private let sessionID = UUID()

    private var timer: Timer?
    private var prevCPU: host_cpu_load_info?
    private var prevNet: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var thermalInFlight = false
    private var historyDirty = false
    private var lastCheckpointAt: TimeInterval
    private var legacyNetworkMigrationPending = false

    init(
        defaults: UserDefaults = .standard,
        historyStore: any MonitorHistoryStoring = MonitorHistoryStore(),
        now: @escaping () -> Date = Date.init,
        performInitialRefresh: Bool = true
    ) {
        self.defaults = defaults
        self.historyStore = historyStore
        self.now = now
        let launchTime = now().timeIntervalSinceReferenceDate
        lastCheckpointAt = launchTime
        memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
        restoreHistory(now: launchTime)
        if performInitialRefresh { refresh() }
    }

    func start(interval: TimeInterval = 1) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.4
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func flushHistory() {
        guard historyDirty else { return }
        let timestamp = now().timeIntervalSinceReferenceDate
        lastCheckpointAt = timestamp
        saveHistory(at: timestamp)
    }

    private func saveHistory(at timestamp: TimeInterval) {
        do {
            try historyStore.save(historySnapshot(savedAt: timestamp))
            historyDirty = false
            if legacyNetworkMigrationPending {
                defaults.removeObject(forKey: legacyNetworkHistoryKey)
                legacyNetworkMigrationPending = false
            }
        } catch {
            // History persistence must never prevent monitoring or app termination.
            historyDirty = true
        }
    }

    var memoryFraction: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }
    var diskFraction: Double { diskTotal > 0 ? diskUsed / diskTotal : 0 }

    func refresh() {
        let timestamp = now().timeIntervalSinceReferenceDate
        let sampledCPU = sampleCPU()
        if let sampledCPU { cpuUsage = sampledCPU }
        let mem = Self.sampleMemory()
        memoryUsed = mem.used
        if mem.total > 0 { memoryTotal = mem.total }
        let disk = Self.sampleDisk()
        diskUsed = disk.used; diskTotal = disk.total
        let bat = Self.sampleBattery()
        hasBattery = bat.hasBattery
        batteryLevel = bat.level; batteryCharging = bat.charging
        batteryHealth = bat.health; batteryCycles = bat.cycles
        batteryMinutesToEmpty = bat.toEmpty; batteryMinutesToFull = bat.toFull
        batteryOnAC = bat.onAC; batteryDraining = bat.draining; batteryFull = bat.full
        let networkSample = sampleNetwork()
        if let networkSample {
            netDown = networkSample.down; netUp = networkSample.up
        }

        historyDirty = pruneHistories(now: timestamp) || historyDirty
        if let sampledCPU {
            historyDirty = Self.appendMetricSample(
                &cpuHistory, value: sampledCPU, timestamp: timestamp,
                retaining: Self.liveHistoryWindow, sessionID: sessionID
            ) || historyDirty
        }
        historyDirty = Self.appendMetricSample(
            &memHistory, value: memoryFraction, timestamp: timestamp,
            retaining: Self.liveHistoryWindow, sessionID: sessionID
        ) || historyDirty
        historyDirty = Self.appendMetricSample(
            &batteryHistory, value: hasBattery ? batteryLevel : nil, timestamp: timestamp,
            retaining: Self.longHistoryWindow,
            minimumInterval: Self.longHistorySampleInterval,
            sessionID: sessionID
        ) || historyDirty
        historyDirty = Self.appendMetricSample(
            &diskHistory, value: diskTotal > 0 ? diskFraction : nil, timestamp: timestamp,
            retaining: Self.longHistoryWindow,
            minimumInterval: Self.longHistorySampleInterval,
            sessionID: sessionID
        ) || historyDirty
        if let networkSample {
            appendNetworkSample(networkSample)
        }
        checkpointIfNeeded(now: timestamp)

        // Thermal sampling does ~130 synchronous IOKit/SMC round-trips (~70–100ms).
        // Running it inline blocks the main run loop once per second and starves the
        // number animations (menu bar, popover, and main window). Sample it off the
        // main actor and apply the result back on the main actor. The in-flight guard
        // skips a tick rather than queueing if a read ever outlasts the cadence.
        if !thermalInFlight {
            thermalInFlight = true
            Task.detached(priority: .utility) { [weak self] in
                let reading = Thermal.read()
                await self?.applyThermal(reading)
            }
        }
    }

    private func applyThermal(_ reading: Thermal.Reading) {
        thermalInFlight = false
        thermal = reading
        if reading.available {
            let timestamp = now().timeIntervalSinceReferenceDate
            historyDirty = Self.appendMetricSample(
                &thermalHistory,
                value: reading.cpu,
                timestamp: timestamp,
                retaining: Self.liveHistoryWindow,
                sessionID: sessionID
            ) || historyDirty
            checkpointIfNeeded(now: timestamp)
        }
    }

    @discardableResult
    nonisolated static func appendMetricSample(
        _ history: inout [MetricSample],
        value: Double?,
        timestamp: TimeInterval,
        retaining window: TimeInterval,
        minimumInterval: TimeInterval = 0,
        sessionID: UUID
    ) -> Bool {
        guard let value, value.isFinite, timestamp.isFinite else { return false }
        let cutoff = timestamp - window
        let originalCount = history.count
        history.removeAll { $0.timestamp < cutoff }
        if minimumInterval > 0,
           let last = history.last,
           last.sessionID == sessionID,
           timestamp - last.timestamp < minimumInterval {
            return history.count != originalCount
        }
        history.append(MetricSample(timestamp: timestamp, value: value, sessionID: sessionID))
        let maximumCount = minimumInterval > 0
            ? Self.maximumLongHistorySamples
            : Self.maximumLiveHistorySamples
        if history.count > maximumCount {
            history.removeFirst(history.count - maximumCount)
        }
        return true
    }

    // MARK: - Uptime & load

    var uptime: TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(tv.tv_sec))
    }

    var loadAverage: Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    static func uptimeString(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86400
        let hours = (Int(interval) % 86400) / 3600
        let mins = (Int(interval) % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // MARK: - CPU

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        defer { prevCPU = info }
        guard let p = prevCPU else { return nil }
        let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        return total > 0 ? max(0, min(1, busy / total)) : nil
    }

    // MARK: - Memory

    private static func sampleMemory() -> (used: Double, total: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = Double(vm_page_size)
        let active = Double(stats.active_count) * page
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        // Approximates Activity Monitor's "Memory Used".
        let used = active + wired + compressed
        return (used, total)
    }

    // MARK: - Disk

    private static func sampleDisk() -> (used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey]) else {
            return (0, 0)
        }
        let total = Double(v.volumeTotalCapacity ?? 0)
        let available = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        return (max(0, total - available), total)
    }

    // MARK: - Battery

    private static func sampleBattery() -> (hasBattery: Bool, level: Double?, charging: Bool, health: Double?, cycles: Int?,
                                            toEmpty: Int?, toFull: Int?, onAC: Bool, draining: Bool, full: Bool) {
        let reg = batteryFromRegistry()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            // No power source (e.g. a desktop): always on wall power.
            return (reg.hasBattery, nil, false, reg.health, reg.cycles, nil, nil, true, false, false)
        }

        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let internalBattery = descriptions.first {
            ($0[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String)
        }
        guard let desc = internalBattery ?? (reg.hasBattery ? descriptions.first : nil) else {
            return (false, nil, false, nil, nil, nil, nil, true, false, false)
        }

        var level: Double? = nil
        if let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
           let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
            level = Double(cur) / Double(max)
        }
        let hasBattery = reg.hasBattery || level != nil
        guard hasBattery else {
            return (false, nil, false, nil, nil, nil, nil, true, false, false)
        }
        let charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
        // Both estimates report -1 while macOS is still calculating; treat as nil.
        func positive(_ key: String) -> Int? {
            guard let value = desc[key] as? Int, value > 0 else { return nil }
            return value
        }
        let toEmpty = positive(kIOPSTimeToEmptyKey as String)
        let toFull = positive(kIOPSTimeToFullChargeKey as String)

        // Power-source state reports "AC Power" whenever the adapter is connected —
        // including while charging or holding at a limit. The signed current then tells
        // us the true direction: < 0 means the battery is net-draining despite AC.
        let onAC = (desc[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
        let full = (desc[kIOPSIsChargedKey as String] as? Bool) ?? false
        let current = desc[kIOPSCurrentKey as String] as? Int
        let draining = onAC && (current ?? 0) < 0
        return (true, level, charging, reg.health, reg.cycles, toEmpty, toFull, onAC, draining, full)
    }

    private static func batteryFromRegistry() -> (hasBattery: Bool, health: Double?, cycles: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (false, nil, nil) }
        defer { IOObjectRelease(service) }
        func intProp(_ key: String) -> Int? {
            guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { return nil }
            return (cf as? NSNumber)?.intValue
        }
        func boolProp(_ key: String) -> Bool {
            guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() else { return false }
            return (cf as? NSNumber)?.boolValue ?? false
        }
        let maxCap = intProp("AppleRawMaxCapacity") ?? intProp("MaxCapacity")
        let designCap = intProp("DesignCapacity")
        let currentCap = intProp("CurrentCapacity")
        let hasBattery = boolProp("BatteryInstalled") || [maxCap, designCap, currentCap].contains { ($0 ?? 0) > 0 }
        let cycles = hasBattery ? intProp("CycleCount") : nil
        var health: Double? = nil
        if let m = maxCap, let d = designCap, d > 0 { health = min(1, Double(m) / Double(d)) }
        return (hasBattery, hasBattery ? health : nil, cycles)
    }

    // MARK: - Network

    private func sampleNetwork() -> NetworkSample? {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr = addrs
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            if let addr = p.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0,
               let data = p.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
            }
            ptr = p.pointee.ifa_next
        }
        let timestamp = now().timeIntervalSinceReferenceDate
        defer { prevNet = (rx, tx, timestamp) }
        guard let prev = prevNet, timestamp > prev.time else { return nil }
        let dt = timestamp - prev.time
        // Guard against counter resets / interface changes: if a cumulative counter
        // appears to decrease, report 0 rather than letting unsigned wraparound (&-)
        // produce a gigantic bogus rate.
        let down = rx >= prev.rx ? Double(rx - prev.rx) / dt : 0
        let up = tx >= prev.tx ? Double(tx - prev.tx) / dt : 0
        return NetworkSample(timestamp: timestamp, down: down, up: up, sessionID: sessionID)
    }

    private func appendNetworkSample(_ sample: NetworkSample) {
        networkHistory.append(sample)
        if networkHistory.count > Self.maximumLiveHistorySamples {
            networkHistory.removeFirst(networkHistory.count - Self.maximumLiveHistorySamples)
        }
        historyDirty = true
    }

    private func pruneHistories(now timestamp: TimeInterval) -> Bool {
        var changed = false
        changed = Self.prune(&cpuHistory, cutoff: timestamp - Self.liveHistoryWindow) || changed
        changed = Self.prune(&memHistory, cutoff: timestamp - Self.liveHistoryWindow) || changed
        changed = Self.prune(&thermalHistory, cutoff: timestamp - Self.liveHistoryWindow) || changed
        changed = Self.prune(&networkHistory, cutoff: timestamp - Self.liveHistoryWindow) || changed
        changed = Self.prune(&batteryHistory, cutoff: timestamp - Self.longHistoryWindow) || changed
        changed = Self.prune(&diskHistory, cutoff: timestamp - Self.longHistoryWindow) || changed
        return changed
    }

    private static func prune<S: TimelineSample>(_ history: inout [S], cutoff: TimeInterval) -> Bool {
        let originalCount = history.count
        history.removeAll { $0.timestamp < cutoff }
        return history.count != originalCount
    }

    func checkpointIfNeeded(now timestamp: TimeInterval) {
        guard historyDirty, timestamp - lastCheckpointAt >= Self.checkpointInterval else { return }
        // Advance the attempt clock even when the write fails. The history remains
        // dirty, but a broken or temporarily unavailable disk cannot turn the
        // one-second monitor cadence into one synchronous write attempt per tick.
        lastCheckpointAt = timestamp
        saveHistory(at: timestamp)
    }

    private func restoreHistory(now timestamp: TimeInterval) {
        if let saved = historyStore.load() {
            apply(saved.normalized(now: timestamp))
            return
        }

        guard let data = defaults.data(forKey: legacyNetworkHistoryKey),
              let legacy = try? JSONDecoder().decode([NetworkSample].self, from: data) else {
            return
        }
        var migrated = MonitorHistorySnapshot.empty(savedAt: timestamp)
        migrated.network = legacy
        migrated = migrated.normalized(now: timestamp)
        apply(migrated)
        legacyNetworkMigrationPending = true
        do {
            try historyStore.save(migrated)
            defaults.removeObject(forKey: legacyNetworkHistoryKey)
            legacyNetworkMigrationPending = false
        } catch {
            historyDirty = true
        }
    }

    private func apply(_ snapshot: MonitorHistorySnapshot) {
        cpuHistory = snapshot.cpu
        memHistory = snapshot.memory
        batteryHistory = snapshot.battery
        diskHistory = snapshot.disk
        networkHistory = snapshot.network
        thermalHistory = snapshot.thermal
    }

    private func historySnapshot(savedAt timestamp: TimeInterval) -> MonitorHistorySnapshot {
        MonitorHistorySnapshot(
            savedAt: timestamp,
            cpu: cpuHistory,
            memory: memHistory,
            battery: batteryHistory,
            disk: diskHistory,
            network: networkHistory,
            thermal: thermalHistory
        ).normalized(now: timestamp)
    }
}
