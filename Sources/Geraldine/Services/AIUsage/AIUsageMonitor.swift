import AppKit
import Combine
import Foundation

/// Connects local coding-assistant sign-ins and keeps remaining-usage snapshots
/// for the menu-bar popover. Disabled providers stay disconnected and do no I/O.
@MainActor
final class AIUsageMonitor: ObservableObject {
    @Published private(set) var snapshots: [AICodingProvider: AIUsageSnapshot]
    @Published private(set) var lastRefresh: Date?

    private let defaults: UserDefaults
    private let transport: any AIUsageTransporting
    private let now: () -> Date
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var inFlight = Set<AICodingProvider>()

    static let connectedKey = "geraldine.aiUsage.connected"
    static let refreshInterval: TimeInterval = 5 * 60
    static let staleInterval: TimeInterval = 30

    init(defaults: UserDefaults = .standard,
         transport: any AIUsageTransporting = URLSessionAIUsageTransport(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        var initial: [AICodingProvider: AIUsageSnapshot] = [:]
        for provider in AICodingProvider.allCases {
            initial[provider] = .disconnected(provider)
        }
        snapshots = initial
        restoreConnections()
    }

    func snapshot(for provider: AICodingProvider) -> AIUsageSnapshot {
        snapshots[provider] ?? .disconnected(provider)
    }

    func isConnected(_ provider: AICodingProvider) -> Bool {
        snapshot(for: provider).status.isConnected
    }

    func start() {
        guard timer == nil else { return }
        refreshConnected()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshConnected() }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        inFlight.removeAll()
    }

    func refreshIfStale() {
        let staleBefore = now().addingTimeInterval(-Self.staleInterval)
        if let lastRefresh, lastRefresh > staleBefore { return }
        refreshConnected()
    }

    func refreshConnected() {
        let providers = AICodingProvider.allCases.filter { isConnected($0) }
        guard !providers.isEmpty else { return }
        refresh(providers)
    }

    func connect(_ provider: AICodingProvider) {
        persistConnected(provider, connected: true)
        snapshots[provider] = .loading(provider, preserving: snapshots[provider])
        refresh([provider])
        NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
    }

    func disconnect(_ provider: AICodingProvider) {
        persistConnected(provider, connected: false)
        snapshots[provider] = .disconnected(provider)
        NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
    }

    /// Keep fetch state aligned with visible popover tiles. Showing a tile
    /// connects it; hiding disconnects it. Already-matching providers are left
    /// alone so a layout republish does not restart in-flight fetches.
    func syncShownProviders(_ shown: Set<AICodingProvider>) {
        var toConnect: [AICodingProvider] = []
        for provider in AICodingProvider.allCases {
            let shouldConnect = shown.contains(provider)
            if shouldConnect && !isConnected(provider) {
                persistConnected(provider, connected: true)
                snapshots[provider] = .loading(provider, preserving: snapshots[provider])
                toConnect.append(provider)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
            } else if !shouldConnect && isConnected(provider) {
                persistConnected(provider, connected: false)
                snapshots[provider] = .disconnected(provider)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
            }
        }
        if !toConnect.isEmpty {
            refresh(toConnect)
        }
    }

    func openSignIn(for provider: AICodingProvider) {
        for name in provider.applicationNames {
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        NSWorkspace.shared.open(provider.fallbackURL)
    }

    private func restoreConnections() {
        let stored = Set(defaults.stringArray(forKey: Self.connectedKey) ?? [])
        for provider in AICodingProvider.allCases where stored.contains(provider.rawValue) {
            snapshots[provider] = .loading(provider)
        }
    }

    private func persistConnected(_ provider: AICodingProvider, connected: Bool) {
        var stored = Set(defaults.stringArray(forKey: Self.connectedKey) ?? [])
        if connected {
            stored.insert(provider.rawValue)
        } else {
            stored.remove(provider.rawValue)
        }
        defaults.set(Array(stored).sorted(), forKey: Self.connectedKey)
    }

    private func refresh(_ providers: [AICodingProvider]) {
        let pending = providers.filter { !inFlight.contains($0) }
        guard !pending.isEmpty else { return }
        inFlight.formUnion(pending)
        for provider in pending {
            let current = snapshots[provider]
            if current?.status != .loading {
                snapshots[provider] = .loading(provider, preserving: current)
            }
        }
        refreshTask = Task { [transport, now] in
            await withTaskGroup(of: (AICodingProvider, AIUsageSnapshot).self) { group in
                for provider in pending {
                    group.addTask {
                        let snapshot = await AIUsageFetcher.fetch(provider, transport: transport, now: now())
                        return (provider, snapshot)
                    }
                }
                for await (provider, snapshot) in group {
                    await MainActor.run {
                        self.snapshots[provider] = snapshot
                        self.inFlight.remove(provider)
                    }
                }
            }
            await MainActor.run {
                self.lastRefresh = now()
            }
        }
    }
}

extension Notification.Name {
    static let aiUsageConnectionDidChange = Notification.Name("geraldine.aiUsage.connectionDidChange")
}
