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

/// Simulates activity (mouse nudges / arrow-key pairs) once the user has been
/// idle for a configurable delay. Idleness comes from polling the system's
/// HIDIdleTime counter — deliberately not a CGEvent tap, so Geraldine never
/// sits in the delivery path of real keyboard or mouse input.
final class IdleActivitySimulationService {
    var onSnapshotChange: ((IdleActivitySimulationSnapshot) -> Void)?

    private enum PulseAction {
        case mouseNudge
        case arrowKeyPair([CGKeyCode])
    }

    private static let arrowLeftKeyCode: CGKeyCode = 123
    private static let arrowRightKeyCode: CGKeyCode = 124
    private static let arrowUpKeyCode: CGKeyCode = 126
    private static let arrowDownKeyCode: CGKeyCode = 125
    // Keyboard pulses stay limited to opposing arrow-key pairs.
    private static let arrowKeyPairs = [
        [arrowLeftKeyCode, arrowRightKeyCode],
        [arrowRightKeyCode, arrowLeftKeyCode],
        [arrowUpKeyCode, arrowDownKeyCode],
        [arrowDownKeyCode, arrowUpKeyCode]
    ]
    private static let pulseIntervalJitter = 0.6...1.8
    private static let mouseNudgeDistanceRange = 4.0...14.0
    // Our own pulses reset HIDIdleTime. Date is kept for the UI, while uptime
    // gives the detector the same monotonic clock semantics as HIDIdleTime.
    // The small tolerance covers event-delivery skew without swallowing real
    // input that arrives shortly after Geraldine's synthetic pulse.
    private static let realInputTolerance: TimeInterval = 0.05

    private var idleDelay: TimeInterval
    private let pulseInterval: TimeInterval
    private var isEnabled = false
    private var isPulsing = false
    private var phase: IdleActivitySimulationPhase = .off
    private var lastPulse: Date?
    private var lastPulseUptime: TimeInterval?
    private var lastUserInput = Date()
    private var errorMessage: String?
    private var timer: Timer?

    init(idleDelay: TimeInterval = 120, pulseInterval: TimeInterval = 30) {
        self.idleDelay = idleDelay
        self.pulseInterval = pulseInterval
    }

    func start(idleDelay newIdleDelay: TimeInterval? = nil) {
        if let newIdleDelay {
            idleDelay = max(1, newIdleDelay)
        }
        isEnabled = true
        errorMessage = nil

        guard Permissions.hasAccessibilityAccess() else {
            stopRuntime(phase: .needsAccessibility)
            return
        }

        guard let currentIdle = Self.currentHIDIdleDuration() else {
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
            self?.timerFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func timerFired() {
        guard isEnabled else { return }

        guard Permissions.hasAccessibilityAccess() else {
            stopRuntime(phase: .needsAccessibility)
            return
        }

        guard let idle = Self.currentHIDIdleDuration() else {
            stopRuntime(phase: .failed, errorMessage: "Could Not Read System Idle Time")
            return
        }

        if isPulsing {
            // The idle clock restarts at every event, including our own pulses.
            // An idle time noticeably younger than our last pulse therefore
            // means real input arrived since then: the user is back.
            let nowUptime = ProcessInfo.processInfo.systemUptime
            let sinceLastPulse = lastPulseUptime.map { nowUptime - $0 } ?? .greatestFiniteMagnitude
            if idle + Self.realInputTolerance < sinceLastPulse {
                isPulsing = false
                lastUserInput = Date().addingTimeInterval(-idle)
                setPhase(.waiting)
                schedule(after: max(1, idleDelay - idle))
                return
            }
            pulse()
            schedule(after: nextPulseInterval())
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
        pulse()
        schedule(after: nextPulseInterval())
    }

    private func pulse() {
        guard postPulse() else {
            stopRuntime(phase: .failed, errorMessage: "Could Not Post Input Events")
            return
        }

        lastPulse = Date()
        lastPulseUptime = ProcessInfo.processInfo.systemUptime
        setPhase(.pulsing)
    }

    private func postPulse() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }

        for action in randomPulseActions() {
            switch action {
            case .mouseNudge:
                guard postMouseNudge(source: source) else { return false }
            case .arrowKeyPair(let keyCodes):
                for keyCode in keyCodes {
                    guard postKey(keyCode, source: source) else { return false }
                }
            }
        }

        return true
    }

    private func nextPulseInterval() -> TimeInterval {
        max(1, pulseInterval * Double.random(in: Self.pulseIntervalJitter))
    }

    private func randomPulseActions() -> [PulseAction] {
        var actions: [PulseAction] = []

        if Bool.random() {
            actions.append(.mouseNudge)
        }

        if Bool.random(), let keyCodes = Self.arrowKeyPairs.randomElement() {
            actions.append(.arrowKeyPair(keyCodes))
        }

        if actions.isEmpty {
            if Bool.random(), let keyCodes = Self.arrowKeyPairs.randomElement() {
                actions.append(.arrowKeyPair(keyCodes))
            } else {
                actions.append(.mouseNudge)
            }
        }

        actions.shuffle()
        return actions
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

    private func postKey(_ keyCode: CGKeyCode, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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
