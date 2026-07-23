import Foundation
import IOKit
import IOKit.ps

// MARK: - Models

/// A single battery-charge reading reconstructed from the system power log.
struct ChargeSample: Equatable, Identifiable, Sendable {
    var date: Date
    var level: Double   // 0…1
    var onAC: Bool       // drawing from the adapter for the interval starting here

    var id: Date { date }
}

/// Rendering policy for the sparse, event-based readings produced by `pmset`.
/// Percentage and power-source events can naturally be many minutes apart, so the
/// threshold is deliberately more forgiving than Geraldine's one-second live charts.
/// A longer interval usually represents sleep, shutdown, or unavailable log data and
/// must remain visibly disconnected.
enum BatteryHistoryPolicy {
    static let maximumContinuousGap: TimeInterval = 90 * 60

    /// Combines system-log and in-process readings in chronological order. Exact
    /// timestamp collisions are deduplicated; a live reading wins because it reflects
    /// the newer observation source. Within one source, the last supplied value wins.
    static func merge(pmset: [ChargeSample], live: [ChargeSample]) -> [ChargeSample] {
        struct Candidate {
            let sample: ChargeSample
            let sourcePriority: Int
            let ordinal: Int
        }

        let pmsetCandidates = pmset.enumerated().map {
            Candidate(sample: $0.element, sourcePriority: 0, ordinal: $0.offset)
        }
        let liveCandidates = live.enumerated().map {
            Candidate(sample: $0.element, sourcePriority: 1, ordinal: $0.offset)
        }
        let sorted = (pmsetCandidates + liveCandidates).sorted { lhs, rhs in
            if lhs.sample.date != rhs.sample.date { return lhs.sample.date < rhs.sample.date }
            if lhs.sourcePriority != rhs.sourcePriority { return lhs.sourcePriority < rhs.sourcePriority }
            return lhs.ordinal < rhs.ordinal
        }

        var merged: [ChargeSample] = []
        for candidate in sorted {
            if merged.last?.date == candidate.sample.date {
                merged[merged.count - 1] = candidate.sample
            } else {
                merged.append(candidate.sample)
            }
        }
        return merged
    }

    /// Linearly scans already normalized (sorted and deduplicated) input, returning
    /// only visible samples and splitting intervals for which the source did not report
    /// a reading. Normalization belongs at the data-owner boundary so hover and
    /// accessibility inspection never repeat an O(n log n) sort.
    static func segments(
        normalizedSamples samples: [ChargeSample],
        start: Date,
        end: Date,
        gapThreshold: TimeInterval = maximumContinuousGap
    ) -> [[ChargeSample]] {
        var result: [[ChargeSample]] = []
        var current: [ChargeSample] = []
        var previousDate: Date?
        for sample in samples {
            if sample.date < start { continue }
            if sample.date > end { break }
            if let previousDate, sample.date.timeIntervalSince(previousDate) > gapThreshold {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
            current.append(sample)
            previousDate = sample.date
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// One app's energy impact, mirroring Activity Monitor's "Energy" tab.
struct EnergyConsumer: Identifiable, Sendable {
    let pid: Int
    var name: String
    var impact: Double

    var id: Int { pid }
}

/// Detailed battery condition & lifecycle, like CleanMyMac's battery popup.
struct BatteryDetail: Sendable {
    var hasBattery: Bool = false
    var maxCapacityPercent: Int? = nil   // health, e.g. 93 (matches macOS Battery Health)
    var cycleCount: Int? = nil
    var condition: String? = nil          // "Normal" / "Service Recommended"
    var temperatureC: Double? = nil
    var voltageV: Double? = nil
    var designCapacity: Int? = nil        // mAh
    var currentMaxCapacity: Int? = nil    // mAh
    var isCharging: Bool = false
    var fullyCharged: Bool = false
    var externalConnected: Bool = false
    var minutesToFull: Int? = nil
    var minutesToEmpty: Int? = nil
    var adapterConnected: Bool = false
    var adapterName: String? = nil
    var adapterWatts: Int? = nil

    /// Health as a 0…1 fraction, preferring the system-reported percentage.
    var healthFraction: Double? {
        if let p = maxCapacityPercent { return Double(p) / 100 }
        if let m = currentMaxCapacity, let d = designCapacity, d > 0 { return Double(m) / Double(d) }
        return nil
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "Last 24 Hours"
    case tenDays = "Last 10 Days"
    var id: String { rawValue }
    var seconds: TimeInterval { self == .day ? 86_400 : 86_400 * 10 }
}

// MARK: - Data source

/// Reads battery history, energy consumers, and lifecycle details. All calls are
/// safe to run off the main actor (they shell out or read the IO registry) and
/// return `Sendable` values, so the view model can hop them back to `@MainActor`.
enum BatteryInfo {

    // MARK: Charge history (pmset -g log)

    /// Reconstructs the charge-level timeline from the system power-management log,
    /// the same source macOS Battery settings draws its 24-hour / 10-day graphs from.
    static func chargeHistory() -> [ChargeSample] {
        let r = Shell.run("/usr/bin/pmset", ["-g", "log"])
        guard r.status == 0 else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

        var samples: [ChargeSample] = []
        for raw in r.output.split(separator: "\n") {
            let line = String(raw)
            guard line.contains("Charge"), line.contains("Using") else { continue }
            guard let stamp = firstMatch(timeRegex, in: line, range: line.startIndex..<line.endIndex),
                  let date = formatter.date(from: stamp) else { continue }
            guard let (source, pct) = chargeMatch(in: line) else { continue }
            samples.append(ChargeSample(date: date,
                                        level: min(1, max(0, Double(pct) / 100)),
                                        onAC: source.uppercased() == "AC"))
        }
        return BatteryHistoryPolicy.merge(pmset: samples, live: [])
    }

    private static let timeRegex = try? NSRegularExpression(
        pattern: "^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4})")
    private static let chargeRegex = try? NSRegularExpression(
        pattern: "Using\\s+(AC|BATT)\\s*\\(Charge\\s*:\\s*([0-9]{1,3})\\s*%?\\s*\\)",
        options: [.caseInsensitive])

    private static func firstMatch(_ regex: NSRegularExpression?, in s: String,
                                   range: Range<String.Index>) -> String? {
        guard let regex else { return nil }
        let ns = NSRange(range, in: s)
        guard let m = regex.firstMatch(in: s, range: ns), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func chargeMatch(in s: String) -> (source: String, pct: Int)? {
        guard let regex = chargeRegex else { return nil }
        let ns = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = regex.firstMatch(in: s, range: ns), m.numberOfRanges > 2,
              let sr = Range(m.range(at: 1), in: s),
              let pr = Range(m.range(at: 2), in: s),
              let pct = Int(s[pr]),
              (0...100).contains(pct) else { return nil }
        return (String(s[sr]), pct)
    }

    // MARK: Energy consumers (top)

    /// Top processes by energy impact. `top -l 2` is required: the first sample
    /// establishes a baseline and the second carries the real per-interval figures.
    /// We read PIDs (not `top`'s truncated command column) and resolve full names
    /// via `ps`, so the list shows "WindowServer" rather than "WindowServ".
    static func energyConsumers(limit: Int = 6) -> [EnergyConsumer] {
        let r = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "power",
                                           "-stats", "pid,power", "-n", "20"])
        guard r.status == 0 else { return [] }
        let lines = r.output.components(separatedBy: "\n")
        // Parse rows after the LAST column header, i.e. the second sample block.
        guard let headerIdx = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }

        var ranked: [(pid: Int, impact: Double)] = []
        for line in lines[(headerIdx + 1)...] {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2, let pid = Int(tokens[0]),
                  let power = Double(tokens[tokens.count - 1]), power > 0 else { continue }
            ranked.append((pid, power))
            if ranked.count >= limit { break }
        }
        guard !ranked.isEmpty else { return [] }

        let names = processNames(for: ranked.map(\.pid))
        return ranked.map {
            EnergyConsumer(pid: $0.pid,
                           name: names[$0.pid] ?? "PID \($0.pid)",
                           impact: $0.impact)
        }
    }

    /// Maps PIDs to friendly executable names in one `ps` call.
    private static func processNames(for pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let r = Shell.run("/bin/ps", ["-p", pids.map(String.init).joined(separator: ","),
                                      "-o", "pid=,comm="])
        guard r.status == 0 else { return [:] }
        var map: [Int: String] = [:]
        for line in r.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            map[pid] = (String(parts[1]) as NSString).lastPathComponent
        }
        return map
    }

    // MARK: Lifecycle / health

    static func detail() -> BatteryDetail {
        var d = registryDetail()
        applySystemProfiler(into: &d)
        return d
    }

    /// Reads AppleSmartBattery straight from the IO registry — no text parsing.
    private static func registryDetail() -> BatteryDetail {
        var d = BatteryDetail()
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return d }
        defer { IOObjectRelease(service) }

        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        func int(_ key: String) -> Int? { (prop(key) as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (prop(key) as? NSNumber)?.boolValue ?? false }

        d.designCapacity = int("DesignCapacity")
        d.currentMaxCapacity = int("AppleRawMaxCapacity") ?? int("MaxCapacity")
        let currentCapacity = int("CurrentCapacity")
        d.hasBattery = bool("BatteryInstalled") || [
            d.designCapacity,
            d.currentMaxCapacity,
            currentCapacity
        ].contains { ($0 ?? 0) > 0 }

        guard d.hasBattery else { return d }

        d.cycleCount = int("CycleCount")
        d.isCharging = bool("IsCharging")
        d.fullyCharged = bool("FullyCharged")
        d.externalConnected = bool("ExternalConnected")
        if let t = int("Temperature") { d.temperatureC = Double(t) / 100 }
        if let v = int("Voltage") { d.voltageV = Double(v) / 1000 }

        // Time estimates: 65535 / 0 mean "still calculating".
        func minutes(_ key: String) -> Int? {
            guard let v = int(key), v > 0, v != 65535 else { return nil }
            return v
        }
        d.minutesToFull = minutes("AvgTimeToFull")
        d.minutesToEmpty = minutes("AvgTimeToEmpty") ?? minutes("TimeRemaining")
        return d
    }

    /// Fills in the values macOS surfaces in System Settings (the official health
    /// percentage, battery condition, and connected-adapter details).
    private static func applySystemProfiler(into d: inout BatteryDetail) {
        let r = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType"])
        guard r.status == 0 else { return }
        var inCharger = false
        for raw in r.output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("Information:") {
                inCharger = line.contains("AC Charger")
            }
            func value(after label: String) -> String? {
                guard line.hasPrefix(label) else { return nil }
                return line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            }
            if let v = value(after: "Cycle Count:") { d.cycleCount = Int(v) ?? d.cycleCount }
            else if let v = value(after: "Condition:") { d.condition = v }
            else if let v = value(after: "Maximum Capacity:") {
                d.maxCapacityPercent = Int(v.filter(\.isNumber)) ?? d.maxCapacityPercent
            }
            else if inCharger, let v = value(after: "Connected:") { d.adapterConnected = v == "Yes" }
            else if inCharger, let v = value(after: "Wattage (W):") { d.adapterWatts = Int(v) }
            else if inCharger, let v = value(after: "Name:") { d.adapterName = v }
        }
    }

    /// "1h 23m" style duration from a minute count.
    static func durationString(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }
}
