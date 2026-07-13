import SwiftUI
import CThermal

enum Thermal {
    struct Sensor: Identifiable, Hashable, Sendable {
        let name: String
        let temp: Double

        var id: String { name }
    }

    struct Reading: Sendable {
        var cpu: Double          // headline CPU/SoC temperature
        var cpuAverage: Double   // average of CPU/SoC candidate sensors
        var cpuPeak: Double      // hottest HID CPU/SoC candidate sensor
        var hidCPUCandidateCount: Int
        var cpuSource: String
        var peak: Double         // hottest sensor
        var battery: Double?
        var storage: Double?
        var sensors: [Sensor]
        var available: Bool { !sensors.isEmpty }

        static let empty = Reading(cpu: 0, cpuAverage: 0, cpuPeak: 0, hidCPUCandidateCount: 0, cpuSource: "Unavailable",
                                   peak: 0, battery: nil, storage: nil, sensors: [])
    }

    private static let smcSensorNamePrefix = "SMC "

    private struct SMCSelection {
        let temp: Double
        let source: String
    }

    private static let cleanMyMacPrimarySMCKey = "TC0D"

    private static let cleanMyMacAppleSiliconSMCKeys = [
        "Tp00", "Tp01", "Tp02", "Tp04", "Tp05", "Tp06", "Tp08", "Tp09", "Tp0A",
        "Tp0a", "Tp0b", "Tp0c", "Tp0C", "Tp0D", "Tp0E", "Tp0f", "Tp0g", "Tp0G",
        "Tp0H", "Tp0I", "Tp0j", "Tp0k", "Tp0K", "Tp0L", "Tp0M", "Tp0O", "Tp0P",
        "Tp0Q", "Tp0S", "Tp0T", "Tp0U", "Tp0W", "Tp0X", "Tp0Y", "Tp17", "Tp18",
        "Tp1B", "Tp1C", "Tp1F", "Tp1G", "Tp1h", "Tp1i", "Tp1J", "Tp1K", "Tp1l",
        "Tp1m", "Tp1N", "Tp1O", "Tp1p", "Tp1q", "Tp1t", "Tp1u", "Tp2H", "Tp2I"
    ]

    private static let cleanMyMacFallbackAverageSMCKeys = [
        "TC0D", "TC0P", "TCAD", "TC0H", "TC0F", "TCAH", "TCBH"
    ]

    private static let cleanMyMacFinalSMCFallbackKeys = ["TCDX"]

    private static let cleanMyMacMaximumPlausibleSMC = 127.0
    private static let cleanMyMacAverageThreshold = 20.0

    static func read() -> Reading {
        let maxCount = 96, stride = 64
        var temps = [Double](repeating: 0, count: maxCount)
        var names = [CChar](repeating: 0, count: maxCount * stride)
        let count = Int(thermal_read(&temps, &names, Int32(stride), Int32(maxCount)))

        var sensors: [Sensor] = []
        appendSensors(count: count, temps: temps, names: names, stride: stride, into: &sensors)

        var smcTemps = [Double](repeating: 0, count: maxCount)
        var smcNames = [CChar](repeating: 0, count: maxCount * stride)
        let smcCount = Int(smc_thermal_read(&smcTemps, &smcNames, Int32(stride), Int32(maxCount)))
        appendSensors(count: smcCount, temps: smcTemps, names: smcNames, stride: stride, into: &sensors)

        guard !sensors.isEmpty else { return .empty }
        return summarize(sensors)
    }

    private static func appendSensors(count: Int, temps: [Double], names: [CChar], stride: Int, into sensors: inout [Sensor]) {
        names.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                let name = String(cString: base + i * stride)
                sensors.append(Sensor(name: name.isEmpty ? "Sensor \(i)" : name, temp: temps[i]))
            }
        }
    }

    private static func summarize(_ sensors: [Sensor]) -> Reading {
        func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

        // On Apple Silicon, "tdie" sensors are the CPU/SoC die temperatures.
        let hidSensors = sensors.filter { !$0.name.hasPrefix(smcSensorNamePrefix) }
        let dies = hidSensors.filter { $0.name.lowercased().contains("tdie") }.map(\.temp)
        let socish = hidSensors.filter {
            let n = $0.name.lowercased()
            return n.contains("pmu") || n.contains("soc") || n.contains("cpu") || n.contains("core")
        }.map(\.temp)

        let cpuCandidates = !dies.isEmpty ? dies : (!socish.isEmpty ? socish : hidSensors.map(\.temp))
        let cpuPeak = cpuCandidates.max() ?? 0
        let cpuAverage = avg(cpuCandidates)
        let hidCPUCandidateCount = cpuCandidates.count
        let hidSource = !dies.isEmpty ? "HID tdie peak" : "HID sensor peak"
        let cleanMyMacSMC = cleanMyMacSMCHeadline(from: sensors)
        let cpu = cleanMyMacSMC?.temp ?? cpuPeak
        let cpuSource = cleanMyMacSMC?.source ?? hidSource
        let peak = sensors.map(\.temp).max() ?? 0
        let battery = sensors.first { $0.name.lowercased().contains("battery") }?.temp
        let storage = sensors.first {
            let n = $0.name.lowercased(); return n.contains("nand") || n.contains("ssd")
        }?.temp

        return Reading(cpu: cpu, cpuAverage: cpuAverage, cpuPeak: cpuPeak, hidCPUCandidateCount: hidCPUCandidateCount, cpuSource: cpuSource,
                       peak: peak, battery: battery, storage: storage,
                       sensors: sensors.sorted { $0.temp > $1.temp })
    }

    private static func cleanMyMacSMCHeadline(from sensors: [Sensor]) -> SMCSelection? {
        let smcByKey = smcTemperatureByKey(from: sensors)

        if let primary = smcByKey[cleanMyMacPrimarySMCKey], isCleanMyMacPlausibleSMC(primary) {
            return SMCSelection(temp: primary, source: smcSensorName(for: cleanMyMacPrimarySMCKey))
        }

        if let average = cleanMyMacAverage(keys: cleanMyMacAppleSiliconSMCKeys, values: smcByKey) {
            return SMCSelection(temp: average, source: "SMC Apple Silicon avg")
        }

        if let fallback = cleanMyMacAverage(keys: cleanMyMacFallbackAverageSMCKeys, values: smcByKey) {
            return SMCSelection(temp: fallback, source: "SMC fallback avg")
        }

        if let fallback = cleanMyMacAverage(keys: cleanMyMacFinalSMCFallbackKeys, values: smcByKey) {
            return SMCSelection(temp: fallback, source: "SMC final fallback avg")
        }

        return nil
    }

    private static func smcTemperatureByKey(from sensors: [Sensor]) -> [String: Double] {
        var values: [String: Double] = [:]
        for sensor in sensors where sensor.name.hasPrefix(smcSensorNamePrefix) {
            let key = String(sensor.name.dropFirst(smcSensorNamePrefix.count))
            if values[key] == nil {
                values[key] = sensor.temp
            }
        }
        return values
    }

    private static func cleanMyMacAverage(keys: [String], values: [String: Double]) -> Double? {
        let valid = keys.compactMap { values[$0] }
            .filter { $0 > cleanMyMacAverageThreshold && $0.rounded(.down) <= cleanMyMacMaximumPlausibleSMC }
        guard !valid.isEmpty else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }

    private static func isCleanMyMacPlausibleSMC(_ temp: Double) -> Bool {
        temp > 0 && temp.rounded(.down) <= cleanMyMacMaximumPlausibleSMC
    }

    private static func smcSensorName(for key: String) -> String {
        smcSensorNamePrefix + key
    }

    /// Hot/critical bands beyond the shared Theme status colors.
    static let hot = Theme.orange
    static let critical = Theme.plum

    /// Fixed temperature-scale gradient stops, top (critical) → bottom (cool).
    static let scaleColors: [Color] = [Theme.Chart.plum, Theme.Chart.red, Theme.Chart.orange,
                                       Theme.Chart.amber, Theme.Chart.green]
    static let chartDomain: ClosedRange<Double> = 40...105

    static func color(_ celsius: Double) -> Color {
        switch celsius {
        case ..<55:   return Theme.good   // green  — cool / idle
        case ..<70:   return Theme.warn   // amber  — normal working temp
        case ..<85:   return hot          // orange — hot, working hard
        case ..<100:  return Theme.bad    // red    — very hot
        default:      return critical     // purple — critical / throttling
        }
    }

    static func chartColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<55:   return Theme.Chart.green
        case ..<70:   return Theme.Chart.amber
        case ..<85:   return Theme.Chart.orange
        case ..<100:  return Theme.Chart.red
        default:      return Theme.Chart.plum
        }
    }
}
