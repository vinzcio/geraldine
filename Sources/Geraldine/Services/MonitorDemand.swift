import Foundation

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

/// Cadence for the ~130-sensor thermal read. Five seconds keeps the sparkline
/// and headline honest without paying a HID/SMC sweep every tick.
enum ThermalSamplePolicy {
    static let activeInterval: TimeInterval = 5

    static func shouldSample(
        now: TimeInterval,
        lastSampleAt: TimeInterval?,
        isDisplayed: Bool
    ) -> Bool {
        guard isDisplayed, now.isFinite else { return false }
        guard let lastSampleAt, lastSampleAt.isFinite else { return true }
        // A clock that moved backwards must not park sampling forever.
        return now < lastSampleAt || now - lastSampleAt >= activeInterval
    }
}
