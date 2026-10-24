import Foundation
import Combine

/// Which expensive live samples a visible surface actually needs.
///
/// Thermal and GPU reads are the two costly samples in `SystemMonitor`: thermal
/// walks every HID/SMC sensor, and GPU discovery opens the IOAccelerator
/// registry. Neither number can be seen when no menu-bar metric, popover, or
/// window is showing it, so the monitor only pays for them on demand.
struct MonitorDemand: Equatable, Sendable {
    var showsThermal: Bool
    var showsGPU: Bool
    var displaysAsleep: Bool

    init(showsThermal: Bool = false, showsGPU: Bool = false, displaysAsleep: Bool = false) {
        self.showsThermal = showsThermal
        self.showsGPU = showsGPU
        self.displaysAsleep = displaysAsleep
    }

    static let inactive = MonitorDemand()
    static let everything = MonitorDemand(showsThermal: true, showsGPU: true)

    var samplesThermal: Bool { showsThermal && !displaysAsleep }
    var samplesGPU: Bool { showsGPU && !displaysAsleep }
}

/// Published values deliver in willSet. Reconcile after assignments finish;
/// a later drag commit must also reconcile the committed menu-bar metric.
@MainActor
final class MonitorDemandObservation {
    private var cancellables = Set<AnyCancellable>()
    private var reconciliationPending = false
    private let reconcile: () -> Void

    init(layout: WidgetLayoutStore, monitor: SystemMonitor, reconcile: @escaping () -> Void) {
        self.reconcile = reconcile
        layout.$items.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleReconciliation() }
            .store(in: &cancellables)
        layout.committedItemsDidChange
            .sink { [weak self] _ in self?.scheduleReconciliation() }
            .store(in: &cancellables)
        monitor.$hasBattery.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.scheduleReconciliation() }
            .store(in: &cancellables)
    }

    private func scheduleReconciliation() {
        guard !reconciliationPending else { return }
        reconciliationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconciliationPending = false
            self.reconcile()
        }
    }
}
