import AppKit
import Combine
import Foundation

/// Connects local coding-assistant sign-ins and keeps remaining-usage snapshots
/// for the menu-bar popover. Disabled providers stay disconnected and do no I/O.
@MainActor
final class AIUsageMonitor: ObservableObject {
    @Published private(set) var snapshots: [AICodingProvider: AIUsageSnapshot]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private let transport: any AIUsageTransporting
    private let now: () -> Date
    private let fetchUsage: UsageFetching
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var inFlight = Set<AICodingProvider>()
    private var queued = Set<AICodingProvider>()

    typealias UsageFetching = @Sendable (AICodingProvider, Date) async -> AIUsageSnapshot

    static let connectedKey = "geraldine.aiUsage.connected"
    nonisolated static let refreshInterval: TimeInterval = 5 * 60

    init(defaults: UserDefaults = .standard,
         transport: any AIUsageTransporting = URLSessionAIUsageTransport(),
         now: @escaping () -> Date = Date.init,
         fetchUsage: UsageFetching? = nil) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        self.fetchUsage = fetchUsage ?? { provider, date in
            await AIUsageFetcher.fetch(provider, transport: transport, now: date)
        }
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
        refreshIfStale()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
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
        queued.removeAll()
        isRefreshing = false
    }

    /// Popover open, become-active, and the 5-minute timer all use this one
    /// shared clock. An in-flight batch is reused instead of starting another.
    func refreshIfStale() {
        guard refreshTask == nil else { return }
        guard needsSharedRefresh else { return }
        let providers = connectedProviders()
        guard !providers.isEmpty else { return }
        startBatch(Set(providers))
    }

    func refreshConnected() {
        let providers = connectedProviders()
        guard !providers.isEmpty else { return }
        enqueue(providers)
    }

    func connect(_ provider: AICodingProvider) {
        persistConnected(provider, connected: true)
        markLoadingIfEmpty(provider)
        enqueue([provider])
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
                markLoadingIfEmpty(provider)
                toConnect.append(provider)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
            } else if !shouldConnect && isConnected(provider) {
                persistConnected(provider, connected: false)
                snapshots[provider] = .disconnected(provider)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: provider)
            }
        }
        if !toConnect.isEmpty {
            enqueue(toConnect)
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

    private func connectedProviders() -> [AICodingProvider] {
        AICodingProvider.allCases.filter { isConnected($0) }
    }

    private var needsSharedRefresh: Bool {
        guard let lastRefresh else { return true }
        return now().timeIntervalSince(lastRefresh) >= Self.refreshInterval
    }

    private func markLoadingIfEmpty(_ provider: AICodingProvider) {
        let current = snapshots[provider]
        if current?.hasDisplayableUsage != true {
            snapshots[provider] = .loading(provider, preserving: current)
        }
    }

    private func enqueue(_ providers: [AICodingProvider]) {
        let wanted = Set(providers).subtracting(inFlight)
        guard !wanted.isEmpty else { return }
        if refreshTask != nil {
            queued.formUnion(wanted)
            return
        }
        startBatch(wanted)
    }

    private func startBatch(_ providers: Set<AICodingProvider>) {
        guard !providers.isEmpty else { return }
        inFlight.formUnion(providers)
        isRefreshing = true
        for provider in providers {
            markLoadingIfEmpty(provider)
        }
        refreshTask = Task { [fetchUsage, now] in
            await withTaskGroup(of: (AICodingProvider, AIUsageSnapshot).self) { group in
                for provider in providers {
                    group.addTask {
                        let snapshot = await fetchUsage(provider, now())
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
                self.refreshTask = nil
                let followUp = self.queued
                self.queued.removeAll()
                if followUp.isEmpty {
                    self.isRefreshing = false
                } else {
                    self.startBatch(followUp)
                }
            }
        }
    }
}

extension Notification.Name {
    static let aiUsageConnectionDidChange = Notification.Name("geraldine.aiUsage.connectionDidChange")
}
