import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum DockActiveClickBehavior: String, CaseIterable, Identifiable {
    case system
    case hideApp
    case minimizeWindows
    case cycleWindows

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .hideApp: return "Hide App"
        case .minimizeWindows: return "Minimize Windows"
        case .cycleWindows: return "Cycle Windows"
        }
    }
}

enum DockActiveClickInterceptionPolicy {
    /// A custom active-app action is only safe to intercept when the target
    /// currently owns a visible window. A windowless, hidden, or fully
    /// minimized app needs the original Dock click so macOS can reopen it.
    ///
    /// The visibility lookup is deliberately deferred: an inactive target and
    /// the System behavior must pass through without an accessibility query.
    static func shouldIntercept(
        behavior: DockActiveClickBehavior,
        targetIsFrontmost: Bool,
        hasVisibleWindow: () -> Bool
    ) -> Bool {
        guard behavior != .system, targetIsFrontmost else { return false }
        return hasVisibleWindow()
    }
}

/// What a click could trigger under the Dock settings, decided from the event
/// alone. Every other click passes through without an accessibility query.
enum DockClickIntent: Equatable {
    case middleClick(DockMiddleClickBehavior)
    case shiftClickNewWindow
    case activeClick(DockActiveClickBehavior)

    static func intent(
        type: CGEventType,
        buttonNumber: Int64,
        flags: CGEventFlags,
        middleClickBehavior: DockMiddleClickBehavior,
        shiftClickNewWindow: Bool,
        activeClickBehavior: DockActiveClickBehavior
    ) -> DockClickIntent? {
        switch type {
        case .otherMouseDown:
            guard buttonNumber == 2, middleClickBehavior != .system else { return nil }
            return .middleClick(middleClickBehavior)
        case .leftMouseDown:
            if flags.contains(.maskShift), shiftClickNewWindow { return .shiftClickNewWindow }
            guard activeClickBehavior != .system else { return nil }
            return .activeClick(activeClickBehavior)
        default:
            return nil
        }
    }
}

/// The strip along the Dock's screen edge that can hold a Dock item, on
/// whichever display a click lands. Clicks outside it never ask the Dock what
/// they hit. Points and bounds use Quartz coordinates (y grows downward).
struct DockEdgeBand: Equatable {
    enum Edge: String {
        case bottom, left, right
    }

    /// Room beyond the largest tile for the Dock's padding and indicators.
    static let margin: CGFloat = 40
    static let defaultTileSize: CGFloat = 64
    static let defaultMagnifiedSize: CGFloat = 128

    let edge: Edge
    let depth: CGFloat

    init(edge: Edge, depth: CGFloat) {
        self.edge = edge
        self.depth = depth
    }

    init(orientation: String?, tileSize: Double?, magnifies: Bool, magnifiedSize: Double?) {
        let tile = Self.size(tileSize) ?? Self.defaultTileSize
        let magnified = magnifies ? (Self.size(magnifiedSize) ?? Self.defaultMagnifiedSize) : 0
        self.init(edge: orientation.flatMap(Edge.init(rawValue:)) ?? .bottom,
                  depth: max(tile, magnified) + Self.margin)
    }

    /// Reads the Dock's own preferences (`com.apple.dock`).
    init(dockPreferences defaults: UserDefaults?) {
        self.init(
            orientation: defaults?.string(forKey: "orientation"),
            tileSize: defaults?.object(forKey: "tilesize") as? Double,
            magnifies: defaults?.bool(forKey: "magnification") ?? false,
            magnifiedSize: defaults?.object(forKey: "largesize") as? Double
        )
    }

    func contains(_ point: CGPoint, displayBounds: CGRect) -> Bool {
        guard displayBounds.contains(point) else { return false }
        switch edge {
        case .bottom: return point.y >= displayBounds.maxY - depth
        case .left: return point.x < displayBounds.minX + depth
        case .right: return point.x >= displayBounds.maxX - depth
        }
    }

    static func displayBounds(containing point: CGPoint) -> CGRect? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return CGDisplayBounds(display)
    }

    private static func size(_ value: Double?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(max(CGFloat(value), 16), 256)
    }
}

enum DockMiddleClickBehavior: String, CaseIterable, Identifiable {
    case system
    case hideApp
    case minimizeWindows
    case newWindow
    case quitApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .hideApp: return "Hide App"
        case .minimizeWindows: return "Minimize Windows"
        case .newWindow: return "New Window"
        case .quitApp: return "Quit App"
        }
    }
}

enum PowerToolResultStatus: Equatable, Sendable {
    case success
    case warning
    case failure
}

struct PowerToolResult: Equatable, Sendable {
    let message: String
    let status: PowerToolResultStatus

    static func success(_ message: String) -> PowerToolResult {
        PowerToolResult(message: message, status: .success)
    }

    static func warning(_ message: String) -> PowerToolResult {
        PowerToolResult(message: message, status: .warning)
    }

    static func failure(_ message: String) -> PowerToolResult {
        PowerToolResult(message: message, status: .failure)
    }
}

enum PowerToolAction {
    case hideAllWindows
    case isolateFrontWindow
    case minimizeAllWindows
    case newFinderTextFile(markdown: Bool)
    case copyFinderPaths
    case copyFinderSHA256
    case openFinderTerminal
    case copyFinderSelectionToFolder
    case moveFinderSelectionToFolder
    case clearClipboard
    case sleepDisplays
    case ejectDisks
    case emptyTrash
}

struct PowerToolsOperationCoordinator {
    struct Ownership: Equatable, Sendable {
        let identifier: UUID
        let actionID: String
    }

    private(set) var ownership: Ownership?
    private(set) var latestResult: PowerToolResult?
    private(set) var latestResultOwnership: Ownership?

    var runningActionID: String? { ownership?.actionID }

    mutating func begin(actionID: String, identifier: UUID = UUID()) -> Ownership? {
        guard ownership == nil else { return nil }
        let newOwnership = Ownership(identifier: identifier, actionID: actionID)
        ownership = newOwnership
        latestResult = nil
        latestResultOwnership = nil
        return newOwnership
    }

    @discardableResult
    mutating func finish(_ finishingOwnership: Ownership, result: PowerToolResult) -> Bool {
        guard ownership == finishingOwnership else { return false }
        ownership = nil
        latestResult = result
        latestResultOwnership = finishingOwnership
        return true
    }

    mutating func invalidate() {
        ownership = nil
    }

    mutating func clearResult() {
        latestResult = nil
        latestResultOwnership = nil
    }

    func isLatestResult(ownedBy completedOwnership: Ownership) -> Bool {
        latestResultOwnership == completedOwnership
    }
}

enum PowerToolsEffectRunner {
    static func run<Output: Sendable>(
        _ effect: @escaping @Sendable () -> Output
    ) async -> Output {
        await Task.detached(priority: .userInitiated) {
            effect()
        }.value
    }
}

private enum PowerToolKeys {
    static let dockActionsEnabled = "powerTools.dock.actionsEnabled"
    static let dockWindowPreviewsEnabled = "powerTools.dock.windowPreviewsEnabled"
    static let activeDockClickBehavior = "powerTools.dock.activeClickBehavior"
    static let middleClickBehavior = "powerTools.dock.middleClickBehavior"
    static let shiftClickNewWindow = "powerTools.dock.shiftClickNewWindow"
    static let unminimizeOnActivation = "powerTools.window.unminimizeOnActivation"
    static let greenButtonFillsWindow = "powerTools.window.greenButtonFillsWindow"
    static let yellowButtonHidesApp = "powerTools.window.yellowButtonHidesApp"
    static let missionControlTwoFingerClose = "powerTools.window.missionControlTwoFingerClose"
    static let commandQDoubleTap = "powerTools.keyboard.commandQDoubleTap"
    static let commandWDoubleTap = "powerTools.keyboard.commandWDoubleTap"
    static let finderReturnOpens = "powerTools.finder.returnOpens"
    static let finderCutPaste = "powerTools.finder.cutPaste"
    static let finderOptionNNewFile = "powerTools.finder.optionNNewFile"
    static let finderBackspaceMovesToTrash = "powerTools.finder.backspaceMovesToTrash"
}

@MainActor
final class PowerToolsController: ObservableObject {
    @Published private(set) var accessibilityTrusted = Permissions.hasAccessibilityAccess()
    @Published private(set) var screenRecordingTrusted = Permissions.hasScreenRecordingAccess()
    @Published private(set) var runningActionID: String?
    @Published private(set) var lastResult: PowerToolResult?

    @Published var dockWindowPreviewsEnabled: Bool {
        didSet {
            defaults.set(dockWindowPreviewsEnabled, forKey: PowerToolKeys.dockWindowPreviewsEnabled)
            applyHooks()
        }
    }
    @Published var dockActionsEnabled: Bool {
        didSet { defaults.set(dockActionsEnabled, forKey: PowerToolKeys.dockActionsEnabled); applyHooks() }
    }
    @Published var activeDockClickBehavior: DockActiveClickBehavior {
        didSet { defaults.set(activeDockClickBehavior.rawValue, forKey: PowerToolKeys.activeDockClickBehavior); applyHooks() }
    }
    @Published var middleClickBehavior: DockMiddleClickBehavior {
        didSet { defaults.set(middleClickBehavior.rawValue, forKey: PowerToolKeys.middleClickBehavior); applyHooks() }
    }
    @Published var shiftClickNewWindow: Bool {
        didSet { defaults.set(shiftClickNewWindow, forKey: PowerToolKeys.shiftClickNewWindow); applyHooks() }
    }
    @Published var unminimizeOnActivation: Bool {
        didSet { defaults.set(unminimizeOnActivation, forKey: PowerToolKeys.unminimizeOnActivation); applyHooks() }
    }
    @Published var greenButtonFillsWindow: Bool {
        didSet { defaults.set(greenButtonFillsWindow, forKey: PowerToolKeys.greenButtonFillsWindow); applyHooks() }
    }
    @Published var yellowButtonHidesApp: Bool {
        didSet { defaults.set(yellowButtonHidesApp, forKey: PowerToolKeys.yellowButtonHidesApp); applyHooks() }
    }
    @Published var missionControlTwoFingerClose: Bool {
        didSet { defaults.set(missionControlTwoFingerClose, forKey: PowerToolKeys.missionControlTwoFingerClose); applyHooks() }
    }
    @Published var commandQDoubleTap: Bool {
        didSet { defaults.set(commandQDoubleTap, forKey: PowerToolKeys.commandQDoubleTap); applyHooks() }
    }
    @Published var commandWDoubleTap: Bool {
        didSet { defaults.set(commandWDoubleTap, forKey: PowerToolKeys.commandWDoubleTap); applyHooks() }
    }
    @Published var finderReturnOpens: Bool {
        didSet { defaults.set(finderReturnOpens, forKey: PowerToolKeys.finderReturnOpens); applyHooks() }
    }
    @Published var finderCutPaste: Bool {
        didSet { defaults.set(finderCutPaste, forKey: PowerToolKeys.finderCutPaste); applyHooks() }
    }
    @Published var finderOptionNNewFile: Bool {
        didSet { defaults.set(finderOptionNNewFile, forKey: PowerToolKeys.finderOptionNNewFile); applyHooks() }
    }
    @Published var finderBackspaceMovesToTrash: Bool {
        didSet {
            defaults.set(finderBackspaceMovesToTrash, forKey: PowerToolKeys.finderBackspaceMovesToTrash)
            applyHooks()
        }
    }

    let finder = FinderPowerToolsService()
    let system = SystemPowerToolsService()

    private let defaults: UserDefaults
    private let dockService = DockInteractionService()
    private let dockPreviewService = DockWindowPreviewService()
    private let trafficLightService = TrafficLightButtonService()
    private let missionControlCloseService = MissionControlCloseService()
    private let keyboardService = KeyboardPowerToolsService()
    private let windowService = WindowActionService()
    private var operationCoordinator = PowerToolsOperationCoordinator()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dockWindowPreviewsEnabled = defaults.bool(forKey: PowerToolKeys.dockWindowPreviewsEnabled)
        dockActionsEnabled = defaults.bool(forKey: PowerToolKeys.dockActionsEnabled)
        let activeRaw = defaults.string(forKey: PowerToolKeys.activeDockClickBehavior) ?? DockActiveClickBehavior.system.rawValue
        activeDockClickBehavior = DockActiveClickBehavior(rawValue: activeRaw) ?? .system
        let middleRaw = defaults.string(forKey: PowerToolKeys.middleClickBehavior) ?? DockMiddleClickBehavior.system.rawValue
        middleClickBehavior = DockMiddleClickBehavior(rawValue: middleRaw) ?? .system
        shiftClickNewWindow = defaults.bool(forKey: PowerToolKeys.shiftClickNewWindow)
        unminimizeOnActivation = defaults.bool(forKey: PowerToolKeys.unminimizeOnActivation)
        greenButtonFillsWindow = defaults.bool(forKey: PowerToolKeys.greenButtonFillsWindow)
        yellowButtonHidesApp = defaults.bool(forKey: PowerToolKeys.yellowButtonHidesApp)
        missionControlTwoFingerClose = defaults.object(forKey: PowerToolKeys.missionControlTwoFingerClose) as? Bool ?? true
        commandQDoubleTap = defaults.bool(forKey: PowerToolKeys.commandQDoubleTap)
        commandWDoubleTap = defaults.bool(forKey: PowerToolKeys.commandWDoubleTap)
        finderReturnOpens = defaults.bool(forKey: PowerToolKeys.finderReturnOpens)
        finderCutPaste = defaults.bool(forKey: PowerToolKeys.finderCutPaste)
        finderOptionNNewFile = defaults.bool(forKey: PowerToolKeys.finderOptionNNewFile)
        finderBackspaceMovesToTrash = defaults.bool(forKey: PowerToolKeys.finderBackspaceMovesToTrash)
    }

    func start() {
        refreshAccessibility()
        applyHooks()
    }

    func stop() {
        dockService.stop()
        dockPreviewService.stop()
        trafficLightService.stop()
        missionControlCloseService.stop()
        keyboardService.stop()
        windowService.stopActivationObserver()
    }

    func refreshAccessibility(prompt: Bool = false) {
        accessibilityTrusted = prompt ? Permissions.requestAccessibilityAccess() : Permissions.hasAccessibilityAccess()
        screenRecordingTrusted = Permissions.hasScreenRecordingAccess()
        dockPreviewService.updateScreenRecordingAccess(screenRecordingTrusted)
        applyHooks()
    }

    func requestDockPreviewThumbnails() {
        screenRecordingTrusted = Permissions.requestScreenRecordingAccess()
        dockPreviewService.updateScreenRecordingAccess(screenRecordingTrusted)
        if !screenRecordingTrusted {
            Permissions.openScreenRecordingSettings()
        }
    }

    func beginAction(actionID: String) -> PowerToolsOperationCoordinator.Ownership? {
        guard let ownership = operationCoordinator.begin(actionID: actionID) else { return nil }
        publishOperationState()
        return ownership
    }

    @discardableResult
    func perform(
        ownership: PowerToolsOperationCoordinator.Ownership,
        action: PowerToolAction
    ) async -> Bool {
        let result = await result(for: action)
        guard operationCoordinator.finish(ownership, result: result) else { return false }
        publishOperationState()
        return true
    }

    func clearResult() {
        operationCoordinator.clearResult()
        publishOperationState()
    }

    func isLatestResult(ownedBy ownership: PowerToolsOperationCoordinator.Ownership) -> Bool {
        operationCoordinator.isLatestResult(ownedBy: ownership)
    }

    private func result(for action: PowerToolAction) async -> PowerToolResult {
        switch action {
        case .hideAllWindows:
            WindowActionService.hideAllWindows()
            return .success("Hid visible app windows.")
        case .isolateFrontWindow:
            return WindowActionService.isolateFrontWindow()
        case .minimizeAllWindows:
            WindowActionService.minimizeWindows()
            return .success("Minimized visible windows.")
        case .newFinderTextFile(let markdown):
            return await finder.createTextFile(markdown: markdown)
        case .copyFinderPaths:
            return finder.copySelectedPaths()
        case .copyFinderSHA256:
            return await finder.copyChecksumSHA256()
        case .openFinderTerminal:
            return await finder.openTerminalHere()
        case .copyFinderSelectionToFolder:
            return await finder.chooseDestinationAndTransfer(copy: true)
        case .moveFinderSelectionToFolder:
            return await finder.chooseDestinationAndTransfer(copy: false)
        case .clearClipboard:
            return system.clearClipboard()
        case .sleepDisplays:
            return await system.sleepDisplays()
        case .ejectDisks:
            return await system.ejectAllDisks()
        case .emptyTrash:
            return await system.emptyTrash()
        }
    }

    private func publishOperationState() {
        runningActionID = operationCoordinator.runningActionID
        lastResult = operationCoordinator.latestResult
    }

    private func applyHooks() {
        guard accessibilityTrusted else {
            stop()
            return
        }

        let needsDockTap = dockActionsEnabled &&
            (activeDockClickBehavior != .system || middleClickBehavior != .system || shiftClickNewWindow)
        needsDockTap ? dockService.start() : dockService.stop()
        dockWindowPreviewsEnabled ? dockPreviewService.start() : dockPreviewService.stop()

        let needsTrafficTap = greenButtonFillsWindow || yellowButtonHidesApp
        needsTrafficTap ? trafficLightService.start() : trafficLightService.stop()

        missionControlTwoFingerClose ? missionControlCloseService.start() : missionControlCloseService.stop()

        let needsKeyboardTap = commandQDoubleTap || commandWDoubleTap || finderReturnOpens ||
            finderCutPaste || finderOptionNNewFile || finderBackspaceMovesToTrash
        needsKeyboardTap ? keyboardService.start() : keyboardService.stop()

        unminimizeOnActivation ? windowService.startActivationObserver() : windowService.stopActivationObserver()
    }
}

struct MissionControlTransformMath {
    static func contains(screenPoint: CGPoint, windowSize: CGSize, screenToWindow: CGAffineTransform) -> Bool {
        guard windowSize.width > 0, windowSize.height > 0 else { return false }
        let windowPoint = screenPoint.applying(screenToWindow)
        return CGRect(origin: .zero, size: windowSize).insetBy(dx: -2, dy: -2).contains(windowPoint)
    }
}

struct MissionControlWindowCandidate {
    let processIdentifier: pid_t
    let windowID: CGWindowID
    let windowSize: CGSize
    let screenToWindow: CGAffineTransform
}

enum MissionControlWindowTargeting {
    /// Candidates must be passed through in WindowServer's front-to-back order.
    /// A second hit means the thumbnail geometry is ambiguous (for example while
    /// Mission Control is settling), so do not guess and close a background window.
    static func candidate(
        at screenPoint: CGPoint,
        in candidates: [MissionControlWindowCandidate]
    ) -> MissionControlWindowCandidate? {
        var match: MissionControlWindowCandidate?

        for candidate in candidates where MissionControlTransformMath.contains(
            screenPoint: screenPoint,
            windowSize: candidate.windowSize,
            screenToWindow: candidate.screenToWindow
        ) {
            guard match == nil else { return nil }
            match = candidate
        }

        return match
    }
}

private typealias SLSMainConnectionIDFunction = @convention(c) () -> Int32
private typealias SLSGetWindowTransformFunction = @convention(c) (
    Int32,
    CGWindowID,
    UnsafeMutablePointer<CGAffineTransform>
) -> CGError
private typealias AXUIElementGetWindowFunction = @convention(c) (
    AXUIElement,
    UnsafeMutablePointer<CGWindowID>
) -> AXError

private enum MissionControlWindowServer {
    private static let skyLightHandle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_NOW
    )

    private static let mainConnectionID: SLSMainConnectionIDFunction? = symbol(
        named: "SLSMainConnectionID",
        in: skyLightHandle
    )

    private static let getWindowTransform: SLSGetWindowTransformFunction? =
        symbol(named: "SLSGetWindowTransform", in: skyLightHandle) ??
        symbol(named: "CGSGetWindowTransform", in: skyLightHandle)

    private static let getWindowID: AXUIElementGetWindowFunction? = symbol(
        named: "_AXUIElementGetWindow",
        in: UnsafeMutableRawPointer(bitPattern: -2)
    )

    static func window(at screenPoint: CGPoint, messagingTimeout: Float? = nil) -> AXUIElement? {
        guard let mainConnectionID, let getWindowTransform, let getWindowID else { return nil }
        let connection = mainConnectionID()
        var candidates: [MissionControlWindowCandidate] = []

        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for info in windowInfo {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let processIdentifier = info[kCGWindowOwnerPID as String] as? pid_t,
                  processIdentifier != 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 0,
                  bounds.height > 0 else { continue }

            var screenToWindow = CGAffineTransform.identity
            guard getWindowTransform(connection, windowID, &screenToWindow) == .success,
                  MissionControlTransformMath.contains(
                    screenPoint: screenPoint,
                    windowSize: bounds.size,
                    screenToWindow: screenToWindow
                  ) else { continue }

            candidates.append(MissionControlWindowCandidate(
                processIdentifier: processIdentifier,
                windowID: windowID,
                windowSize: bounds.size,
                screenToWindow: screenToWindow
            ))
        }

        guard let candidate = MissionControlWindowTargeting.candidate(
                  at: screenPoint,
                  in: candidates
              ),
              let app = NSRunningApplication(processIdentifier: candidate.processIdentifier) else {
            return nil
        }

        return AXTools.windows(of: app, messagingTimeout: messagingTimeout).first { window in
            var windowID: CGWindowID = 0
            return getWindowID(window, &windowID) == .success && windowID == candidate.windowID
        }
    }

    private static func symbol<T>(named name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let rawSymbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(rawSymbol, to: T.self)
    }
}

final class MissionControlCloseService {
    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
    ) { [weak self] _, event in
        self?.handle(event: event) ?? false
    }

    func start() { tap.start() }
    func stop() { tap.stop() }

    private func handle(event: CGEvent) -> Bool {
        let timeout = AXTools.eventTapMessagingTimeout
        guard UserDefaults.standard.object(forKey: PowerToolKeys.missionControlTwoFingerClose) as? Bool ?? true,
              AXTools.missionControlGroup(messagingTimeout: timeout) != nil,
              let window = MissionControlWindowServer.window(at: event.location, messagingTimeout: timeout) else {
            return false
        }

        // Closing waits on the window's app (a save sheet, a busy process), so
        // it runs after the tap answers. A right-click means nothing else in
        // Mission Control, so it is swallowed once a window is targeted.
        AXTools.unbounded(window)
        DispatchQueue.main.async {
            AXTools.close(window: window)
        }
        return true
    }
}

/// Shared CGEvent-tap plumbing for the Power Tools services: creates the session
/// tap, re-enables it when macOS disables it after a timeout, and tears it down
/// on `stop()`. The handler returns true to swallow the event, false to pass it
/// through.
///
/// macOS holds every event a filtering tap matches until the callback returns,
/// so filtering taps deliver on `EventTapThread`, never the main run loop: a busy
/// main thread must not delay, reorder, or drop clicks and keys across the Mac.
/// Their handlers run off the main thread. They must use thread-safe state, rule
/// events out without messaging other processes where they can, bound any
/// accessibility query with `AXTools.eventTapMessagingTimeout`, and hand the
/// resulting work to the main queue asynchronously. Listen-only taps cannot hold
/// input and keep delivering on the main run loop.
final class EventTapService {
    private let mask: CGEventMask
    private let options: CGEventTapOptions
    private let handler: (CGEventType, CGEvent) -> Bool
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(mask: CGEventMask, options: CGEventTapOptions = .defaultTap,
         handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.mask = mask
        self.options = options
        self.handler = handler
    }

    deinit {
        stop()
    }

    static func deliversOnMainRunLoop(_ options: CGEventTapOptions) -> Bool {
        options == .listenOnly
    }

    private var deliveryRunLoop: CFRunLoop {
        Self.deliversOnMainRunLoop(options) ? CFRunLoopGetMain() : EventTapThread.shared.runLoop
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard eventTap == nil else { return true }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: options,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        eventTap = tap
        runLoopSource = source
        let runLoop = deliveryRunLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns once no callback for this tap is running or can still arrive, so
    /// a service may reset its handler state afterwards.
    func stop() {
        lock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        lock.unlock()
        guard let tap else { return }

        let runLoop = deliveryRunLoop
        let teardown = {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        if Self.deliversOnMainRunLoop(options) {
            teardown()
        } else {
            EventTapThread.shared.sync(teardown)
        }
    }

    private func reenable() {
        lock.lock()
        defer { lock.unlock() }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            service.reenable()
            return Unmanaged.passUnretained(event)
        }

        return service.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}

/// The run loop that delivers filtering event taps. It never waits on the main
/// thread, and user-interactive QoS keeps it scheduled while the app is busy.
final class EventTapThread: Thread {
    static let shared: EventTapThread = {
        let thread = EventTapThread()
        thread.name = "com.vincent.geraldine.event-taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.started.wait()
        return thread
    }()

    private let started = DispatchSemaphore(value: 0)
    private var startedRunLoop: CFRunLoop?

    /// Set by `main()` before `shared` returns.
    var runLoop: CFRunLoop { startedRunLoop! }

    override func main() {
        startedRunLoop = CFRunLoopGetCurrent()
        // A run loop without sources returns at once; the port keeps it running.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while true {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// Runs `body` on this thread and waits for it. Blocks run between tap
    /// callbacks, so no callback is in flight while `body` runs.
    func sync(_ body: @escaping () -> Void) {
        if Thread.current === self {
            body()
            return
        }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            body()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
    }
}

final class DockInteractionService {
    private static let dockPreferences = UserDefaults(suiteName: "com.apple.dock")

    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
    ) { [weak self] type, event in
        self?.handle(type: type, event: event) ?? false
    }

    func start() { tap.start() }
    func stop() { tap.stop() }

    /// Sees every left and middle click on the Mac, so it rules clicks out from
    /// the event and settings first. Only a click in the Dock's edge band asks
    /// the Dock what it hit.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PowerToolKeys.dockActionsEnabled),
              let intent = DockClickIntent.intent(
                  type: type,
                  buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
                  flags: event.flags,
                  middleClickBehavior: defaults.string(forKey: PowerToolKeys.middleClickBehavior)
                      .flatMap(DockMiddleClickBehavior.init(rawValue:)) ?? .system,
                  shiftClickNewWindow: defaults.bool(forKey: PowerToolKeys.shiftClickNewWindow),
                  activeClickBehavior: defaults.string(forKey: PowerToolKeys.activeDockClickBehavior)
                      .flatMap(DockActiveClickBehavior.init(rawValue:)) ?? .system
              ) else {
            return false
        }

        let point = event.location
        guard let displayBounds = DockEdgeBand.displayBounds(containing: point),
              DockEdgeBand(dockPreferences: Self.dockPreferences).contains(point, displayBounds: displayBounds),
              let target = DockTarget.target(at: point) else {
            return false
        }

        switch intent {
        case .middleClick(let behavior):
            DispatchQueue.main.async {
                Self.performMiddleClick(behavior, app: target.app)
            }
            return true
        case .shiftClickNewWindow:
            DispatchQueue.main.async {
                WindowActionService.openNewWindow(for: target.app)
            }
            return true
        case .activeClick(let behavior):
            let timeout = AXTools.eventTapMessagingTimeout
            // NSWorkspace can lag behind while the main thread is busy, so the
            // target confirms it is active before its click is taken over.
            let targetIsFrontmost =
                target.app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier &&
                AXTools.reportsFrontmost(target.app, messagingTimeout: timeout)
            guard DockActiveClickInterceptionPolicy.shouldIntercept(
                behavior: behavior,
                targetIsFrontmost: targetIsFrontmost,
                hasVisibleWindow: {
                    WindowActionService.hasVisibleWindow(of: target.app, messagingTimeout: timeout)
                }
            ) else {
                return false
            }

            DispatchQueue.main.async {
                Self.performActiveClick(behavior, app: target.app)
            }
            return true
        }
    }

    private static func performActiveClick(_ behavior: DockActiveClickBehavior, app: NSRunningApplication) {
        switch behavior {
        case .system:
            break
        case .hideApp:
            app.hide()
        case .minimizeWindows:
            WindowActionService.minimizeWindows(of: app)
        case .cycleWindows:
            WindowActionService.cycleWindows(of: app)
        }
    }

    private static func performMiddleClick(_ behavior: DockMiddleClickBehavior, app: NSRunningApplication) {
        switch behavior {
        case .system:
            break
        case .hideApp:
            app.hide()
        case .minimizeWindows:
            WindowActionService.minimizeWindows(of: app)
        case .newWindow:
            WindowActionService.openNewWindow(for: app)
        case .quitApp:
            app.terminate()
        }
    }
}

private struct DockTarget {
    let app: NSRunningApplication

    static func target(at point: CGPoint) -> DockTarget? {
        guard let dockProcessIdentifier = DockWindowPreviewAccessibility.dockProcessIdentifier(),
              let target = DockWindowPreviewAccessibility.target(
                  at: point,
                  dockProcessIdentifier: dockProcessIdentifier,
                  candidates: DockWindowPreviewAccessibility.applicationCandidates(),
                  messagingTimeout: AXTools.eventTapMessagingTimeout
              ) else { return nil }
        return DockTarget(app: target.app)
    }
}

/// WindowServer's on-screen window list, which answers without messaging the
/// app that owns a window.
enum WindowServerHitTest {
    struct Window: Equatable {
        let processIdentifier: pid_t
        let bounds: CGRect
    }

    static func frontmostWindow(at point: CGPoint) -> Window? {
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return frontmostWindow(at: point, in: windowInfo)
    }

    /// The front-most visible window under `point` when it is an ordinary
    /// (layer 0) window; nil when a menu, panel, or overlay is on top.
    /// `windowInfo` is front-to-back, as WindowServer returns it.
    static func frontmostWindow(at point: CGPoint, in windowInfo: [[String: Any]]) -> Window? {
        for info in windowInfo {
            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let processIdentifier = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return Window(processIdentifier: processIdentifier, bounds: bounds)
        }
        return nil
    }
}

/// Window buttons sit in a title bar's top corner (top-right in right-to-left
/// layouts). Clicks anywhere else in a window skip the accessibility query.
enum TrafficLightRegion {
    static let height: CGFloat = 60
    static let width: CGFloat = 120

    static func contains(_ point: CGPoint, windowBounds: CGRect) -> Bool {
        guard windowBounds.contains(point), point.y - windowBounds.minY < height else { return false }
        return point.x - windowBounds.minX < width || windowBounds.maxX - point.x <= width
    }
}

final class TrafficLightButtonService {
    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    ) { [weak self] _, event in
        self?.handle(event: event) ?? false
    }

    func start() { tap.start() }
    func stop() { tap.stop() }

    /// Sees every left click on the Mac. Only a click in a standard window's
    /// button corner asks that window's app what it hit.
    private func handle(event: CGEvent) -> Bool {
        let point = event.location
        let timeout = AXTools.eventTapMessagingTimeout
        guard !event.flags.contains(.maskAlternate),
              let frontWindow = WindowServerHitTest.frontmostWindow(at: point),
              TrafficLightRegion.contains(point, windowBounds: frontWindow.bounds),
              let element = AXTools.element(
                  at: point, inApplication: frontWindow.processIdentifier, messagingTimeout: timeout
              ),
              let subrole = AXTools.string(element, kAXSubroleAttribute) else {
            return false
        }

        let defaults = UserDefaults.standard

        if subrole == "AXZoomButton", defaults.bool(forKey: PowerToolKeys.greenButtonFillsWindow),
           let window = AXTools.window(containing: element, messagingTimeout: timeout) {
            AXTools.unbounded(window)
            DispatchQueue.main.async {
                WindowActionService.fillOrRestore(window: window)
            }
            return true
        }

        if subrole == "AXMinimizeButton", defaults.bool(forKey: PowerToolKeys.yellowButtonHidesApp),
           let app = AXTools.runningApplication(for: element) {
            DispatchQueue.main.async {
                app.hide()
            }
            return true
        }

        return false
    }
}

// MARK: - Keyboard Power Tools Reducer

enum KeyboardPowerToolsKeyCode {
    static let q: Int64 = 12
    static let w: Int64 = 13
    static let x: Int64 = 7
    static let v: Int64 = 9
    static let n: Int64 = 45
    static let returnKey: Int64 = 36
    static let delete: Int64 = 51
}

struct KeyboardPowerToolsModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let command = KeyboardPowerToolsModifiers(rawValue: 1 << 0)
    static let shift = KeyboardPowerToolsModifiers(rawValue: 1 << 1)
    static let control = KeyboardPowerToolsModifiers(rawValue: 1 << 2)
    static let option = KeyboardPowerToolsModifiers(rawValue: 1 << 3)
}

struct KeyboardPowerToolsPreferences: Equatable, Sendable {
    let commandQDoubleTap: Bool
    let commandWDoubleTap: Bool
    let finderReturnOpens: Bool
    let finderCutPaste: Bool
    let finderOptionNNewFile: Bool
    let finderBackspaceMovesToTrash: Bool
}

struct KeyboardPowerToolsInput: Equatable, Sendable {
    let keyCode: Int64
    let modifiers: KeyboardPowerToolsModifiers
    let isAutorepeat: Bool
    let timestamp: TimeInterval
    let frontmostProcessIdentifier: pid_t?
    let frontmostBundleIdentifier: String?
    let finderCanHandleFileShortcut: Bool
    let hasFinderCutSession: Bool
}

enum KeyboardPowerToolsEffect: Equatable, Sendable {
    case beep
    case openFinderSelection
    case createTextFile
    case moveFinderSelectionToTrash
    case prepareCut
    case pasteCut
}

enum KeyboardPowerToolsFileEffect: Equatable, Sendable {
    case createTextFile
    case moveFinderSelectionToTrash
    case prepareCut
    case pasteCut
}

struct KeyboardPowerToolsFileEffectCoordinator {
    struct Ownership: Equatable, Sendable {
        let identifier: UUID
        let effect: KeyboardPowerToolsFileEffect
    }

    private(set) var ownership: Ownership?
    private var queuedOwnerships: [Ownership] = []

    var queuedEffects: [KeyboardPowerToolsFileEffect] {
        queuedOwnerships.map(\.effect)
    }

    mutating func enqueue(
        _ effect: KeyboardPowerToolsFileEffect,
        identifier: UUID = UUID()
    ) -> Ownership {
        let newOwnership = Ownership(identifier: identifier, effect: effect)
        if ownership == nil {
            ownership = newOwnership
        } else {
            queuedOwnerships.append(newOwnership)
        }
        return newOwnership
    }

    func isActive(_ candidate: Ownership) -> Bool {
        ownership == candidate
    }

    mutating func complete(_ completedOwnership: Ownership) -> Ownership? {
        guard ownership == completedOwnership else { return nil }
        guard !queuedOwnerships.isEmpty else {
            ownership = nil
            return nil
        }
        let nextOwnership = queuedOwnerships.removeFirst()
        ownership = nextOwnership
        return nextOwnership
    }

    mutating func invalidate() {
        ownership = nil
        queuedOwnerships.removeAll()
    }
}

struct KeyboardPowerToolsDecision: Equatable, Sendable {
    let suppress: Bool
    let effect: KeyboardPowerToolsEffect?

    static let pass = KeyboardPowerToolsDecision(suppress: false, effect: nil)

    static func suppressing(_ effect: KeyboardPowerToolsEffect? = nil) -> Self {
        KeyboardPowerToolsDecision(suppress: true, effect: effect)
    }
}

struct KeyboardPowerToolsReducer {
    private struct SafetyPressKey: Hashable {
        let processIdentifier: pid_t
        let keyCode: Int64
    }

    private var pendingSafetyPresses: [SafetyPressKey: TimeInterval] = [:]

    var pendingSafetyPressCount: Int { pendingSafetyPresses.count }

    mutating func reduce(
        input: KeyboardPowerToolsInput,
        preferences: KeyboardPowerToolsPreferences
    ) -> KeyboardPowerToolsDecision {
        if input.modifiers == .command {
            if input.keyCode == KeyboardPowerToolsKeyCode.q, preferences.commandQDoubleTap {
                return safetyDecision(for: input)
            }
            if input.keyCode == KeyboardPowerToolsKeyCode.w, preferences.commandWDoubleTap {
                return safetyDecision(for: input)
            }
        }

        guard input.frontmostBundleIdentifier == "com.apple.finder",
              input.finderCanHandleFileShortcut,
              let effect = Self.finderEffect(
                  keyCode: input.keyCode,
                  modifiers: input.modifiers,
                  preferences: preferences,
                  hasFinderCutSession: input.hasFinderCutSession
              ) else {
            return .pass
        }

        return handledDecision(effect: effect, isAutorepeat: input.isAutorepeat)
    }

    /// The Finder shortcut a key press maps to under `preferences`, before
    /// Finder's focus is known. Nil means the key passes without asking Finder.
    static func finderEffect(
        keyCode: Int64,
        modifiers: KeyboardPowerToolsModifiers,
        preferences: KeyboardPowerToolsPreferences,
        hasFinderCutSession: Bool
    ) -> KeyboardPowerToolsEffect? {
        if keyCode == KeyboardPowerToolsKeyCode.returnKey,
           modifiers.isEmpty,
           preferences.finderReturnOpens {
            return .openFinderSelection
        }

        if keyCode == KeyboardPowerToolsKeyCode.n,
           modifiers == .option,
           preferences.finderOptionNNewFile {
            return .createTextFile
        }

        if keyCode == KeyboardPowerToolsKeyCode.delete,
           modifiers.isEmpty,
           preferences.finderBackspaceMovesToTrash {
            return .moveFinderSelectionToTrash
        }

        if modifiers == .command, preferences.finderCutPaste {
            if keyCode == KeyboardPowerToolsKeyCode.x {
                return .prepareCut
            }
            if keyCode == KeyboardPowerToolsKeyCode.v, hasFinderCutSession {
                return .pasteCut
            }
        }

        return nil
    }

    mutating func reset() {
        pendingSafetyPresses.removeAll()
    }

    private mutating func safetyDecision(
        for input: KeyboardPowerToolsInput
    ) -> KeyboardPowerToolsDecision {
        guard !input.isAutorepeat else { return .suppressing() }

        let safetyKey = SafetyPressKey(
            processIdentifier: input.frontmostProcessIdentifier ?? 0,
            keyCode: input.keyCode
        )
        pendingSafetyPresses = pendingSafetyPresses.filter {
            input.timestamp - $0.value < 2
        }
        let previous = pendingSafetyPresses[safetyKey]
        pendingSafetyPresses[safetyKey] = input.timestamp
        if let previous, input.timestamp - previous < 1.15 {
            pendingSafetyPresses[safetyKey] = nil
            return .pass
        }
        return .suppressing(.beep)
    }

    private func handledDecision(
        effect: KeyboardPowerToolsEffect,
        isAutorepeat: Bool
    ) -> KeyboardPowerToolsDecision {
        .suppressing(isAutorepeat ? nil : effect)
    }
}

// MARK: - Keyboard Power Tools Service

extension KeyboardPowerToolsModifiers {
    static func normalized(from flags: CGEventFlags) -> Self {
        var modifiers: Self = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        return modifiers
    }
}

final class KeyboardPowerToolsService {
    @MainActor
    private static var fileEffectCoordinator = KeyboardPowerToolsFileEffectCoordinator()

    private var reducer = KeyboardPowerToolsReducer()

    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.keyDown.rawValue)
    ) { [weak self] _, event in
        self?.handle(event: event) ?? false
    }

    func start() { tap.start() }

    func stop() {
        tap.stop()
        reducer.reset()
    }

    /// Sees every key press on the Mac. Finder's focus is only queried for a key
    /// that maps to an enabled Finder shortcut.
    private func handle(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = KeyboardPowerToolsModifiers.normalized(from: event.flags)
        let defaults = UserDefaults.standard
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let preferences = KeyboardPowerToolsPreferences(
            commandQDoubleTap: defaults.bool(forKey: PowerToolKeys.commandQDoubleTap),
            commandWDoubleTap: defaults.bool(forKey: PowerToolKeys.commandWDoubleTap),
            finderReturnOpens: defaults.bool(forKey: PowerToolKeys.finderReturnOpens),
            finderCutPaste: defaults.bool(forKey: PowerToolKeys.finderCutPaste),
            finderOptionNNewFile: defaults.bool(forKey: PowerToolKeys.finderOptionNNewFile),
            finderBackspaceMovesToTrash: defaults.bool(forKey: PowerToolKeys.finderBackspaceMovesToTrash)
        )
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let hasFinderCutSession = FinderPowerToolsService.shared.hasCutSession
        let finderCanHandleFileShortcut: Bool
        if let frontmostApp,
           frontmostApp.bundleIdentifier == "com.apple.finder",
           KeyboardPowerToolsReducer.finderEffect(
               keyCode: keyCode,
               modifiers: modifiers,
               preferences: preferences,
               hasFinderCutSession: hasFinderCutSession
           ) != nil {
            finderCanHandleFileShortcut = AXTools.canHandleFinderFileShortcut(
                in: frontmostApp, messagingTimeout: AXTools.eventTapMessagingTimeout
            )
        } else {
            finderCanHandleFileShortcut = false
        }

        let input = KeyboardPowerToolsInput(
            keyCode: keyCode,
            modifiers: modifiers,
            isAutorepeat: isAutorepeat,
            timestamp: ProcessInfo.processInfo.systemUptime,
            frontmostProcessIdentifier: frontmostApp?.processIdentifier,
            frontmostBundleIdentifier: frontmostApp?.bundleIdentifier,
            finderCanHandleFileShortcut: finderCanHandleFileShortcut,
            hasFinderCutSession: hasFinderCutSession
        )
        let decision = reducer.reduce(input: input, preferences: preferences)
        if let effect = decision.effect {
            dispatch(effect)
        }
        return decision.suppress
    }

    static func isFinderTrashShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == KeyboardPowerToolsKeyCode.delete &&
            KeyboardPowerToolsModifiers.normalized(from: flags).isEmpty
    }

    private func dispatch(_ effect: KeyboardPowerToolsEffect) {
        switch effect {
        case .beep:
            Task { @MainActor in
                NSSound.beep()
            }
        case .openFinderSelection:
            Task { @MainActor in
                _ = FinderPowerToolsService.openFinderSelection()
            }
        case .createTextFile:
            dispatch(KeyboardPowerToolsFileEffect.createTextFile)
        case .moveFinderSelectionToTrash:
            dispatch(KeyboardPowerToolsFileEffect.moveFinderSelectionToTrash)
        case .prepareCut:
            dispatch(KeyboardPowerToolsFileEffect.prepareCut)
        case .pasteCut:
            dispatch(KeyboardPowerToolsFileEffect.pasteCut)
        }
    }

    private func dispatch(_ effect: KeyboardPowerToolsFileEffect) {
        DispatchQueue.main.async {
            Self.enqueueFileEffect(effect)
        }
    }

    @MainActor
    private static func enqueueFileEffect(_ effect: KeyboardPowerToolsFileEffect) {
        let ownership = fileEffectCoordinator.enqueue(effect)
        guard fileEffectCoordinator.isActive(ownership) else { return }
        Task { @MainActor in
            await drainFileEffects(startingWith: ownership)
        }
    }

    @MainActor
    private static func drainFileEffects(
        startingWith initialOwnership: KeyboardPowerToolsFileEffectCoordinator.Ownership
    ) async {
        var ownership = initialOwnership
        while true {
            switch ownership.effect {
            case .createTextFile:
                _ = await FinderPowerToolsService().createTextFile(markdown: false)
            case .moveFinderSelectionToTrash:
                _ = await FinderPowerToolsService.moveFinderSelectionToTrash()
            case .prepareCut:
                _ = FinderPowerToolsService.shared.prepareCut()
            case .pasteCut:
                _ = await FinderPowerToolsService.shared.pasteCut()
            }

            guard let nextOwnership = fileEffectCoordinator.complete(ownership) else { return }
            ownership = nextOwnership
        }
    }
}

final class WindowActionService {
    private var activationObserver: NSObjectProtocol?
    private static var dockActivationSelection = DockPreviewActivationSelection()

    func startActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard UserDefaults.standard.bool(forKey: PowerToolKeys.unminimizeOnActivation),
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let selected = Self.dockActivationSelection.take(afterActivating: app.processIdentifier)
            Self.unminimizeWindows(of: app, firstOnly: false)
            if let selected, AXTools.windows(of: app).contains(where: { CFEqual($0, selected.element) }) {
                AXTools.perform(selected.element, kAXRaiseAction)
            }
        }
    }

    func stopActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        Self.dockActivationSelection = DockPreviewActivationSelection()
    }

    @MainActor
    static func activate(_ app: NSRunningApplication, selecting window: DockPreviewWindow) -> Bool {
        // The existing "unminimize on activation" preference may raise several
        // windows in its notification callback. Preserve the user's exact
        // preview selection after that callback, without changing the preference.
        dockActivationSelection = DockPreviewActivationSelection()
        if !app.isActive, UserDefaults.standard.bool(forKey: PowerToolKeys.unminimizeOnActivation) {
            dockActivationSelection.prepare(window, processIdentifier: app.processIdentifier)
        }
        // The preview deliberately leaves Geraldine inactive. A generic app
        // activation request can be ignored in that context; use the existing
        // Accessibility grant for the user's explicit window selection.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focused = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString,
                                                   kCFBooleanTrue) == .success
        let activated = focused || app.activate(options: [])
        if !activated { dockActivationSelection = DockPreviewActivationSelection() }
        return activated
    }

    static func hideAllWindows() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular else { continue }
            app.hide()
        }
    }

    static func isolateFrontWindow() -> PowerToolResult {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return .warning("No frontmost app.")
        }

        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != frontmost.processIdentifier,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular else { continue }
            app.hide()
        }

        guard let focusedWindow = AXTools.focusedWindow() else {
            return .success("Hid other apps.")
        }

        for window in AXTools.windows(of: frontmost) where !AXTools.isSameElement(window, focusedWindow) {
            AXTools.setMinimized(true, for: window)
        }

        return .success("Isolated the front window.")
    }

    static func minimizeWindows(of app: NSRunningApplication? = nil) {
        let apps = app.map { [$0] } ?? NSWorkspace.shared.runningApplications.filter { running in
            running.activationPolicy == .regular && running.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        for app in apps {
            for window in AXTools.windows(of: app) {
                AXTools.setMinimized(true, for: window)
            }
        }
    }

    /// Only consume a custom Dock click when it has a window to operate on.
    /// If there is no visible window, passing the click through preserves the
    /// app's native reopen/new-window behavior.
    /// A window that does not answer in time does not count as visible, so the
    /// Dock click goes to the Dock.
    static func hasVisibleWindow(of app: NSRunningApplication, messagingTimeout: Float? = nil) -> Bool {
        guard !app.isHidden else { return false }
        return AXTools.windows(of: app, messagingTimeout: messagingTimeout).contains {
            AXTools.minimizedState(of: $0) == false
        }
    }

    static func unminimizeWindows(of app: NSRunningApplication, firstOnly: Bool) {
        for window in AXTools.windows(of: app) where AXTools.isMinimized(window) {
            AXTools.setMinimized(false, for: window)
            AXTools.perform(window, kAXRaiseAction)
            if firstOnly { break }
        }
    }

    static func cycleWindows(of app: NSRunningApplication) {
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            KeyboardPoster.post(keyCode: 50, flags: .maskCommand)
        }
    }

    static func openNewWindow(for app: NSRunningApplication) {
        if !app.isActive {
            app.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            KeyboardPoster.post(keyCode: KeyboardPowerToolsKeyCode.n, flags: .maskCommand)
        }
    }

    static func fillOrRestore(window: AXUIElement) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let frame = AXTools.frame(of: window) else { return false }
            return screen.frame.intersects(frame)
        }) ?? NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        if let previous = AXTools.takeRestoreFrame(for: window) {
            AXTools.setFrame(previous, for: window)
        } else if let current = AXTools.frame(of: window) {
            AXTools.storeRestoreFrame(current, for: window)
            AXTools.setFrame(visible, for: window)
        }
    }
}

final class FinderPowerToolsService {
    private struct FileCreationOutput: Sendable {
        let result: PowerToolResult
        let createdURL: URL?
    }

    private struct PasteboardEffectOutput: Sendable {
        let result: PowerToolResult
        let text: String?
    }

    static let shared = FinderPowerToolsService()

    // Written on the main thread, read by the keyboard event-tap thread.
    private let cutItemsLock = NSLock()
    private var lockedCutItems: [URL] = []

    private(set) var cutItems: [URL] {
        get { cutItemsLock.withLock { lockedCutItems } }
        set { cutItemsLock.withLock { lockedCutItems = newValue } }
    }

    var hasCutSession: Bool { !cutItems.isEmpty }

    @MainActor
    func createTextFile(markdown: Bool) async -> PowerToolResult {
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        let ext = markdown ? "md" : "txt"
        let contents = markdown ? "# Untitled\n" : ""
        let output = await PowerToolsEffectRunner.run {
            let url = Self.uniqueFileURL(in: directory, base: "Untitled", ext: ext)
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
                return FileCreationOutput(
                    result: .success("Created \(url.lastPathComponent)."),
                    createdURL: url
                )
            } catch {
                return FileCreationOutput(
                    result: .failure("Could not create file: \(error.localizedDescription)"),
                    createdURL: nil
                )
            }
        }
        if let url = output.createdURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return output.result
    }

    @MainActor
    func copySelectedPaths() -> PowerToolResult {
        let urls = Self.selectedFileURLs()
        guard !urls.isEmpty else { return .warning("No Finder selection.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return .success("Copied \(urls.count) path\(urls.count == 1 ? "" : "s").")
    }

    @MainActor
    func copyChecksumSHA256() async -> PowerToolResult {
        let urls = Self.selectedFileURLs().filter { !$0.hasDirectoryPath }
        guard !urls.isEmpty else { return .warning("Select one or more files in Finder.") }

        let output = await PowerToolsEffectRunner.run {
            var lines: [String] = []
            for url in urls {
                let result = Shell.run("/usr/bin/shasum", ["-a", "256", url.path])
                guard result.status == 0 else {
                    return PasteboardEffectOutput(
                        result: .failure("Checksum failed for \(url.lastPathComponent)."),
                        text: nil
                    )
                }
                lines.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return PasteboardEffectOutput(
                result: .success("Copied SHA-256 for \(urls.count) file\(urls.count == 1 ? "" : "s")."),
                text: lines.joined(separator: "\n")
            )
        }
        if let text = output.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return output.result
    }

    @MainActor
    func openTerminalHere() async -> PowerToolResult {
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        return await PowerToolsEffectRunner.run {
            let status = Shell.run("/usr/bin/open", ["-a", "Terminal", directory.path]).status
            return status == 0
                ? PowerToolResult.success("Opened Terminal in \(directory.lastPathComponent).")
                : PowerToolResult.failure("Could not open Terminal.")
        }
    }

    @MainActor
    func chooseDestinationAndTransfer(copy: Bool) async -> PowerToolResult {
        let urls = Self.selectedFileURLs()
        guard !urls.isEmpty else { return .warning("No Finder selection.") }

        let panel = NSOpenPanel()
        panel.title = copy ? "Copy To" : "Move To"
        panel.prompt = copy ? "Copy" : "Move"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let destination = panel.url else {
            return .warning("Transfer cancelled.")
        }

        return await PowerToolsEffectRunner.run {
            Self.transfer(urls, to: destination, copy: copy)
        }
    }

    @MainActor
    func prepareCut() -> PowerToolResult {
        let urls = Self.selectedFileURLs()
        guard !urls.isEmpty else { return .warning("No Finder selection.") }
        cutItems = urls
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        return .success("Cut \(urls.count) item\(urls.count == 1 ? "" : "s").")
    }

    @MainActor
    func pasteCut() async -> PowerToolResult {
        guard !cutItems.isEmpty else { return .warning("Nothing to paste.") }
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        let items = cutItems
        let message = await PowerToolsEffectRunner.run {
            Self.transfer(items, to: directory, copy: false)
        }
        cutItems.removeAll()
        return message
    }

    @MainActor
    static func openFinderSelection() -> PowerToolResult {
        let script = """
        tell application "Finder"
            set selectedItems to selection
            if selectedItems is {} then return "No Finder selection."
            open selectedItems
        end tell
        """
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        if result.status == 0 {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return output == "No Finder selection." ? .warning(output) : .success("Opened Finder selection.")
        }
        return .failure("Could not open Finder selection: \(shortErrorText(result.output))")
    }

    @MainActor
    static func moveFinderSelectionToTrash() async -> PowerToolResult {
        let urls = selectedFileURLs()
        return await PowerToolsEffectRunner.run {
            moveToTrash(urls)
        }
    }

    static func moveToTrash(
        _ urls: [URL],
        operation: ([ScanItem]) -> TrashService.Result = { TrashService.moveToTrash($0) }
    ) -> PowerToolResult {
        guard !urls.isEmpty else { return .warning("No Finder selection.") }

        let result = operation(urls.map { ScanItem(url: $0, size: 0) })
        if result.failures.isEmpty {
            return .success(
                "Moved \(result.trashed) item\(result.trashed == 1 ? "" : "s") to Trash."
            )
        }

        let summary = "Moved \(result.trashed) of \(urls.count) items to Trash."
        return result.trashed > 0 ? .warning(summary) : .failure(summary)
    }

    @MainActor
    private static func selectedFileURLs() -> [URL] {
        let script = """
        tell application "Finder"
            set selectedItems to selection as alias list
            set output to {}
            repeat with selectedItem in selectedItems
                set end of output to POSIX path of selectedItem
            end repeat
            return output
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        guard let descriptor = appleScript?.executeAndReturnError(&error) else { return [] }
        return decodeSelectedFileURLs(from: descriptor)
    }

    static func decodeSelectedFileURLs(from descriptor: NSAppleEventDescriptor) -> [URL] {
        guard descriptor.descriptorType == typeAEList else { return [] }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).compactMap { index in
            guard let item = descriptor.atIndex(index),
                  [typeChar, typeUnicodeText, typeUTF8Text, typeUTF16ExternalRepresentation].contains(item.descriptorType),
                  let path = item.stringValue else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    @MainActor
    private static func frontFinderDirectory() -> URL? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                set targetFolder to target of front Finder window as alias
            else
                set targetFolder to path to desktop folder
            end if
            return POSIX path of targetFolder
        end tell
        """
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private static func transfer(_ urls: [URL], to destination: URL, copy: Bool) -> PowerToolResult {
        var failures = 0
        var skipped = 0
        let destinationDirectory = destination.standardizedFileURL.resolvingSymlinksInPath()
        for source in urls {
            if !copy,
               source.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == destinationDirectory {
                skipped += 1
                continue
            }

            let target = uniqueFileURL(in: destination,
                                       base: source.deletingPathExtension().lastPathComponent,
                                       ext: source.pathExtension.isEmpty ? nil : source.pathExtension)
            do {
                if copy {
                    try FileManager.default.copyItem(at: source, to: target)
                } else {
                    try FileManager.default.moveItem(at: source, to: target)
                }
            } catch {
                failures += 1
            }
        }
        let verb = copy ? "Copied" : "Moved"
        if failures == 0, skipped == 0 {
            return .success("\(verb) \(urls.count) item\(urls.count == 1 ? "" : "s").")
        }
        let completed = urls.count - failures - skipped
        var parts = ["\(verb) \(completed) item\(completed == 1 ? "" : "s")"]
        if skipped > 0 { parts.append("\(skipped) already there") }
        if failures > 0 { parts.append("\(failures) failed") }
        return failures > 0 ? .warning(parts.joined(separator: "; ") + ".") : .success(parts.joined(separator: "; ") + ".")
    }

    private static func uniqueFileURL(in directory: URL, base: String, ext: String?) -> URL {
        let fm = FileManager.default
        let suffix = ext.map { ".\($0)" } ?? ""
        var candidate = directory.appendingPathComponent("\(base)\(suffix)")
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(index)\(suffix)")
            index += 1
        }
        return candidate
    }
}

private struct PowerToolsTrashRootResolver: TrashRootResolving {
    let root: URL

    func trashRoots() -> [URL] { [root] }
}

final class SystemPowerToolsService {
    @MainActor
    func clearClipboard() -> PowerToolResult {
        NSPasteboard.general.clearContents()
        return .success("Cleared the clipboard.")
    }

    @MainActor
    func sleepDisplays() async -> PowerToolResult {
        await PowerToolsEffectRunner.run {
            let result = Shell.run("/usr/bin/pmset", ["displaysleepnow"])
            return result.status == 0
                ? PowerToolResult.success("Put displays to sleep.")
                : PowerToolResult.failure("Could not sleep displays: \(shortErrorText(result.output))")
        }
    }

    @MainActor
    func ejectAllDisks() async -> PowerToolResult {
        await PowerToolsEffectRunner.run {
            let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                             options: [.skipHiddenVolumes]) ?? []
            var ejected = 0
            var failed = 0
            for url in urls {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.volumeIsEjectable == true || values?.volumeIsRemovable == true else { continue }
                let result = Shell.run("/usr/sbin/diskutil", ["eject", url.path])
                if result.status == 0 { ejected += 1 } else { failed += 1 }
            }
            if ejected == 0 && failed == 0 {
                return PowerToolResult.warning("No ejectable disks found.")
            }
            return failed == 0
                ? PowerToolResult.success("Ejected \(ejected) disk\(ejected == 1 ? "" : "s").")
                : PowerToolResult.warning("Ejected \(ejected); \(failed) failed.")
        }
    }

    @MainActor
    func emptyTrash() async -> PowerToolResult {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return await PowerToolsEffectRunner.run {
            let contents: [URL]
            do {
                contents = try FileManager.default.contentsOfDirectory(at: trash,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [])
            } catch {
                return PowerToolResult.failure("Could not read the Trash: \(error.localizedDescription)")
            }
            guard !contents.isEmpty else {
                return PowerToolResult.warning("Trash is already empty.")
            }

            let result = TrashService.clean(
                contents.map { ScanItem(url: $0, size: 0) },
                rootResolver: PowerToolsTrashRootResolver(root: trash)
            )
            if result.failures.isEmpty {
                return PowerToolResult.success(
                    "Emptied \(result.removed) Trash item\(result.removed == 1 ? "" : "s")."
                )
            }

            let failed = result.failures.count
            let first = result.failures[0]
            let message = "Could not empty \(failed) Trash item\(failed == 1 ? "" : "s")" +
                " (\(first.url.lastPathComponent): \(first.message))."
            if result.removed > 0 {
                return PowerToolResult.warning("Emptied \(result.removed); \(message)")
            }
            return PowerToolResult.failure(message)
        }
    }
}

/// Trimmed command output for user-facing failure messages, never empty.
private func shortErrorText(_ output: String) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown error" : trimmed
}

enum AXTools {
    private struct RestoreFrame {
        let window: AXUIElement
        let frame: CGRect
    }

    private static var restoreFrames: [RestoreFrame] = []
    private static let windowIDFunction: AXUIElementGetWindowFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AXUIElementGetWindowFunction.self)
    }()

    /// The longest an accessibility message sent from an event-tap callback may
    /// wait. macOS holds the user's click or key meanwhile; a query that misses
    /// this budget lets the event through unchanged.
    static let eventTapMessagingTimeout: Float = 0.05

    /// Applies `timeout` to messages sent to `element`; nil keeps the default.
    /// Never pass the system-wide element, which would change the whole process.
    @discardableResult
    static func bounded(_ element: AXUIElement, _ timeout: Float?) -> AXUIElement {
        if let timeout {
            AXUIElementSetMessagingTimeout(element, timeout)
        }
        return element
    }

    /// Returns `element` to the process-wide timeout for work that no longer
    /// holds the user's input.
    static func unbounded(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0)
    }

    /// Hit-tests inside one app so `messagingTimeout` bounds the wait; a timeout
    /// set on the system-wide element would apply to the whole process.
    static func element(at point: CGPoint, inApplication processIdentifier: pid_t,
                        messagingTimeout: Float) -> AXUIElement? {
        let app = bounded(AXUIElementCreateApplication(processIdentifier), messagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return nil
        }
        return bounded(element, messagingTimeout)
    }

    static func runningApplication(for element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    static func windows(of app: NSRunningApplication, messagingTimeout: Float? = nil) -> [AXUIElement] {
        let appElement = bounded(AXUIElementCreateApplication(app.processIdentifier), messagingTimeout)
        return array(appElement, kAXWindowsAttribute).map { bounded($0, messagingTimeout) }
    }

    static func windowID(of window: AXUIElement) -> CGWindowID? {
        guard let windowIDFunction else { return nil }
        var windowID: CGWindowID = 0
        guard windowIDFunction(window, &windowID) == .success else { return nil }
        return windowID
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return value(appElement, kAXFocusedWindowAttribute, as: AXUIElement.self)
    }

    /// The app's own answer to whether it is active. NSWorkspace's frontmost app
    /// only updates when Geraldine's main run loop runs, so it can be stale on
    /// the event-tap thread. False when the app does not answer.
    static func reportsFrontmost(_ app: NSRunningApplication, messagingTimeout: Float? = nil) -> Bool {
        let appElement = bounded(AXUIElementCreateApplication(app.processIdentifier), messagingTimeout)
        return answer(appElement, kAXFrontmostAttribute).bool == true
    }

    /// True only when Finder answers that it is active and that nothing is
    /// focused or focus is outside a text field. An unanswered query lets the
    /// key through: a slow Finder must never turn Delete during a rename, or in
    /// the app the user just switched to, into Move to Trash.
    static func canHandleFinderFileShortcut(in app: NSRunningApplication, messagingTimeout: Float? = nil) -> Bool {
        let appElement = bounded(AXUIElementCreateApplication(app.processIdentifier), messagingTimeout)
        guard answer(appElement, kAXFrontmostAttribute).bool == true else { return false }
        let focused = answer(appElement, kAXFocusedUIElementAttribute)
        if focused.isUnanswered { return false }
        guard let focusedElement = focused.element else { return true }
        return isTextEntryElement(focusedElement, messagingTimeout: messagingTimeout) == false
    }

    static func window(containing element: AXUIElement, messagingTimeout: Float? = nil) -> AXUIElement? {
        if let window = value(element, kAXWindowAttribute, as: AXUIElement.self) {
            return window
        }

        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let parent = current.flatMap({ value($0, kAXParentAttribute, as: AXUIElement.self) }) else { break }
            bounded(parent, messagingTimeout)
            if string(parent, kAXRoleAttribute) == kAXWindowRole {
                return parent
            }
            current = parent
        }
        return nil
    }

    static func missionControlGroup(messagingTimeout: Float? = nil) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let dockElement = bounded(AXUIElementCreateApplication(dock.processIdentifier), messagingTimeout)
        return array(dockElement, kAXChildrenAttribute).first { child in
            string(bounded(child, messagingTimeout), "AXIdentifier") == "mc"
        }
    }

    static func closeButton(of window: AXUIElement) -> AXUIElement? {
        value(window, kAXCloseButtonAttribute, as: AXUIElement.self)
    }

    @discardableResult
    static func close(window: AXUIElement) -> Bool {
        if let closeButton = closeButton(of: window),
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success {
            return true
        }
        return AXUIElementPerformAction(window, "AXClose" as CFString) == .success
    }

    static func setMinimized(_ minimized: Bool, for window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        value(window, kAXMinimizedAttribute, as: Bool.self) ?? false
    }

    /// Nil when the window did not answer; one without the attribute is not
    /// minimized.
    static func minimizedState(of window: AXUIElement) -> Bool? {
        let minimized = answer(window, kAXMinimizedAttribute)
        if minimized.isUnanswered { return nil }
        return minimized.bool ?? false
    }

    static func perform(_ element: AXUIElement, _ action: String) {
        AXUIElementPerformAction(element, action as CFString)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = value(window, kAXPositionAttribute, as: AXValue.self),
              let sizeValue = value(window, kAXSizeAttribute, as: AXValue.self) else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func setFrame(_ frame: CGRect, for window: AXUIElement) {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin),
              let axSize = AXValueCreate(.cgSize, &size) else {
            return
        }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axSize)
    }

    static func takeRestoreFrame(for window: AXUIElement) -> CGRect? {
        guard let index = restoreFrames.firstIndex(where: { CFEqual($0.window, window) }) else {
            return nil
        }
        return restoreFrames.remove(at: index).frame
    }

    static func storeRestoreFrame(_ frame: CGRect, for window: AXUIElement) {
        restoreFrames.removeAll { CFEqual($0.window, window) }
        restoreFrames.append(RestoreFrame(window: window, frame: frame))
    }

    static func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute, as: String.self)
    }

    static func parent(of element: AXUIElement) -> AXUIElement? {
        value(element, kAXParentAttribute, as: AXUIElement.self)
    }

    static func fileURL(of element: AXUIElement) -> URL? {
        let url = value(element, kAXURLAttribute, as: URL.self) ??
            string(element, kAXURLAttribute).flatMap(URL.init(string:))
        return url?.isFileURL == true ? url : nil
    }

    /// Nil when an element did not answer, so callers never guess that focus is
    /// outside a text field.
    private static func isTextEntryElement(_ element: AXUIElement, messagingTimeout: Float?) -> Bool? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let candidate = current else { break }
            bounded(candidate, messagingTimeout)
            let role = answer(candidate, kAXRoleAttribute)
            let subrole = answer(candidate, kAXSubroleAttribute)
            guard !role.isUnanswered, !subrole.isUnanswered else { return nil }
            if role.string == kAXTextFieldRole ||
                role.string == kAXTextAreaRole ||
                role.string == kAXComboBoxRole ||
                subrole.string == "AXSearchField" ||
                subrole.string == "AXSecureTextField" {
                return true
            }
            let parent = answer(candidate, kAXParentAttribute)
            guard !parent.isUnanswered else { return nil }
            current = parent.element
        }
        return false
    }

    private static func array(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute, as: [AXUIElement].self) ?? []
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    /// An attribute read that keeps "the element has no such value" apart from a
    /// message that failed or timed out, which must not be taken as a fact.
    private enum Answer {
        case value(CFTypeRef)
        case missing
        case unanswered

        var isUnanswered: Bool {
            if case .unanswered = self { return true }
            return false
        }

        var string: String? {
            guard case .value(let value) = self else { return nil }
            return value as? String
        }

        var bool: Bool? {
            guard case .value(let value) = self else { return nil }
            return value as? Bool
        }

        var element: AXUIElement? {
            guard case .value(let value) = self, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private static func answer(_ element: AXUIElement, _ attribute: String) -> Answer {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success:
            return value.map(Answer.value) ?? .missing
        case .noValue, .attributeUnsupported:
            return .missing
        default:
            return .unanswered
        }
    }
}
