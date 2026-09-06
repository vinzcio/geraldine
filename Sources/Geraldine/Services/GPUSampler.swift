import Foundation
import IOKit

struct GPUReading {
    enum Counter: String, CaseIterable {
        case device = "Device Utilization %"
        case activity = "GPU Activity(%)"
    }

    let id: UInt64
    let name: String
    let activity: Double?
    let counter: Counter?
    let poweredOff: Bool
}

enum GPUSampler {
    /// nil means discovery failed; an empty array means successful discovery with
    /// no devices. IDs identify device registrations, never cores or array slots.
    /// Reading registry properties does not submit Metal work to a GPU.
    static func sample() -> [GPUReading]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"),
                                          &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [GPUReading] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else {
                // Partial discovery cannot establish that other devices left.
                return nil
            }
            let statistics = property(service, "PerformanceStatistics") as? [String: Any] ?? [:]
            let power = property(service, "AGCInfo") as? [String: Any] ?? [:]
            let poweredOff = (power["poweredOffByAGC"] as? NSNumber)?.boolValue == true
            let counter = GPUReading.Counter.allCases.first {
                utilization(from: statistics, key: $0.rawValue) != nil
            }
            // Intel/AMD model names can live on the PCI parent.
            let model = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "model" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            )
            readings.append(GPUReading(
                id: id, name: modelName(model) ?? "Graphics Processor",
                activity: poweredOff ? nil : counter.flatMap { utilization(from: statistics, key: $0.rawValue) },
                counter: counter, poweredOff: poweredOff
            ))
        }
        guard IOIteratorIsValid(iterator) != 0 else { return nil }
        return readings
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func modelName(_ value: Any?) -> String? {
        let text: String?
        if let data = value as? Data {
            text = String(data: data, encoding: .utf8)
        } else {
            text = value as? String
        }
        let name = text?.replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    static func utilization(from statistics: [String: Any]) -> Double? {
        GPUReading.Counter.allCases.lazy.compactMap {
            utilization(from: statistics, key: $0.rawValue)
        }.first
    }

    private static func utilization(from statistics: [String: Any], key: String) -> Double? {
        guard let number = statistics[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let percent = number.doubleValue
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent / 100
    }
}
