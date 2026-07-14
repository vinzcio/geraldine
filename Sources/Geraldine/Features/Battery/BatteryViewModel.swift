import SwiftUI

@MainActor
final class BatteryViewModel: ObservableObject {
    @Published var detail = BatteryDetail()
    @Published var history: [ChargeSample] = []
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
            self.loadedHistory = true
            self.lastHistoryLoad = Date()
            self.historyTask = nil
        }
    }

    /// pmset history is a point-in-time snapshot; without periodic reloads the chart
    /// bridges a flat line from the last sample to now once the app has been open a
    /// while. `loadedHistory` stays set, so only the very first fetch shows a spinner.
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
}
