import Foundation
import Combine
import Network
import CoreWLAN
import CoreLocation
import AppKit

/// Live view of the Mac's own network connection — connection type, Wi-Fi name,
/// security, signal, link speed — plus an on-demand throughput test.
///
/// This mirrors CleanMyMac's "Network" menu module: it describes *your* connection,
/// not other devices on the LAN. Live up/down byte rates come from `SystemMonitor`;
/// this type owns the Wi-Fi metadata and the speed test.
///
/// Note: macOS gates the Wi-Fi name (SSID) behind Location Services since Sonoma, so
/// the network name only appears once the user grants location access.
@MainActor
final class NetworkMonitor: NSObject, ObservableObject {
    enum Connection: Equatable {
        case wifi, ethernet, other, offline

        var label: String {
            switch self {
            case .wifi:     return "Wi-Fi"
            case .ethernet: return "Ethernet"
            case .other:    return "Connected"
            case .offline:  return "Offline"
            }
        }

        var icon: String {
            switch self {
            case .wifi:     return "wifi"
            case .ethernet: return "cable.connector"
            case .other:    return "network"
            case .offline:  return "wifi.slash"
            }
        }
    }

    struct Security: Equatable {
        var label: String
        var strong: Bool
        static let unknown = Security(label: "—", strong: true)
    }

    /// Whether macOS will hand us the Wi-Fi name yet. `undetermined` means we can still
    /// prompt; `denied` means the only way back is System Settings.
    enum NameAccess: Equatable { case authorized, undetermined, denied }

    enum SpeedPhase: Equatable { case download, upload }

    enum SpeedTest: Equatable {
        case idle
        case running(SpeedPhase)
        case done(down: Double, up: Double)   // Mbps
        case failed
    }

    @Published private(set) var connection: Connection = .other
    @Published private(set) var online = true
    @Published private(set) var ssid: String?
    @Published private(set) var security = Security.unknown
    @Published private(set) var rssi: Int?            // dBm
    @Published private(set) var linkRateMbps: Double?
    @Published private(set) var locationAuthorized = false
    @Published private(set) var nameAccess: NameAccess = .undetermined
    @Published private(set) var speedTest: SpeedTest = .idle

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.vincent.geraldine.netpath")
    private let wifiClient = CWWiFiClient.shared()
    private lazy var locationManager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        return m
    }()
    private var timer: Timer?

    override init() {
        super.init()
        refreshNameAccess()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connection = Self.classify(path)
            let online = path.status == .satisfied
            Task { @MainActor in self?.apply(connection: connection, online: online) }
        }
        pathMonitor.start(queue: pathQueue)
        refreshWiFi()
    }

    func start(interval: TimeInterval = 3) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWiFi() }
        }
        t.tolerance = 1
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 0…1 signal strength derived from RSSI (-100 dBm → 0, -50 dBm → 1).
    var signalFraction: Double? {
        guard let rssi else { return nil }
        return max(0, min(1, Double(rssi + 100) / 50))
    }

    /// The headline name to show: the Wi-Fi SSID when available, else the connection kind.
    var displayName: String { ssid ?? connection.label }

    private func apply(connection: Connection, online: Bool) {
        self.connection = connection
        self.online = online
        refreshWiFi()
    }

    func refreshWiFi() {
        guard let iface = wifiClient.interface() else {
            ssid = nil; rssi = nil; linkRateMbps = nil; security = .unknown
            return
        }
        // SSID only resolves with Location authorization on macOS 14+.
        ssid = (connection == .wifi && locationAuthorized) ? iface.ssid() : nil
        let r = iface.rssiValue()
        rssi = (connection == .wifi && r != 0) ? r : nil
        let rate = iface.transmitRate()
        linkRateMbps = (connection == .wifi && rate > 0) ? rate : nil
        security = connection == .wifi ? Self.security(from: iface.security()) : .unknown
    }

    // MARK: - Wi-Fi name access (Location)

    /// True once the OS will tell us the network name. When false, offer `requestNameAccess()`.
    var canShowName: Bool { locationAuthorized }

    func refreshNameAccess() {
        let status = locationManager.authorizationStatus
        locationAuthorized = Self.isAuthorized(status)
        nameAccess = Self.nameAccess(for: status)
        refreshWiFi()
    }

    /// Ask macOS to register Geraldine for Location access so System Settings can show it.
    func requestNameAccess() {
        refreshNameAccess()
        switch nameAccess {
        case .undetermined:
            NSApp.activate(ignoringOtherApps: true)
            locationManager.requestWhenInUseAuthorization()
            locationManager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refreshNameAccess()
            }
        case .denied:
            Self.openLocationSettings()
        case .authorized:
            break
        }
    }

    func requestNameAccessAndOpenSettings() {
        requestNameAccess()
        Self.openLocationSettings()
    }

    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    private static func nameAccess(for status: CLAuthorizationStatus) -> NameAccess {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .notDetermined:                          return .undetermined
        default:                                      return .denied   // .denied, .restricted
        }
    }

    // MARK: - Classification

    private nonisolated static func classify(_ path: NWPath) -> Connection {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .other
    }

    private static func security(from security: CWSecurity) -> Security {
        switch security {
        case .none:
            return Security(label: "Open", strong: false)
        case .WEP, .dynamicWEP:
            return Security(label: "WEP", strong: false)
        case .wpaPersonal, .wpaPersonalMixed, .wpaEnterprise, .wpaEnterpriseMixed:
            return Security(label: "WPA", strong: false)
        case .wpa2Personal, .wpa2Enterprise, .personal, .enterprise:
            return Security(label: "WPA2", strong: true)
        case .wpa3Personal, .wpa3Enterprise, .wpa3Transition:
            return Security(label: "WPA3", strong: true)
        case .OWE, .oweTransition:
            return Security(label: "Enhanced Open", strong: true)
        default:
            return .unknown
        }
    }

    // MARK: - Speed test

    func runSpeedTest() {
        if case .running = speedTest { return }
        speedTest = .running(.download)
        Task {
            do {
                let down = try await Self.measureDownload()
                self.speedTest = .running(.upload)
                let up = (try? await Self.measureUpload()) ?? 0
                self.speedTest = .done(down: down, up: up)
            } catch {
                self.speedTest = .failed
            }
        }
    }

    func resetSpeedTest() { speedTest = .idle }

    /// Download throughput in Mbps, measured against Cloudflare's public endpoint.
    nonisolated private static func measureDownload() async throws -> Double {
        let bytes = 25_000_000
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let seconds = max(Date().timeIntervalSince(start), 0.001)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return Double(data.count) * 8 / seconds / 1_000_000
    }

    /// Upload throughput in Mbps, measured against Cloudflare's public endpoint.
    nonisolated private static func measureUpload() async throws -> Double {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { throw URLError(.badURL) }
        let payload = Data(count: 10_000_000)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let start = Date()
        let (_, response) = try await URLSession.shared.upload(for: request, from: payload)
        let seconds = max(Date().timeIntervalSince(start), 0.001)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 500) < 400 else {
            throw URLError(.badServerResponse)
        }
        return Double(payload.count) * 8 / seconds / 1_000_000
    }
}

extension NetworkMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshNameAccess()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.refreshNameAccess()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.refreshNameAccess()
        }
    }
}
