import SwiftUI

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var detail = BatteryDetail()
    @Published private(set) var history: [ChargeSample] = []
    @Published private(set) var liveHistory: [ChargeSample] = []
    @Published private(set) var chartHistory: [ChargeSample] = []
    @Published var consumers: [EnergyConsumer] = []
    @Published var loadedHistory = false
    @Published var sampling = false

    private var detailTimer: Timer?
    private var consumerTimer: Timer?
    private var detailTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var consumerTask: Task<Void, Never>?
    private var lifecycleID = UUID()
    private var lastHistoryLoad: Date?

    func start() {
        detailTimer?.invalidate()
        consumerTimer?.invalidate()
        cancelInFlightWork()
        loadDetail()
        if !loadedHistory { loadHistory() }
        sampleConsumers()

        let dt = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadDetail()
                self?.reloadHistoryIfStale()
            }
        }
        dt.tolerance = 4
        detailTimer = dt

        let ct = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleConsumers() }
        }
        ct.tolerance = 2
        consumerTimer = ct
    }

    func stop() {
        detailTimer?.invalidate(); detailTimer = nil
        consumerTimer?.invalidate(); consumerTimer = nil
        cancelInFlightWork()
    }

    func loadDetail() {
        detailTask?.cancel()
        let lifecycleID = self.lifecycleID
        detailTask = Task { [weak self] in
            let d = await Task.detached { BatteryInfo.detail() }.value
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleID == lifecycleID else { return }
            self.detail = d
            self.detailTask = nil
        }
    }

    func loadHistory() {
        historyTask?.cancel()
        let lifecycleID = self.lifecycleID
        historyTask = Task { [weak self] in
            let h = await Task.detached { BatteryInfo.chargeHistory() }.value
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleID == lifecycleID else { return }
            self.history = h
            self.rebuildChartHistory()
            self.loadedHistory = true
            self.lastHistoryLoad = Date()
            self.historyTask = nil
        }
    }

    /// Keeps readings observed while this process is running separate from the pmset
    /// snapshot. Persistence belongs to the monitor history store; this small buffer
    /// only lets the standalone Battery page connect genuinely observed live points.
    func recordLiveReading(level: Double, onAC: Bool, at date: Date = Date()) {
        guard level.isFinite else { return }
        let sample = ChargeSample(date: date, level: min(max(level, 0), 1), onAC: onAC)
        let cutoff = date.addingTimeInterval(-HistoryRange.tenDays.seconds)
        liveHistory = BatteryHistoryPolicy.merge(pmset: [], live: liveHistory + [sample])
            .filter { $0.date >= cutoff }
        rebuildChartHistory()
    }

    /// pmset history is a point-in-time snapshot. Reload periodically so new system
    /// events arrive while this page remains open. `loadedHistory` stays set, so only
    /// the first fetch shows a spinner.
    private func reloadHistoryIfStale() {
        guard let lastHistoryLoad, Date().timeIntervalSince(lastHistoryLoad) >= 300 else { return }
        loadHistory()
    }

    /// `top -l 2` blocks for ~2s, so guard against overlapping samples.
    private func sampleConsumers() {
        guard consumerTask == nil else { return }
        sampling = true
        let lifecycleID = self.lifecycleID
        consumerTask = Task { [weak self] in
            let list = await Task.detached { BatteryInfo.energyConsumers(limit: 6) }.value
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleID == lifecycleID else { return }
            self.consumers = list
            self.sampling = false
            self.consumerTask = nil
        }
    }

    private func cancelInFlightWork() {
        lifecycleID = UUID()
        detailTask?.cancel(); detailTask = nil
        historyTask?.cancel(); historyTask = nil
        consumerTask?.cancel(); consumerTask = nil
        sampling = false
    }

    private func rebuildChartHistory() {
        chartHistory = BatteryHistoryPolicy.merge(pmset: history, live: liveHistory)
    }
}
