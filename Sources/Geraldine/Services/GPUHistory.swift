import Foundation

struct GPUDeviceHistory: Identifiable {
    enum State: String {
        case available
        case poweredOff = "Powered Off"
        case unavailable = "Unavailable"
        case disconnected = "Disconnected"
    }

    let id: UInt64
    let name: String
    let ordinal: Int
    var displayName: String { ordinal == 1 ? name : "\(name) (\(ordinal))" }
    var state: State = .unavailable
    var activity: Double?
    var samples: [MetricSample] = []
    fileprivate var lastSeen: TimeInterval
    fileprivate var counter: GPUReading.Counter?
    fileprivate var segmentID = UUID()
}

/// Session-only histories use the same window and bound as other live charts.
/// Discovery order changes and load changes never reorder existing rows.
struct GPUHistory {
    private(set) var devices: [GPUDeviceHistory] = []
    private(set) var selectedDeviceID: UInt64?
    var selectedDevice: GPUDeviceHistory? { devices.first { $0.id == selectedDeviceID } }

    mutating func selectDevice(_ id: UInt64) {
        guard devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = id
    }

    mutating func apply(_ readings: [GPUReading]?, at timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        if let readings {
            for reading in readings where !devices.contains(where: { $0.id == reading.id }) {
                let ordinal = (devices.filter { $0.name == reading.name }.map(\.ordinal).max() ?? 0) + 1
                devices.append(GPUDeviceHistory(id: reading.id, name: reading.name, ordinal: ordinal, lastSeen: timestamp))
            }
        }
        // Pin once per monitoring session; loss of the selected device never
        // silently substitutes a different GPU in a compact widget or status item.
        if selectedDeviceID == nil { selectedDeviceID = devices.first?.id }
        for index in devices.indices {
            let reading = readings?.first { $0.id == devices[index].id }
            let state: GPUDeviceHistory.State
            if let reading {
                devices[index].lastSeen = timestamp
                state = reading.poweredOff ? .poweredOff : (reading.activity == nil ? .unavailable : .available)
            } else {
                state = readings == nil ? .unavailable : .disconnected
            }
            // Even one missed sample is a real gap. A changed counter also starts
            // a separate segment instead of joining different measurements.
            if state != .available || devices[index].state != .available || devices[index].counter != reading?.counter {
                devices[index].segmentID = UUID()
            }
            devices[index].state = state
            devices[index].activity = state == .available ? reading?.activity : nil
            devices[index].counter = reading?.counter
            devices[index].samples.removeAll { $0.timestamp < timestamp - SystemMonitor.liveHistoryWindow }
            if let activity = devices[index].activity {
                SystemMonitor.appendMetricSample(
                    &devices[index].samples, value: activity, timestamp: timestamp,
                    retaining: SystemMonitor.liveHistoryWindow, sessionID: devices[index].segmentID
                )
            }
        }
        // Removed devices leave once their existing live history window expires.
        devices.removeAll {
            $0.state == .disconnected && $0.lastSeen < timestamp - SystemMonitor.liveHistoryWindow
        }
    }
}
