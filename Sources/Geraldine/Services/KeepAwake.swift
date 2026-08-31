import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

enum KeepAwakeDuration: String, CaseIterable, Identifiable {
    case tenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours
    case twelveHours
    case indefinitely

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .tenMinutes: return 10 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        case .twelveHours: return 12 * 60 * 60
        case .indefinitely: return nil
        }
    }

    var label: String {
        switch self {
        case .tenMinutes: return "10 Minutes"
        case .thirtyMinutes: return "30 Minutes"
        case .oneHour: return "1 Hour"
        case .twoHours: return "2 Hours"
        case .fourHours: return "4 Hours"
        case .eightHours: return "8 Hours"
        case .twelveHours: return "12 Hours"
        case .indefinitely: return "Indefinitely"
        }
    }

    var shortLabel: String {
        switch self {
        case .tenMinutes: return "10m"
        case .thirtyMinutes: return "30m"
        case .oneHour: return "1h"
        case .twoHours: return "2h"
        case .fourHours: return "4h"
        case .eightHours: return "8h"
        case .twelveHours: return "12h"
        case .indefinitely: return "∞"
        }
    }

    static func matching(seconds: TimeInterval?) -> KeepAwakeDuration? {
        guard let seconds else { return .indefinitely }
        return allCases.first { option in
            guard let optionSeconds = option.seconds else { return false }
            return abs(optionSeconds - seconds) < 0.5
        }
    }
}

@MainActor
final class KeepAwakeController: ObservableObject {
    private enum DefaultsKey {
        static let defaultDuration = "keepAwake.defaultDuration"
        static let allowDisplaySleep = "keepAwake.allowDisplaySleep"
        static let deactivateOnBattery = "keepAwake.deactivateOnBattery"
        static let pauseWhenScreenLocked = "keepAwake.pauseWhenScreenLocked"
        static let simulateIdleActivity = "keepAwake.simulateIdleActivity"
        static let idleActivityDelayMinutes = "keepAwake.idleActivityDelayMinutes"
    }

    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var pauseReason: String?
    @Published private(set) var activeUntil: Date?
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var lastError: String?
    @Published private(set) var idleActivityPhase: IdleActivitySimulationPhase = .off
    @Published private(set) var idleActivityLastPulse: Date?
    @Published private(set) var idleActivityLastUserInput: Date?
    @Published private(set) var idleActivityError: String?

    @Published var defaultDuration: KeepAwakeDuration {
        didSet { defaults.set(defaultDuration.rawValue, forKey: DefaultsKey.defaultDuration) }
    }

    @Published var allowDisplaySleep: Bool {
        didSet {
            defaults.set(allowDisplaySleep, forKey: DefaultsKey.allowDisplaySleep)
            refreshAssertions()
        }
    }

    @Published var deactivateOnBattery: Bool {
        didSet {
            defaults.set(deactivateOnBattery, forKey: DefaultsKey.deactivateOnBattery)
            if deactivateOnBattery {
                handlePowerSourceChange()
            }
        }
    }

    @Published var pauseWhenScreenLocked: Bool {
        didSet {
            defaults.set(pauseWhenScreenLocked, forKey: DefaultsKey.pauseWhenScreenLocked)
            if !pauseWhenScreenLocked, isPaused, pauseReason == Self.screenLockPauseReason {
                resumeFromPolicyPause()
            }
        }
    }

    @Published var simulateIdleActivity: Bool {
        didSet {
            defaults.set(simulateIdleActivity, forKey: DefaultsKey.simulateIdleActivity)
            applyIdleActivitySimulation()
        }
    }

    @Published var idleActivityDelayMinutes: Int {
        didSet {
            let clamped = Self.clampedIdleActivityDelayMinutes(idleActivityDelayMinutes)
            if idleActivityDelayMinutes != clamped {
                idleActivityDelayMinutes = clamped
                return
            }
            defaults.set(idleActivityDelayMinutes, forKey: DefaultsKey.idleActivityDelayMinutes)
            applyIdleActivitySimulation()
        }
    }

    private static let screenLockPauseReason = "Screen Locked"
    static let batteryPolicyRefusalMessage =
        "Keep Awake is off while Deactivate On Battery is enabled."
    private let defaults: UserDefaults
    private let currentPowerSourceIsBattery: () -> Bool
    private let idleActivitySimulator: IdleActivitySimulationService
    private var activeSince: Date?
    private var idleAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var expirationTimer: Timer?
    /// Regenerated whenever expiration ownership changes. A callback that has
    /// already started delivery cannot use an invalidated timer to end a newer session.
    private(set) var expirationSessionToken = UUID()
    private var ticker: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard,
         currentPowerSourceIsBattery: @escaping () -> Bool = KeepAwakeController.isOnBatteryPower,
         idleActivitySimulator: IdleActivitySimulationService? = nil) {
        self.defaults = defaults
        self.currentPowerSourceIsBattery = currentPowerSourceIsBattery
        self.idleActivitySimulator = idleActivitySimulator ?? IdleActivitySimulationService()

        let rawDuration = defaults.string(forKey: DefaultsKey.defaultDuration) ?? KeepAwakeDuration.oneHour.rawValue
        defaultDuration = KeepAwakeDuration(rawValue: rawDuration) ?? .oneHour
        allowDisplaySleep = defaults.bool(forKey: DefaultsKey.allowDisplaySleep)
        deactivateOnBattery = defaults.bool(forKey: DefaultsKey.deactivateOnBattery)
        pauseWhenScreenLocked = defaults.bool(forKey: DefaultsKey.pauseWhenScreenLocked)
        simulateIdleActivity = defaults.bool(forKey: DefaultsKey.simulateIdleActivity)
        let rawIdleDelay = defaults.object(forKey: DefaultsKey.idleActivityDelayMinutes) as? Int ?? 2
        idleActivityDelayMinutes = Self.clampedIdleActivityDelayMinutes(rawIdleDelay)
        defaults.set(idleActivityDelayMinutes, forKey: DefaultsKey.idleActivityDelayMinutes)

        installPowerSourceObserver()
        installWorkspaceObservers()
        configureIdleActivitySimulator()
        applyIdleActivitySimulation()
    }

    var statusLine: String {
        guard isActive else { return "Off" }
        if isPaused, let pauseReason { return "Paused · \(pauseReason)" }
        if let remaining { return "On · \(Self.durationString(remaining)) Left" }
        return "On · Indefinitely"
    }

    var endTimeLine: String {
        if let activeUntil {
            return "Until \(activeUntil.formatted(date: .omitted, time: .shortened))"
        }
        return "No Scheduled End"
    }

    var idleActivityStatusLine: String {
        guard simulateIdleActivity else { return "Off" }
        guard isActive else { return "Starts With Keep Awake" }
        if isPaused { return "Paused · \(pauseReason ?? "Keep Awake Paused")" }

        switch idleActivityPhase {
        case .off:
            return "Starting"
        case .waiting:
            return "On · Waiting \(idleActivityDelayLabel)"
        case .pulsing:
            return "On · Simulating Activity"
        case .needsAccessibility:
            return "Needs Accessibility"
        case .failed:
            return idleActivityError ?? "Unavailable"
        }
    }

    var idleActivityDelay: TimeInterval {
        TimeInterval(idleActivityDelayMinutes * 60)
    }

    var idleActivityDelayLabel: String {
        idleActivityDelayMinutes == 1 ? "1m" : "\(idleActivityDelayMinutes)m"
    }

    var idleActivityNeedsAccessibility: Bool {
        simulateIdleActivity && idleActivityPhase == .needsAccessibility
    }

    /// Fraction of the current timed session that has elapsed, 0…1. `nil` for an indefinite
    /// session (nothing to measure against) or when inactive.
    var progressFraction: Double? {
        guard isActive, let activeSince, let activeUntil, let remaining else { return nil }
        let total = activeUntil.timeIntervalSince(activeSince)
        guard total > 0 else { return nil }
        return min(1, max(0, 1 - remaining / total))
    }

    /// The timed span owned by the running session. This deliberately does not read
    /// `defaultDuration`: changing the honeycomb while active configures the next session.
    var activeDuration: TimeInterval? {
        guard isActive, let activeSince, let activeUntil else { return nil }
        return max(0, activeUntil.timeIntervalSince(activeSince))
    }

    /// The honeycomb option represented by the running session. URL automation may
    /// start an arbitrary duration; in that case no preset should appear selected.
    var activeDurationOption: KeepAwakeDuration? {
        guard isActive else { return nil }
        return KeepAwakeDuration.matching(seconds: activeDuration)
    }

    func activateDefault() {
        activate(duration: defaultDuration.seconds)
    }

    func activate(option: KeepAwakeDuration) {
        activate(duration: option.seconds)
    }

    /// Applies a duration choice consistently across every surface. While a session is
    /// running, the choice becomes the new current session instead of silently changing
    /// only the next launch.
    func selectDuration(_ option: KeepAwakeDuration) {
        defaultDuration = option
        if isActive {
            activate(option: option)
        }
    }

    func activate(duration: TimeInterval?) {
        if deactivateOnBattery, currentPowerSourceIsBattery() {
            if isActive {
                endSession()
            }
            lastError = Self.batteryPolicyRefusalMessage
            return
        }

        lastError = nil
        isActive = true
        isPaused = false
        pauseReason = nil
        let now = Date()
        activeSince = now
        activeUntil = duration.map { now.addingTimeInterval(max(1, $0)) }
        updateRemaining()
        scheduleExpirationTimer()
        startTicker()
        refreshAssertions()
        applyIdleActivitySimulation()
    }

    /// Adds time to a running, finite session without resetting elapsed progress. No-op when
    /// inactive or indefinite; leaves the power assertions untouched.
    func extend(by seconds: TimeInterval) {
        guard isActive, seconds > 0, let current = activeUntil else { return }
        activeUntil = current.addingTimeInterval(seconds)
        updateRemaining()
        scheduleExpirationTimer()
    }

    func deactivate() {
        endSession()
        lastError = nil
    }

    /// Stops the session: clears the published state, both timers, and the assertions.
    /// Callers decide what happens to `lastError`.
    private func endSession() {
        isActive = false
        isPaused = false
        pauseReason = nil
        activeSince = nil
        activeUntil = nil
        remaining = nil
        invalidateExpirationTimer()
        ticker?.invalidate()
        ticker = nil
        releaseAssertions()
        applyIdleActivitySimulation()
    }

    func toggle() {
        if isActive {
            deactivate()
        } else {
            activateDefault()
        }
    }

    func shutdown() {
        deactivate()
        idleActivitySimulator.stop()
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            self.powerSourceRunLoopSource = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "geraldine",
              let command = Self.command(from: url) else { return false }

        let parsedDuration = Self.durationOverride(from: url)
        let duration = parsedDuration.wasSpecified ? parsedDuration.seconds : defaultDuration.seconds

        switch command {
        case "activate":
            activate(duration: duration)
        case "deactivate":
            deactivate()
        case "toggle":
            if isActive {
                deactivate()
            } else {
                activate(duration: duration)
            }
        default:
            return false
        }
        return true
    }

    func refreshIdleActivityAccess(prompt: Bool = false) {
        if prompt {
            Permissions.requestAccessibilityAccess()
        }
        applyIdleActivitySimulation()
    }

    private func configureIdleActivitySimulator() {
        idleActivitySimulator.onSnapshotChange = { [weak self] snapshot in
            Self.deliverMainRunLoopCallback {
                self?.idleActivityPhase = snapshot.phase
                self?.idleActivityLastPulse = snapshot.lastPulse
                self?.idleActivityLastUserInput = snapshot.lastUserInput
                self?.idleActivityError = snapshot.errorMessage
            }
        }
    }

    /// Idle activity only runs while a Keep Awake session is active and not paused:
    /// synthetic input must never fire when the user believes Keep Awake is off,
    /// or into a locked screen.
    private var idleActivityShouldRun: Bool {
        simulateIdleActivity && isActive && !isPaused
    }

    private func applyIdleActivitySimulation() {
        if idleActivityShouldRun {
            idleActivitySimulator.start(idleDelay: idleActivityDelay)
        } else {
            idleActivitySimulator.stop()
        }
    }

    private static func clampedIdleActivityDelayMinutes(_ minutes: Int) -> Int {
        // Only 1m, 2m, and 5m remain valid. Thresholds avoid subtracting an untrusted
        // persisted Int, which could overflow while repairing Int.min or Int.max.
        if minutes <= 1 { return 1 }
        if minutes <= 3 { return 2 }
        return 5
    }

    static let idleActivityDelayOptions = [1, 2, 5]

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                                     object: nil,
                                                     queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pauseForScreenLockIfNeeded() }
        })

        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                                     object: nil,
                                                     queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeFromPolicyPause() }
        })
    }

    private func installPowerSourceObserver() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let controller = Unmanaged<KeepAwakeController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.handlePowerSourceChange() }
        }, context)?.takeRetainedValue() else { return }

        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func pauseForScreenLockIfNeeded() {
        guard pauseWhenScreenLocked, isActive else { return }
        isPaused = true
        pauseReason = Self.screenLockPauseReason
        releaseAssertions()
        applyIdleActivitySimulation()
    }

    private func resumeFromPolicyPause() {
        guard isActive, isPaused, pauseReason == Self.screenLockPauseReason else { return }
        isPaused = false
        pauseReason = nil
        refreshAssertions()
        applyIdleActivitySimulation()
    }

    private func handlePowerSourceChange() {
        guard deactivateOnBattery, isActive, currentPowerSourceIsBattery() else { return }
        deactivate()
    }

    private func scheduleExpirationTimer() {
        invalidateExpirationTimer()

        guard let activeUntil else { return }
        let interval = max(0.1, activeUntil.timeIntervalSinceNow)
        let sessionToken = expirationSessionToken
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Self.deliverMainRunLoopCallback {
                self?.expireSession(ifCurrent: sessionToken)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimer = timer
    }

    private func invalidateExpirationTimer() {
        expirationSessionToken = UUID()
        expirationTimer?.invalidate()
        expirationTimer = nil
    }

    /// Handles the semantic expiration event after the run-loop timer fires.
    /// Keeping the token check here makes stale delivery inert even if the old
    /// timer fired just before it was invalidated.
    func expireSession(ifCurrent sessionToken: UUID) {
        guard sessionToken == expirationSessionToken else { return }
        deactivate()
    }

    nonisolated static func deliverMainRunLoopCallback(
        _ callback: @MainActor () -> Void
    ) {
        precondition(Thread.isMainThread, "Keep Awake callbacks must run on the main run loop")
        MainActor.assumeIsolated(callback)
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateRemaining() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func updateRemaining() {
        guard isActive else {
            remaining = nil
            return
        }

        guard let activeUntil else {
            remaining = nil
            return
        }

        let nextRemaining = max(0, activeUntil.timeIntervalSinceNow)
        remaining = nextRemaining
        if nextRemaining <= 0 {
            deactivate()
        }
    }

    private func refreshAssertions() {
        guard isActive, !isPaused else {
            releaseAssertions()
            return
        }

        guard holdAssertion(type: kIOPMAssertionTypeNoIdleSleep as CFString, storage: &idleAssertion) else {
            deactivateAfterAssertionFailure("Could not prevent system sleep.")
            return
        }

        if allowDisplaySleep {
            releaseAssertion(&displayAssertion)
        } else if !holdAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                 storage: &displayAssertion) {
            deactivateAfterAssertionFailure("Could not prevent display sleep.")
        }
    }

    private func holdAssertion(type: CFString, storage: inout IOPMAssertionID) -> Bool {
        guard storage == 0 else { return true }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Geraldine Keep Awake" as CFString,
                                                 &assertionID)
        guard result == kIOReturnSuccess else { return false }
        storage = assertionID
        return true
    }

    private func deactivateAfterAssertionFailure(_ message: String) {
        endSession()
        lastError = message
    }

    private func releaseAssertions() {
        releaseAssertion(&idleAssertion)
        releaseAssertion(&displayAssertion)
    }

    private func releaseAssertion(_ assertion: inout IOPMAssertionID) {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    nonisolated static func isOnBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == (kIOPSBatteryPowerValue as String)
    }

    private static func command(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host?.lowercased()
        let path = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()

        if host == "awake", !path.isEmpty { return path }
        if let host, ["activate", "deactivate", "toggle"].contains(host) { return host }
        if ["activate", "deactivate", "toggle"].contains(path) { return path }
        return nil
    }

    private static func durationOverride(from url: URL) -> (wasSpecified: Bool, seconds: TimeInterval?) {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return (false, nil)
        }

        if let raw = value(for: ["duration", "mode"], in: items)?.lowercased(),
           ["indefinite", "indefinitely", "forever"].contains(raw) {
            return (true, nil)
        }

        var total: TimeInterval = 0
        var specified = false
        if let hours = Double(value(for: ["hours", "hour"], in: items) ?? "") {
            total += max(0, hours) * 60 * 60
            specified = true
        }
        if let minutes = Double(value(for: ["minutes", "minute", "mins", "min"], in: items) ?? "") {
            total += max(0, minutes) * 60
            specified = true
        }

        return specified ? (true, max(1, total)) : (false, nil)
    }

    private static func value(for names: [String], in items: [URLQueryItem]) -> String? {
        let wanted = Set(names.map { $0.lowercased() })
        return items.first { wanted.contains($0.name.lowercased()) }?.value
    }

    static func durationString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 && minutes < 10 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }
}
