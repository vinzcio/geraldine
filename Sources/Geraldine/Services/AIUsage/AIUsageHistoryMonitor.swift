import Foundation
import Combine

/// History is fetched explicitly from Coding Usage; it never delays the quota timer.
@MainActor
final class AIUsageHistoryMonitor: ObservableObject {
    @Published private(set) var summaries: [AIUsageIdentity: AIHistorySummary] = [:]
    @Published private(set) var reading = Set<AIUsageIdentity>()
    @Published private(set) var errors: [AIUsageIdentity: String] = [:]
    @Published private(set) var pricingNotice: String?
    private var tasks: [AIUsageIdentity: Task<Void, Never>] = [:]
    private var prices = AIHistoryPrices()
    private var priceTask: Task<AIHistoryPrices, Never>?
    private var priceAttempted = false
    private var directories: [AIUsageIdentity: URL] = [:]
    typealias Reading = @Sendable (AIUsageIdentity, URL?) async throws -> AIHistoryRead
    private let readHistory: Reading
    private let fetchPrices: @Sendable () async throws -> Data

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         readHistory: Reading? = nil,
         fetchPrices: @escaping @Sendable () async throws -> Data = { try await HistoryHTTP().data(URLRequest(url: AIHistoryPrices.url)) }) {
        self.fetchPrices = fetchPrices
        self.readHistory = readHistory ?? { identity, directory in
            if identity.provider == .cursor { return try await CursorHistory().read(home: home) }
            let worker = Task.detached(priority: .utility) { try AIHistoryReader(home: home).read(identity, directory: directory) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
    }

    func refresh(_ identity: AIUsageIdentity, directory: URL? = nil) {
        guard tasks[identity] == nil else { return }
        if let directory { directories[identity] = directory }
        let selectedDirectory = directories[identity]
        reading.insert(identity); errors[identity] = nil
        tasks[identity] = Task {
            async let prices = loadPrices()
            do {
                let read = try await readHistory(identity, selectedDirectory)
                let rates = await prices
                try Task.checkCancellation()
                let summary = await Task.detached(priority: .utility) { AIHistorySummary(read: read, prices: rates) }.value
                try Task.checkCancellation()
                summaries[identity] = summary
            } catch is CancellationError { }
            catch { errors[identity] = "History could not be read. Previous totals, if any, are unchanged. Refresh to retry." }
            reading.remove(identity); tasks[identity] = nil
        }
    }

    func refreshPrices() async {
        guard priceTask == nil else { return }
        priceAttempted = false
        _ = await loadPrices()
        // Histories must be reread to apply new model rates; no transcripts are retained in this monitor.
    }

    private func loadPrices() async -> AIHistoryPrices {
        if priceTask == nil {
            if priceAttempted { return prices }
            priceAttempted = true
            let fetch = fetchPrices
            priceTask = Task.detached(priority: .utility) {
                guard let data = try? await fetch() else { return AIHistoryPrices() }
                return AIHistoryPrices(data: data)
            }
        }
        guard let task = priceTask else { return prices }
        let fetched = await task.value
        priceTask = nil
        if fetched.models.isEmpty {
            pricingNotice = prices.models.isEmpty ? "Public prices unavailable. Provider-reported costs remain available; other records are unpriced." : "Price refresh failed; using the last fetched rates."
        } else { prices = fetched; pricingNotice = nil }
        return prices
    }

    func stop() {
        for task in tasks.values { task.cancel() }
        priceTask?.cancel()
    }
}
