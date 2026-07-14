import Foundation
import IOKit
import OSLog

private let keyboardTransportLog = Logger(
    subsystem: "com.vincent.geraldine",
    category: "KeyboardTransport"
)

enum KeyboardTransport: String, CaseIterable, Hashable {
    case wired
    case wireless24GHz
    case bluetooth
    case disconnected

    var label: String {
        switch self {
        case .wired: "Wired USB"
        case .wireless24GHz: "2.4 GHz"
        case .bluetooth: "Bluetooth"
        case .disconnected: "Disconnected"
        }
    }

    var systemImage: String {
        switch self {
        case .wired: "cable.connector"
        case .wireless24GHz: "antenna.radiowaves.left.and.right"
        case .bluetooth: "wave.3.right"
        case .disconnected: "keyboard.badge.ellipsis"
        }
    }
}

enum KeyboardTransportHUDPreferences {
    static let enabledKey = "keyboardTransportHUDEnabled"
}

struct KeyboardTransportActivity: Equatable {
    var inputReportCount: UInt64
    var lastInputReportTime: UInt64
}

struct KeyboardTransportSample: Equatable {
    var activities: [KeyboardTransport: KeyboardTransportActivity]

    static let empty = KeyboardTransportSample(activities: [:])
}

enum KeyboardTransportClassifier {
    private static let wiredProduct = "Akko Multi-modes Keyboard-B"
    private static let receiverProduct = "Akko 2.4G Wireless Keyboard"

    static func classify(product: String, transport: String) -> KeyboardTransport? {
        let normalizedProduct = product.lowercased()
        let normalizedTransport = transport.lowercased()

        if normalizedTransport.contains("bluetooth"),
           normalizedProduct.contains("akko") || normalizedProduct.contains("pc98") {
            return .bluetooth
        }
        if product == wiredProduct { return .wired }
        if product == receiverProduct { return .wireless24GHz }
        return nil
    }
}

/// Turns IORegistry counter snapshots into confirmed transport changes. The
/// first snapshot establishes a silent baseline so launching Geraldine never
/// produces a stale or misleading HUD.
struct KeyboardTransportReducer {
    private(set) var currentTransport: KeyboardTransport?
    private var previousSample: KeyboardTransportSample?

    mutating func consume(_ sample: KeyboardTransportSample) -> KeyboardTransport? {
        guard let previousSample else {
            self.previousSample = sample
            currentTransport = mostRecentlyActiveTransport(in: sample)
            return nil
        }

        defer { self.previousSample = sample }

        if sample.activities.isEmpty {
            guard currentTransport != nil else { return nil }
            currentTransport = nil
            return .disconnected
        }

        if let currentTransport, sample.activities[currentTransport] == nil {
            self.currentTransport = nil
            return .disconnected
        }

        let activeCandidates = sample.activities.compactMap { transport, activity -> (KeyboardTransport, KeyboardTransportActivity)? in
            guard let previous = previousSample.activities[transport],
                  activity.inputReportCount > previous.inputReportCount else {
                return nil
            }
            return (transport, activity)
        }

        guard let confirmed = activeCandidates.max(by: {
            if $0.1.lastInputReportTime == $1.1.lastInputReportTime {
                return $0.1.inputReportCount < $1.1.inputReportCount
            }
            return $0.1.lastInputReportTime < $1.1.lastInputReportTime
        })?.0 else {
            return nil
        }

        guard confirmed != currentTransport else { return nil }
        currentTransport = confirmed
        return confirmed
    }

    private func mostRecentlyActiveTransport(in sample: KeyboardTransportSample) -> KeyboardTransport? {
        sample.activities.max(by: {
            if $0.value.lastInputReportTime == $1.value.lastInputReportTime {
                return $0.value.inputReportCount < $1.value.inputReportCount
            }
            return $0.value.lastInputReportTime < $1.value.lastInputReportTime
        })?.key
    }
}

@MainActor
final class KeyboardTransportMonitor {
    private var timer: Timer?
    private var reducer = KeyboardTransportReducer()
    private var onChange: ((KeyboardTransport) -> Void)?
    private var hasLoggedBaseline = false

    func start(onChange: @escaping (KeyboardTransport) -> Void) {
        guard timer == nil else { return }
        self.onChange = onChange
        reducer = KeyboardTransportReducer()
        hasLoggedBaseline = false
        keyboardTransportLog.notice("Monitor started")
        sample()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
        reducer = KeyboardTransportReducer()
        hasLoggedBaseline = false
        keyboardTransportLog.notice("Monitor stopped")
    }

    private func sample() {
        let snapshot = IORegistryKeyboardTransportReader.read()
        if !hasLoggedBaseline {
            hasLoggedBaseline = true
            let transports = snapshot.activities.keys.map(\.rawValue).sorted().joined(separator: ",")
            keyboardTransportLog.notice("Baseline transports: \(transports, privacy: .public)")
        }
        if let change = reducer.consume(snapshot) {
            keyboardTransportLog.notice("Confirmed transport: \(change.rawValue, privacy: .public)")
            onChange?(change)
        }
    }
}

private enum IORegistryKeyboardTransportReader {
    static func read() -> KeyboardTransportSample {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDInterface"),
            &iterator
        ) == KERN_SUCCESS else {
            return .empty
        }
        defer { IOObjectRelease(iterator) }

        var activities: [KeyboardTransport: KeyboardTransportActivity] = [:]
        while case let interface = IOIteratorNext(iterator), interface != 0 {
            defer { IOObjectRelease(interface) }

            var device: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &device) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(device) }

            guard let transport = keyboardTransport(for: device),
                  let debugState = property("DebugState", from: device) as? [String: Any],
                  let reportCount = number("InputReportCount", in: debugState) else {
                continue
            }

            let reportTime = number("InputReportTime", in: debugState) ?? 0
            var activity = activities[transport] ?? KeyboardTransportActivity(
                inputReportCount: 0,
                lastInputReportTime: 0
            )
            activity.inputReportCount += reportCount
            activity.lastInputReportTime = max(activity.lastInputReportTime, reportTime)
            activities[transport] = activity
        }

        return KeyboardTransportSample(activities: activities)
    }

    private static func keyboardTransport(for service: io_registry_entry_t) -> KeyboardTransport? {
        let product = property("Product", from: service) as? String ?? ""
        let transport = property("Transport", from: service) as? String ?? ""
        return KeyboardTransportClassifier.classify(product: product, transport: transport)
    }

    private static func property(_ key: String, from service: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func number(_ key: String, in dictionary: [String: Any]) -> UInt64? {
        (dictionary[key] as? NSNumber)?.uint64Value
    }
}
