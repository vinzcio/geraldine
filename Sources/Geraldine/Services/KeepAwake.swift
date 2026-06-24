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
        case .tenMinutes: return "10 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        case .eightHours: return "8 hours"
        case .twelveHours: return "12 hours"
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
}

@MainActor
final class KeepAwakeController: ObservableObject {
    private enum DefaultsKey {
        static let defaultDuration = "keepAwake.defaultDuration"
        static let allowDisplaySleep = "keepAwake.allowDisplaySleep"
        static let deactivateOnBattery = "keepAwake.deactivateOnBattery"
        static let pauseWhenScreenLocked = "keepAwake.pauseWhenScreenLocked"
    }

    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var pauseReason: String?
    @Published private(set) var activeUntil: Date?
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var lastError: String?

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

    private static let screenLockPauseReason = "Screen locked"
    private let defaults: UserDefaults
    private var idleAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var expirationTimer: Timer?
    private var ticker: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawDuration = defaults.string(forKey: DefaultsKey.defaultDuration) ?? KeepAwakeDuration.oneHour.rawValue
        defaultDuration = KeepAwakeDuration(rawValue: rawDuration) ?? .oneHour
        allowDisplaySleep = defaults.bool(forKey: DefaultsKey.allowDisplaySleep)
        deactivateOnBattery = defaults.bool(forKey: DefaultsKey.deactivateOnBattery)
        pauseWhenScreenLocked = defaults.bool(forKey: DefaultsKey.pauseWhenScreenLocked)

        installPowerSourceObserver()
        installWorkspaceObservers()
    }

    var statusLine: String {
        guard isActive else { return "Off" }
        if isPaused, let pauseReason { return "Paused · \(pauseReason)" }
        if let remaining { return "On · \(Self.durationString(remaining)) left" }
        return "On · Indefinitely"
    }

    var endTimeLine: String {
        if let activeUntil {
            return "Until \(activeUntil.formatted(date: .omitted, time: .shortened))"
        }
        return "No scheduled end"
    }

    func activateDefault() {
        activate(duration: defaultDuration.seconds)
    }

    func activate(option: KeepAwakeDuration) {
        activate(duration: option.seconds)
    }

    func activate(duration: TimeInterval?) {
        lastError = nil
        isActive = true
        isPaused = false
        pauseReason = nil
        activeUntil = duration.map { Date().addingTimeInterval(max(1, $0)) }
        updateRemaining()
        scheduleExpirationTimer()
        startTicker()
        refreshAssertions()
    }

    func deactivate() {
        isActive = false
        isPaused = false
        pauseReason = nil
        activeUntil = nil
        remaining = nil
        lastError = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        ticker?.invalidate()
        ticker = nil
        releaseAssertions()
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
    }

    private func resumeFromPolicyPause() {
        guard isActive, isPaused, pauseReason == Self.screenLockPauseReason else { return }
        isPaused = false
        pauseReason = nil
        refreshAssertions()
    }

    private func handlePowerSourceChange() {
        guard deactivateOnBattery, isActive, Self.isOnBatteryPower() else { return }
        deactivate()
    }

    private func scheduleExpirationTimer() {
        expirationTimer?.invalidate()
        expirationTimer = nil

        guard let activeUntil else { return }
        let interval = max(0.1, activeUntil.timeIntervalSinceNow)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.deactivate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimer = timer
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
        } else if !holdAssertion(type: kIOPMAssertionTypeNoDisplaySleep as CFString, storage: &displayAssertion) {
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
        releaseAssertions()
        isActive = false
        isPaused = false
        pauseReason = nil
        activeUntil = nil
        remaining = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        ticker?.invalidate()
        ticker = nil
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

    private static func isOnBatteryPower() -> Bool {
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
