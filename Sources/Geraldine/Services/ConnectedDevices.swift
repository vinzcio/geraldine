import Foundation
import AppKit

/// One device attached to this Mac — an external drive, a Bluetooth peripheral,
/// or a USB-connected iPhone/iPad. Mirrors CleanMyMac's "Connected Devices" module
/// (peripherals attached to the Mac), not a scan of the local network.
struct ConnectedDevice: Identifiable, Equatable {
    enum Kind: Equatable {
        case drive, iosDevice, bluetooth

        var icon: String {
            switch self {
            case .drive:     return "externaldrive.fill"
            case .iosDevice: return "iphone"
            case .bluetooth: return "dot.radiowaves.left.and.right"
            }
        }

        /// Lower sorts first (after low-battery items).
        var rank: Int {
            switch self {
            case .drive:     return 0
            case .iosDevice: return 1
            case .bluetooth: return 2
            }
        }
    }

    let id: String
    var name: String
    var kind: Kind
    var battery: Double?      // 0…1, nil if not reported
    var detail: String
    var volumeURL: URL?       // present when the device can be ejected

    var lowBattery: Bool {
        guard battery != nil else { return false }
        return MetricPresentationPolicy.batteryChargeState(level: battery) != .good
    }
    var ejectable: Bool { volumeURL != nil }
}

@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var scanning = false
    @Published private(set) var ejectErrors: [String: String] = [:]
    @Published private(set) var ejectingIDs: Set<String> = []

    private var observing = false

    /// Begin watching for volume mount/unmount events and do an initial scan.
    func start() {
        guard !observing else { return }
        observing = true
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(self, selector: #selector(volumesChanged), name: name, object: nil)
        }
        refresh()
    }

    @objc private func volumesChanged() { refresh() }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let drives = Self.scanDrives()
            let profile = Self.scanSystemProfiler()    // Bluetooth + USB iOS in one call
            let all = (drives + profile.ios + profile.bluetooth).sorted(by: Self.order)
            await MainActor.run {
                self.devices = all
                let currentIDs = Set(all.map(\.id))
                self.ejectErrors = self.ejectErrors.filter { currentIDs.contains($0.key) }
                self.scanning = false
            }
        }
    }

    func eject(_ device: ConnectedDevice) {
        guard let url = device.volumeURL, !ejectingIDs.contains(device.id) else { return }
        ejectErrors[device.id] = nil
        ejectingIDs.insert(device.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            defer { ejectingIDs.remove(device.id) }
            let errorMessage = await Task.detached(priority: .userInitiated) {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil as String?
                } catch {
                    return Self.ejectMessage(for: error)
                }
            }.value
            if let errorMessage {
                ejectErrors[device.id] = "Could not eject: \(errorMessage)"
            } else {
                refresh()
            }
        }
    }

    func isEjecting(_ device: ConnectedDevice) -> Bool {
        ejectingIDs.contains(device.id)
    }

    func ejectError(for device: ConnectedDevice) -> String? {
        ejectErrors[device.id]
    }

    nonisolated private static func order(_ a: ConnectedDevice, _ b: ConnectedDevice) -> Bool {
        if a.lowBattery != b.lowBattery { return a.lowBattery }       // low battery floats to top
        if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    nonisolated private static func ejectMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "macOS reported an unknown error." : message
    }

    // MARK: - External drives

    nonisolated private static func scanDrives() -> [ConnectedDevice] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }

        var out: [ConnectedDevice] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let ejectable = v.volumeIsEjectable ?? false
            let removable = v.volumeIsRemovable ?? false
            // External storage only — skip the internal boot drive and network shares.
            guard ejectable || removable else { continue }

            let name = v.volumeName ?? url.lastPathComponent
            let total = Double(v.volumeTotalCapacity ?? 0)
            let free = Double(v.volumeAvailableCapacity ?? 0)
            let detail = total > 0 ? "\(Fmt.size(free)) free of \(Fmt.size(total))" : "Mounted"
            out.append(ConnectedDevice(id: "vol:\(url.path)", name: name, kind: .drive,
                                       battery: nil, detail: detail,
                                       volumeURL: ejectable ? url : nil))
        }
        return out
    }

    // MARK: - Bluetooth + USB (system_profiler)

    nonisolated private static func scanSystemProfiler()
        -> (bluetooth: [ConnectedDevice], ios: [ConnectedDevice]) {
        let r = Shell.run("/usr/sbin/system_profiler",
                          ["SPBluetoothDataType", "SPUSBDataType", "-json"])
        guard r.status == 0,
              let data = r.output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], []) }
        return (parseBluetooth(root), parseUSB(root))
    }

    nonisolated private static func parseBluetooth(_ root: [String: Any]) -> [ConnectedDevice] {
        guard let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [ConnectedDevice] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for wrapper in connected {
                for (name, value) in wrapper {
                    guard let info = value as? [String: Any] else { continue }
                    let battery = batteryLevel(info)
                    // The adjacent indicator owns the battery value and its chart-matched
                    // color; repeating it here creates a second, neutral-colored readout.
                    let detail = "Connected"
                    out.append(ConnectedDevice(id: "bt:\(name)", name: name, kind: .bluetooth,
                                               battery: battery, detail: detail, volumeURL: nil))
                }
            }
        }
        return out
    }

    nonisolated private static func batteryLevel(_ info: [String: Any]) -> Double? {
        // Single-cell devices (mouse, keyboard, headphones) report one of these.
        for key in ["device_batteryLevelMain", "device_batteryLevelSingle", "device_batteryLevel"] {
            if let raw = info[key] as? String, let pct = percent(raw) { return pct }
        }
        // Multi-cell devices (AirPods) report left/right/case — surface the lowest.
        let multi = ["device_batteryLevelLeft", "device_batteryLevelRight", "device_batteryLevelCase"]
            .compactMap { info[$0] as? String }
            .compactMap(percent)
        return multi.min()
    }

    /// "85%" → 0.85
    nonisolated private static func percent(_ raw: String) -> Double? {
        let digits = raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))
        guard let value = Double(digits) else { return nil }
        return max(0, min(1, value / 100))
    }

    nonisolated private static func parseUSB(_ root: [String: Any]) -> [ConnectedDevice] {
        guard let controllers = root["SPUSBDataType"] as? [[String: Any]] else { return [] }
        var found: [ConnectedDevice] = []
        var seen = Set<String>()
        func walk(_ items: [[String: Any]]) {
            for item in items {
                let name = (item["_name"] as? String) ?? ""
                let lower = name.lowercased()
                if lower.contains("iphone") || lower.contains("ipad") || lower.contains("ipod") {
                    let id = "ios:\((item["serial_num"] as? String) ?? name)"
                    if seen.insert(id).inserted {
                        found.append(ConnectedDevice(id: id, name: name, kind: .iosDevice,
                                                     battery: nil, detail: "Connected Via USB",
                                                     volumeURL: nil))
                    }
                }
                if let children = item["_items"] as? [[String: Any]] { walk(children) }
            }
        }
        for controller in controllers {
            if let items = controller["_items"] as? [[String: Any]] { walk(items) }
        }
        return found
    }
}
