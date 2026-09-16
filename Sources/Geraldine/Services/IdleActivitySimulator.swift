import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit

enum IdleActivitySimulationPhase: Equatable {
    case off
    case waiting
    case pulsing
    case needsAccessibility
    case failed
}

struct IdleActivitySimulationSnapshot: Equatable {
    var phase: IdleActivitySimulationPhase
    var lastPulse: Date?
    var lastUserInput: Date?
    var errorMessage: String?
}

/// Simulates activity with mouse nudges and Control-key presses once the user has been
/// idle for a configurable delay. Idleness comes from polling the system's
/// HIDIdleTime counter — deliberately not a CGEvent tap, so Geraldine never
/// sits in the delivery path of real keyboard or mouse input.
@MainActor
final class IdleActivitySimulationService {
    var onSnapshotChange: ((IdleActivitySimulationSnapshot) -> Void)?

    private static let mouseNudgeDistanceRange = 4.0...14.0
    // Our own pulses reset HIDIdleTime. Date is kept for the UI, while uptime
    // gives the detector the same monotonic clock semantics as HIDIdleTime.
    // The small tolerance covers event-delivery skew without swallowing real
    // input that arrives shortly after Geraldine's synthetic pulse.
    private static let realInputTolerance: TimeInterval = 0.05

    private var idleDelay: TimeInterval
    private var isEnabled = false
    private var isPulsing = false
    private var phase: IdleActivitySimulationPhase = .off
    private var lastPulse: Date?
    private var lastPulseUptime: TimeInterval?
    private var lastUserInput = Date()
    private var errorMessage: String?
    private var timer: Timer?
    private let accessibilityAvailable: () -> Bool
    private let currentIdleDuration: () -> TimeInterval?
    private let injectedPulsePoster: (() -> Bool)?
    private let uptime: () -> TimeInterval
    // Random spacing targets the requested 24–30 active seconds per minute.
    // Reserve 0.1s below the 2.5s maximum gap for ordinary timer lateness.
    // Multiple events in one pulse still count as only one active second.
    // Real input and controller pauses take priority.
    private let nextPulseInterval: () -> TimeInterval

    init(
        idleDelay: TimeInterval = 120,
        accessibilityAvailable: (() -> Bool)? = nil,
        currentIdleDuration: (() -> TimeInterval?)? = nil,
        pulsePoster: (() -> Bool)? = nil,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        nextPulseInterval: @escaping () -> TimeInterval = { Double.random(in: 2...2.4) }
    ) {
        self.idleDelay = idleDelay
        self.accessibilityAvailable = accessibilityAvailable ?? { Permissions.hasAccessibilityAccess() }
        self.currentIdleDuration = currentIdleDuration ?? { Self.currentHIDIdleDuration() }
        injectedPulsePoster = pulsePoster
        self.uptime = uptime
        self.nextPulseInterval = nextPulseInterval
    }

    var hasScheduledTimer: Bool { timer != nil }
    var nextFireDate: Date? { timer?.fireDate }

    func start(idleDelay newIdleDelay: TimeInterval? = nil) {
        if let newIdleDelay {
            idleDelay = max(1, newIdleDelay)
        }
        isEnabled = true
        errorMessage = nil

        guard accessibilityAvailable() else {
            stopRuntime(phase: .needsAccessibility)
            return
        }

        guard let currentIdle = currentIdleDuration() else {
            stopRuntime(phase: .failed, errorMessage: "Could Not Read System Idle Time")
            return
        }

        lastUserInput = Date().addingTimeInterval(-currentIdle)
        lastPulse = nil
        lastPulseUptime = nil
        isPulsing = false

        if currentIdle >= idleDelay {
            beginPulsing()
        } else {
            setPhase(.waiting)
            schedule(after: idleDelay - currentIdle)
        }
    }

    func stop() {
        isEnabled = false
        stopRuntime(phase: .off)
    }

    private func stopRuntime(phase: IdleActivitySimulationPhase, errorMessage: String? = nil) {
        timer?.invalidate()
        timer = nil
        isPulsing = false
        lastPulseUptime = nil
        self.errorMessage = errorMessage
        setPhase(phase)
    }

    private func schedule(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: max(0.25, interval), repeats: false) { [weak self] _ in
            Self.deliverMainRunLoopTimerCallback {
                self?.timerFired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    nonisolated static func deliverMainRunLoopTimerCallback(
        _ callback: @MainActor () -> Void
    ) {
        precondition(Thread.isMainThread, "Idle activity timers must run on the main run loop")
        MainActor.assumeIsolated(callback)
    }

    func timerFired() {
        guard isEnabled else { return }

        guard accessibilityAvailable() else {
            stopRuntime(phase: .needsAccessibility)
            return
        }

        guard let idle = currentIdleDuration() else {
            stopRuntime(phase: .failed, errorMessage: "Could Not Read System Idle Time")
            return
        }

        if isPulsing {
            // The idle clock restarts at every event, including our own pulses.
            // An idle time noticeably younger than our last pulse therefore
            // means real input arrived since then: the user is back.
            let nowUptime = uptime()
            let sinceLastPulse = lastPulseUptime.map { nowUptime - $0 } ?? .greatestFiniteMagnitude
            if idle + Self.realInputTolerance < sinceLastPulse {
                isPulsing = false
                lastUserInput = Date().addingTimeInterval(-idle)
                setPhase(.waiting)
                schedule(after: max(1, idleDelay - idle))
                return
            }
            performPulseCycle()
            return
        }

        lastUserInput = Date().addingTimeInterval(-idle)
        if idle >= idleDelay {
            beginPulsing()
        } else {
            setPhase(.waiting)
            schedule(after: idleDelay - idle)
        }
    }

    private func beginPulsing() {
        isPulsing = true
        setPhase(.pulsing)
        performPulseCycle()
    }

    func performPulseCycle() {
        guard isEnabled, isPulsing else { return }
        guard pulse() else { return }
        schedule(after: nextPulseInterval())
    }

    @discardableResult
    private func pulse() -> Bool {
        guard postPulse() else {
            stopRuntime(phase: .failed, errorMessage: "Could Not Post Input Events")
            return false
        }

        lastPulse = Date()
        lastPulseUptime = uptime()
        setPhase(.pulsing)
        return true
    }

    private func postPulse() -> Bool {
        if let injectedPulsePoster {
            return injectedPulsePoster()
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        // A bare Control press adds keyboard activity without typing text or
        // navigating with arrow keys. Always construct both events before posting.
        guard let keys = Self.makeControlKeyPulse(source: source),
              postMouseNudge(source: source) else { return false }
        keys.down.post(tap: .cghidEventTap)
        keys.up.post(tap: .cghidEventTap)
        return true
    }

    static func makeControlKeyPulse(source: CGEventSource) -> (down: CGEvent, up: CGEvent)? {
        let controlKey: CGKeyCode = 59
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: controlKey, keyDown: false) else {
            return nil
        }
        return (down, up)
    }

    private func postMouseNudge(source: CGEventSource) -> Bool {
        let current = Self.currentMouseLocation()
        let nudge = Self.randomMouseNudge()

        let target = Self.clampedMousePoint(CGPoint(x: current.x + nudge.x,
                                                    y: current.y + nudge.y),
                                            near: current)
        guard CGWarpMouseCursorPosition(target) == .success else { return false }
        guard postMouseMove(to: target, source: source) else { return false }
        guard CGWarpMouseCursorPosition(current) == .success else { return false }
        return postMouseMove(to: current, source: source)
    }

    private func postMouseMove(to point: CGPoint, source: CGEventSource) -> Bool {
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func setPhase(_ phase: IdleActivitySimulationPhase) {
        self.phase = phase
        onSnapshotChange?(.init(phase: phase,
                                lastPulse: lastPulse,
                                lastUserInput: lastUserInput,
                                errorMessage: errorMessage))
    }

    private static func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? CGPoint(x: CGFloat(CGDisplayPixelsWide(CGMainDisplayID())) / 2,
                                                  y: CGFloat(CGDisplayPixelsHigh(CGMainDisplayID())) / 2)
    }

    private static func randomMouseNudge() -> CGPoint {
        let angle = Double.random(in: 0..<(Double.pi * 2))
        let distance = Double.random(in: mouseNudgeDistanceRange)
        return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }

    private static func clampedMousePoint(_ point: CGPoint, near current: CGPoint) -> CGPoint {
        let bounds = displayBounds(containing: current) ?? CGDisplayBounds(CGMainDisplayID())
        let inset = bounds.insetBy(dx: 4, dy: 4)
        return CGPoint(x: min(max(point.x, inset.minX), inset.maxX),
                       y: min(max(point.y, inset.minY), inset.maxY))
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return nil
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }

        return displays
            .prefix(Int(displayCount))
            .map { CGDisplayBounds($0) }
            .first { $0.insetBy(dx: 4, dy: 4).contains(point) }
    }

    private static func currentHIDIdleDuration() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(service,
                                                            "HIDIdleTime" as CFString,
                                                            kCFAllocatorDefault,
                                                            0)?.takeRetainedValue(),
              let idleNanos = property as? NSNumber else {
            return nil
        }
        return idleNanos.doubleValue / 1_000_000_000
    }
}
