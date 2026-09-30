import AppKit
import Combine
import Foundation

/// Connects local coding-assistant sign-ins and keeps remaining-usage snapshots
/// for the menu-bar popover. Disabled providers stay disconnected and do no I/O.
@MainActor
final class AIUsageMonitor: ObservableObject {
    @Published private(set) var snapshots: [AIUsageIdentity: AIUsageSnapshot]
    /// Logins on this Mac. Discovered at launch and again with each usage
    /// refresh, off the main thread, so views never list folders.
    @Published private(set) var accounts: [AIUsageAccount]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let defaults: UserDefaults
    private let transport: any AIUsageTransporting
    private let now: () -> Date
    private let userHome: URL
    private let fetchUsage: UsageFetching
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var inFlight = Set<AIUsageIdentity>()
    private var queued = Set<AIUsageIdentity>()
    private var discoveryTask: Task<Void, Never>?

    typealias UsageFetching = @Sendable (AIUsageIdentity, Date) async -> AIUsageSnapshot

    static let connectedKey = "geraldine.aiUsage.connected"
    nonisolated static let refreshInterval: TimeInterval = 5 * 60

    init(defaults: UserDefaults = .standard,
         transport: any AIUsageTransporting = URLSessionAIUsageTransport(),
         now: @escaping () -> Date = Date.init,
         userHome: URL = AIUsageCredentialStore.home(),
         fetchUsage: UsageFetching? = nil) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        self.userHome = userHome
        self.fetchUsage = fetchUsage ?? { identity, date in
            await AIUsageFetcher.fetch(identity, transport: transport, now: date, homeDirectory: userHome)
        }
        let found = AIUsageAccountDiscovery.accounts(userHome: userHome)
        accounts = found
        snapshots = Dictionary(uniqueKeysWithValues: found.map { ($0.identity, .disconnected($0.identity.provider)) })
        restoreConnections()
    }

    func snapshot(for provider: AICodingProvider) -> AIUsageSnapshot {
        snapshot(for: AIUsageIdentity(provider))
    }

    func snapshot(for identity: AIUsageIdentity) -> AIUsageSnapshot {
        snapshots[identity] ?? .disconnected(identity.provider)
    }

    func isConnected(_ provider: AICodingProvider) -> Bool {
        isConnected(AIUsageIdentity(provider))
    }

    func isConnected(_ identity: AIUsageIdentity) -> Bool {
        snapshot(for: identity).status.isConnected
    }

    /// Tile name: the account name once a provider has several logins.
    func tileName(for identity: AIUsageIdentity) -> String {
        hasSeveralAccounts(identity.provider) ? accountName(for: identity) : identity.provider.title
    }

    /// Settings and tooltip name: "Claude · Fasaj", or "Claude" for a single login.
    func displayName(for identity: AIUsageIdentity) -> String {
        guard hasSeveralAccounts(identity.provider) else { return identity.provider.title }
        return "\(identity.provider.title) · \(accountName(for: identity))"
    }

    private func hasSeveralAccounts(_ provider: AICodingProvider) -> Bool {
        accounts.filter { $0.identity.provider == provider }.count > 1
    }

    private func accountName(for identity: AIUsageIdentity) -> String {
        accounts.first { $0.identity == identity }?.name ?? identity.folderName ?? identity.provider.title
    }

    /// Pick up a login added or removed since launch without blocking the main thread.
    private func rediscoverAccounts() {
        guard discoveryTask == nil else { return }
        let userHome = userHome
        discoveryTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                AIUsageAccountDiscovery.accounts(userHome: userHome)
            }.value
            guard let self else { return }
            self.discoveryTask = nil
            if self.accounts != found { self.accounts = found }
        }
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
        let identities = connectedIdentities()
        guard !identities.isEmpty else { return }
        rediscoverAccounts()
        startBatch(Set(identities))
    }

    func refreshConnected() {
        let identities = connectedIdentities()
        guard !identities.isEmpty else { return }
        rediscoverAccounts()
        enqueue(identities)
    }

    func connect(_ provider: AICodingProvider) {
        connect(AIUsageIdentity(provider))
    }

    func connect(_ identity: AIUsageIdentity) {
        persistConnected(identity, connected: true)
        markLoadingIfEmpty(identity)
        enqueue([identity])
        NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: identity.provider)
    }

    func disconnect(_ provider: AICodingProvider) {
        disconnect(AIUsageIdentity(provider))
    }

    func disconnect(_ identity: AIUsageIdentity) {
        persistConnected(identity, connected: false)
        snapshots[identity] = .disconnected(identity.provider)
        NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: identity.provider)
    }

    /// Keep fetch state aligned with visible popover tiles. Showing a tile
    /// connects it; hiding disconnects it. Already-matching identities are left
    /// alone so a layout republish does not restart in-flight fetches.
    func syncShownProviders(_ shown: Set<AICodingProvider>) {
        syncShownIdentities(Set(shown.map { AIUsageIdentity($0) }))
    }

    func syncShownIdentities(_ shown: Set<AIUsageIdentity>) {
        var toConnect: [AIUsageIdentity] = []
        let known = Set(accounts.map(\.identity) + snapshots.keys + shown)
        for identity in known {
            let shouldConnect = shown.contains(identity)
            if shouldConnect && !isConnected(identity) {
                persistConnected(identity, connected: true)
                markLoadingIfEmpty(identity)
                toConnect.append(identity)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: identity.provider)
            } else if !shouldConnect && isConnected(identity) {
                persistConnected(identity, connected: false)
                snapshots[identity] = .disconnected(identity.provider)
                NotificationCenter.default.post(name: .aiUsageConnectionDidChange, object: identity.provider)
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
        for account in accounts where stored.contains(account.id) {
            snapshots[account.identity] = .loading(account.identity.provider)
        }
    }

    private func persistConnected(_ identity: AIUsageIdentity, connected: Bool) {
        var stored = Set(defaults.stringArray(forKey: Self.connectedKey) ?? [])
        if connected {
            stored.insert(identity.id)
        } else {
            stored.remove(identity.id)
        }
        defaults.set(Array(stored).sorted(), forKey: Self.connectedKey)
    }

    private func connectedIdentities() -> [AIUsageIdentity] {
        let known = Set(accounts.map(\.identity) + snapshots.keys)
        return known.filter { isConnected($0) }.sorted { $0.id < $1.id }
    }

    private var needsSharedRefresh: Bool {
        guard let lastRefresh else { return true }
        return now().timeIntervalSince(lastRefresh) >= Self.refreshInterval
    }

    private func markLoadingIfEmpty(_ identity: AIUsageIdentity) {
        let current = snapshots[identity]
        if current?.hasDisplayableUsage != true {
            snapshots[identity] = .loading(identity.provider, preserving: current)
        }
    }

    private func enqueue(_ identities: [AIUsageIdentity]) {
        let wanted = Set(identities).subtracting(inFlight)
        guard !wanted.isEmpty else { return }
        if refreshTask != nil {
            queued.formUnion(wanted)
            return
        }
        startBatch(wanted)
    }

    private func startBatch(_ identities: Set<AIUsageIdentity>) {
        guard !identities.isEmpty else { return }
        inFlight.formUnion(identities)
        isRefreshing = true
        for identity in identities {
            markLoadingIfEmpty(identity)
        }
        refreshTask = Task { [fetchUsage, now] in
            await withTaskGroup(of: (AIUsageIdentity, AIUsageSnapshot).self) { group in
                for identity in identities {
                    group.addTask {
                        (identity, await fetchUsage(identity, now()))
                    }
                }
                for await (identity, snapshot) in group {
                    await MainActor.run {
                        self.snapshots[identity] = snapshot
                        self.inFlight.remove(identity)
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
