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
    private var tasks: [AIUsageIdentity: Task<Void, Never>] = [:]
    private var completedAt: [AIUsageIdentity: Date] = [:]
    private var pending = Set<AIUsageIdentity>()
    private var generations: [AIUsageIdentity: UUID] = [:]
    private var saved: [AIUsageIdentity: AIUsageSnapshot] = [:]
    private var timer: Timer?
    private var discoveryTask: Task<Void, Never>?

    typealias UsageFetching = @Sendable (AIUsageIdentity, Date) async -> AIUsageSnapshot

    static let cacheKey = "geraldine.aiUsage.snapshots"
    static let accountsKey = "geraldine.aiUsage.accounts"
    static let connectedKey = "geraldine.aiUsage.connected"
    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    /// Check more often than the cadence so a request's completion time cannot
    /// push its next refresh out to every other five-minute tick.
    nonisolated static let stalenessCheckInterval: TimeInterval = 60

    init(defaults: UserDefaults = .standard,
         transport: any AIUsageTransporting = URLSessionAIUsageTransport(),
         now: @escaping () -> Date = Date.init,
         userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         fetchUsage: UsageFetching? = nil) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        self.userHome = userHome
        self.fetchUsage = fetchUsage ?? { identity, date in
            await AIUsageFetcher.fetch(identity, transport: transport, now: date, homeDirectory: userHome)
        }
        saved = UsageCache.load([AIUsageIdentity: AIUsageSnapshot].self, defaults: defaults, key: Self.cacheKey) ?? [:]
        accounts = UsageCache.load([AIUsageAccount].self, defaults: defaults, key: Self.accountsKey)
            ?? AICodingProvider.allCases.map { AIUsageAccount(identity: AIUsageIdentity($0), name: "Personal") }
        snapshots = [:]
        restoreConnections()
        rediscoverAccounts()
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

    /// Settings and tooltip name: "Claude · Client", or "Claude" for a single login.
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
            guard !Task.isCancelled else { return }
            if self.accounts != found { self.accounts = found }
            UsageCache.save(found, defaults: self.defaults, key: Self.accountsKey)
        }
    }

    func start() {
        guard timer == nil else { return }
        refreshIfStale()
        let timer = Timer(timeInterval: Self.stalenessCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for task in tasks.values { task.cancel() }
        generations.removeAll()
        pending.removeAll()
        discoveryTask?.cancel()
        isRefreshing = false
    }

    func isRefreshing(_ identity: AIUsageIdentity) -> Bool {
        tasks[identity].map { !$0.isCancelled } ?? false
    }

    /// Each login owns its cadence and in-flight work. Opening a surface never
    /// waits for a CLI, and one slow login cannot hold another behind a batch.
    func refreshIfStale() {
        rediscoverAccounts()
        let date = now()
        enqueue(connectedIdentities().filter { identity in
            let last = completedAt[identity] ?? snapshots[identity]?.fetchedAt
            return last.map { date.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        })
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
        generations[identity] = nil
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
                generations[identity] = nil
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
        for id in stored {
            guard let identity = AIUsageIdentity.from(widgetID: "ai." + id) else { continue }
            snapshots[identity] = cachedSnapshot(identity) ?? .loading(identity.provider)
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

    private func cachedSnapshot(_ identity: AIUsageIdentity) -> AIUsageSnapshot? {
        guard var cached = saved[identity] else { return nil }
        let hadWindows = !cached.windows.isEmpty
        cached.windows.removeAll { $0.resetsAt.map { $0 <= now() } ?? false }
        if hadWindows && cached.windows.isEmpty { return nil }
        return cached
    }

    private func markLoadingIfEmpty(_ identity: AIUsageIdentity) {
        let current = snapshots[identity]?.hasDisplayableUsage == true ? snapshots[identity] : cachedSnapshot(identity)
        if let current, current.hasDisplayableUsage {
            snapshots[identity] = current
        } else {
            snapshots[identity] = .loading(identity.provider, preserving: current)
        }
    }

    /// A failed check keeps the last successful values, marked with the
    /// error and their original fetch time, so one bad answer from a provider
    /// does not blank its tile. A window drops out once its reset has passed:
    /// its old number no longer describes the new window.
    private func keepingLastValues(_ fresh: AIUsageSnapshot, over current: AIUsageSnapshot?) -> AIUsageSnapshot {
        guard case .error(let message) = fresh.status, fresh.windows.isEmpty, let current else { return fresh }
        let date = now()
        var kept = AIUsageSnapshot.failed(fresh.provider, message: message, preserving: current)
        kept.windows.removeAll { window in window.resetsAt.map { $0 <= date } ?? false }
        return kept.windows.isEmpty ? fresh : kept
    }

    private func enqueue(_ identities: [AIUsageIdentity]) {
        for identity in identities where isConnected(identity) {
            guard tasks[identity] == nil else {
                if tasks[identity]?.isCancelled == true || generations[identity] == nil { pending.insert(identity) }
                continue
            }
            let generation = UUID()
            generations[identity] = generation
            let date = now()
            markLoadingIfEmpty(identity)
            isRefreshing = true
            tasks[identity] = Task { [weak self, fetchUsage] in
                let snapshot = await fetchUsage(identity, date)
                guard let self else { return }
                self.tasks[identity] = nil
                if !Task.isCancelled, self.generations[identity] == generation, self.isConnected(identity) {
                    let kept = self.keepingLastValues(snapshot, over: self.snapshots[identity])
                    self.snapshots[identity] = kept
                    self.completedAt[identity] = self.now()
                    self.lastRefresh = self.now()
                    // Only display data is persisted, never provider credentials or transcripts.
                    self.saved[identity] = kept.fetchedAt == nil ? nil : kept
                    UsageCache.save(self.saved, defaults: self.defaults, key: Self.cacheKey)
                }
                self.isRefreshing = self.tasks.values.contains { !$0.isCancelled }
                if self.pending.remove(identity) != nil, self.isConnected(identity) { self.enqueue([identity]) }
            }
        }
    }
}

extension Notification.Name {
    static let aiUsageConnectionDidChange = Notification.Name("geraldine.aiUsage.connectionDidChange")
}
