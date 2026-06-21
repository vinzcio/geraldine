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
    private var consumerTask: Task<Void, Never>?

    func start() {
        loadDetail()
        loadHistory()
        sampleConsumers()

        detailTimer?.invalidate()
        let dt = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadDetail() }
        }
        dt.tolerance = 4
        detailTimer = dt

        consumerTimer?.invalidate()
        let ct = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleConsumers() }
        }
        ct.tolerance = 2
        consumerTimer = ct
    }

    func stop() {
        detailTimer?.invalidate(); detailTimer = nil
        consumerTimer?.invalidate(); consumerTimer = nil
        consumerTask?.cancel(); consumerTask = nil
    }

    func loadDetail() {
        Task {
            let d = await Task.detached { BatteryInfo.detail() }.value
            self.detail = d
        }
    }

    func loadHistory() {
        Task {
            let h = await Task.detached { BatteryInfo.chargeHistory() }.value
            self.history = h
            self.loadedHistory = true
        }
    }

    /// `top -l 2` blocks for ~2s, so guard against overlapping samples.
    private func sampleConsumers() {
        guard consumerTask == nil else { return }
        sampling = true
        consumerTask = Task {
            let list = await Task.detached { BatteryInfo.energyConsumers(limit: 6) }.value
            self.consumers = list
            self.sampling = false
            self.consumerTask = nil
        }
    }
}
