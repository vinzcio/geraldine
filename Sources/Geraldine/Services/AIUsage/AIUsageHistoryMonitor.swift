import Foundation
import Combine

/// App-owned history cache. Each requested login refreshes independently, even
/// while its view is closed. Pricing never gates publication of token totals.
@MainActor
final class AIUsageHistoryMonitor: ObservableObject {
    @Published private(set) var summaries: [AIUsageIdentity: AIHistorySummary]
    @Published private(set) var reading = Set<AIUsageIdentity>()
    @Published private(set) var errors: [AIUsageIdentity: String] = [:]
    @Published private(set) var pricingNotice: String?
    private var tasks: [AIUsageIdentity: Task<Void, Never>] = [:]
    private var prices = AIHistoryPrices()
    private var priceTask: Task<Void, Never>?
    private var priceAttempted = false
    private var priceRevision = 0
    private var directories: [AIUsageIdentity: URL] = [:]
    private var completedAt: [AIUsageIdentity: Date] = [:]
    private var saved: [AIUsageIdentity: AIHistorySummary]
    private var tracked: Set<AIUsageIdentity>
    private var timer: Timer?
    private let defaults: UserDefaults
    private let now: () -> Date
    static let cacheKey = "geraldine.aiUsage.historySummaries"
    static let trackedKey = "geraldine.aiUsage.historyAccounts"
    typealias Reading = @Sendable (AIUsageIdentity, URL?) async throws -> AIHistoryRead
    private let readHistory: Reading
    private let fetchPrices: @Sendable () async throws -> Data

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         readHistory: Reading? = nil,
         fetchPrices: @escaping @Sendable () async throws -> Data = { try await HistoryHTTP().data(URLRequest(url: AIHistoryPrices.url)) }) {
        self.defaults = defaults
        self.now = now
        let cached = UsageCache.load([AIUsageIdentity: AIHistorySummary].self, defaults: defaults, key: Self.cacheKey) ?? [:]
        summaries = cached
        saved = cached
        tracked = UsageCache.load(Set<AIUsageIdentity>.self, defaults: defaults, key: Self.trackedKey) ?? []
        self.fetchPrices = fetchPrices
        self.readHistory = readHistory ?? { identity, directory in
            if identity.provider == .cursor { return try await CursorHistory().read(home: home) }
            let worker = Task.detached(priority: .utility) { try AIHistoryReader(home: home).read(identity, directory: directory) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
    }

    func start() {
        guard timer == nil else { return }
        refreshIfStale()
        let timer = Timer(timeInterval: AIUsageMonitor.stalenessCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfStale() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfStale(_ identities: [AIUsageIdentity]? = nil) {
        for identity in identities ?? Array(tracked) {
            let last = completedAt[identity] ?? summaries[identity]?.updatedAt
            if last.map({ now().timeIntervalSince($0) >= AIUsageMonitor.refreshInterval }) ?? true {
                refresh(identity)
            }
        }
    }

    func refresh(_ identity: AIUsageIdentity, directory: URL? = nil) {
        guard tasks[identity] == nil else { return }
        if let directory { directories[identity] = directory }
        else {
            tracked.insert(identity)
            UsageCache.save(tracked, defaults: defaults, key: Self.trackedKey)
        }
        let selectedDirectory = directories[identity]
        reading.insert(identity)
        loadPrices()
        tasks[identity] = Task { [weak self, readHistory] in
            do {
                let read = try await readHistory(identity, selectedDirectory)
                try Task.checkCancellation()
                guard let self else { return }
                if read.records.isEmpty, let notice = read.notice, self.summaries[identity] != nil {
                    self.errors[identity] = "Couldn't refresh. " + notice
                } else {
                    var revision: Int
                    var summary: AIHistorySummary
                    repeat {
                        revision = self.priceRevision
                        let rates = self.prices
                        let date = self.now()
                        summary = await Task.detached(priority: .utility) { AIHistorySummary(read: read, prices: rates, now: date) }.value
                        try Task.checkCancellation()
                    } while revision != self.priceRevision
                    self.summaries[identity] = summary
                    self.errors[identity] = nil
                    // Chosen directories remain scoped to this app session. Do not
                    // restore their totals under a default history source at relaunch.
                    if selectedDirectory == nil {
                        self.saved[identity] = summary
                        UsageCache.save(self.saved, defaults: self.defaults, key: Self.cacheKey)
                    }
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self?.errors[identity] = "Couldn't refresh. Showing the last known history, if available." }
            }
            guard let self else { return }
            if !Task.isCancelled { self.completedAt[identity] = self.now() }
            self.reading.remove(identity)
            self.tasks[identity] = nil
        }
    }

    func refreshPrices() {
        guard priceTask == nil else { return }
        priceAttempted = false
        loadPrices()
    }

    private func loadPrices() {
        guard priceTask == nil, !priceAttempted else { return }
        priceAttempted = true
        priceTask = Task { [weak self, fetchPrices] in
            let fetched = await Task.detached(priority: .utility) {
                guard let data = try? await fetchPrices() else { return AIHistoryPrices() }
                return AIHistoryPrices(data: data)
            }.value
            guard let self else { return }
            self.priceTask = nil
            guard !Task.isCancelled else { self.priceAttempted = false; return }
            if fetched.models.isEmpty {
                self.pricingNotice = self.prices.models.isEmpty ? "Public prices unavailable. Provider-reported costs remain available; other records are unpriced." : "Price refresh failed; using the last fetched rates."
            } else {
                self.prices = fetched
                self.priceRevision += 1
                self.pricingNotice = nil
                // Re-read completed default histories to apply new rates. Work
                // still in progress uses the latest rates when it completes.
                for identity in self.tracked where self.summaries[identity] != nil {
                    self.refresh(identity)
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for task in tasks.values { task.cancel() }
        priceTask?.cancel()
    }
}
