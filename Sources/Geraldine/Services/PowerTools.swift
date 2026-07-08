import AppKit
import ApplicationServices
import CoreGraphics
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

enum PowerToolResultStatus {
    case success
    case warning
    case failure
}

struct PowerToolResult {
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

private enum PowerToolKeys {
    static let dockActionsEnabled = "powerTools.dock.actionsEnabled"
    static let activeDockClickBehavior = "powerTools.dock.activeClickBehavior"
    static let middleClickBehavior = "powerTools.dock.middleClickBehavior"
    static let shiftClickNewWindow = "powerTools.dock.shiftClickNewWindow"
    static let unminimizeOnActivation = "powerTools.window.unminimizeOnActivation"
    static let greenButtonFillsWindow = "powerTools.window.greenButtonFillsWindow"
    static let yellowButtonHidesApp = "powerTools.window.yellowButtonHidesApp"
    static let commandQDoubleTap = "powerTools.keyboard.commandQDoubleTap"
    static let commandWDoubleTap = "powerTools.keyboard.commandWDoubleTap"
    static let finderReturnOpens = "powerTools.finder.returnOpens"
    static let finderCutPaste = "powerTools.finder.cutPaste"
    static let finderOptionNNewFile = "powerTools.finder.optionNNewFile"
}

@MainActor
final class PowerToolsController: ObservableObject {
    @Published private(set) var accessibilityTrusted = Permissions.hasAccessibilityAccess()
    @Published var lastResult: PowerToolResult?

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

    let finder = FinderPowerToolsService()
    let system = SystemPowerToolsService()

    private let defaults: UserDefaults
    private let dockService = DockInteractionService()
    private let trafficLightService = TrafficLightButtonService()
    private let keyboardService = KeyboardPowerToolsService()
    private let windowService = WindowActionService()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dockActionsEnabled = defaults.bool(forKey: PowerToolKeys.dockActionsEnabled)
        let activeRaw = defaults.string(forKey: PowerToolKeys.activeDockClickBehavior) ?? DockActiveClickBehavior.system.rawValue
        activeDockClickBehavior = DockActiveClickBehavior(rawValue: activeRaw) ?? .system
        let middleRaw = defaults.string(forKey: PowerToolKeys.middleClickBehavior) ?? DockMiddleClickBehavior.system.rawValue
        middleClickBehavior = DockMiddleClickBehavior(rawValue: middleRaw) ?? .system
        shiftClickNewWindow = defaults.bool(forKey: PowerToolKeys.shiftClickNewWindow)
        unminimizeOnActivation = defaults.bool(forKey: PowerToolKeys.unminimizeOnActivation)
        greenButtonFillsWindow = defaults.bool(forKey: PowerToolKeys.greenButtonFillsWindow)
        yellowButtonHidesApp = defaults.bool(forKey: PowerToolKeys.yellowButtonHidesApp)
        commandQDoubleTap = defaults.bool(forKey: PowerToolKeys.commandQDoubleTap)
        commandWDoubleTap = defaults.bool(forKey: PowerToolKeys.commandWDoubleTap)
        finderReturnOpens = defaults.bool(forKey: PowerToolKeys.finderReturnOpens)
        finderCutPaste = defaults.bool(forKey: PowerToolKeys.finderCutPaste)
        finderOptionNNewFile = defaults.bool(forKey: PowerToolKeys.finderOptionNNewFile)
    }

    func start() {
        refreshAccessibility()
        applyHooks()
    }

    func stop() {
        dockService.stop()
        trafficLightService.stop()
        keyboardService.stop()
        windowService.stopActivationObserver()
    }

    func refreshAccessibility(prompt: Bool = false) {
        accessibilityTrusted = prompt ? Permissions.requestAccessibilityAccess() : Permissions.hasAccessibilityAccess()
        applyHooks()
    }

    func hideAllWindows() {
        WindowActionService.hideAllWindows()
        lastResult = .success("Hid visible app windows.")
    }

    func isolateFrontWindow() {
        lastResult = WindowActionService.isolateFrontWindow()
    }

    func minimizeAllWindows() {
        WindowActionService.minimizeWindows()
        lastResult = .success("Minimized visible windows.")
    }

    func newFinderTextFile(markdown: Bool = false) {
        lastResult = finder.createTextFile(markdown: markdown)
    }

    func copyFinderPaths() {
        lastResult = finder.copySelectedPaths()
    }

    func copyFinderSHA256() {
        lastResult = finder.copyChecksumSHA256()
    }

    func openFinderTerminal() {
        lastResult = finder.openTerminalHere()
    }

    func copyFinderSelectionToFolder() {
        lastResult = finder.chooseDestinationAndTransfer(copy: true)
    }

    func moveFinderSelectionToFolder() {
        lastResult = finder.chooseDestinationAndTransfer(copy: false)
    }

    func clearClipboard() {
        lastResult = system.clearClipboard()
    }

    func sleepDisplays() {
        lastResult = system.sleepDisplays()
    }

    func ejectDisks() {
        lastResult = system.ejectAllDisks()
    }

    func emptyTrash() {
        lastResult = system.emptyTrash()
    }

    private func applyHooks() {
        guard accessibilityTrusted else {
            stop()
            return
        }

        let needsDockTap = dockActionsEnabled &&
            (activeDockClickBehavior != .system || middleClickBehavior != .system || shiftClickNewWindow)
        needsDockTap ? dockService.start() : dockService.stop()

        let needsTrafficTap = greenButtonFillsWindow || yellowButtonHidesApp
        needsTrafficTap ? trafficLightService.start() : trafficLightService.stop()

        let needsKeyboardTap = commandQDoubleTap || commandWDoubleTap || finderReturnOpens || finderCutPaste || finderOptionNNewFile
        needsKeyboardTap ? keyboardService.start() : keyboardService.stop()

        unminimizeOnActivation ? windowService.startActivationObserver() : windowService.stopActivationObserver()
    }
}

/// Shared CGEvent-tap plumbing for the Power Tools services: creates the session
/// tap, keeps its source on the main run loop, re-enables the tap when macOS
/// disables it after a timeout, and tears everything down on `stop()`. The
/// handler returns true to swallow the event, false to pass it through.
final class EventTapService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let mask: CGEventMask
    private let handler: (CGEventType, CGEvent) -> Bool

    init(mask: CGEventMask, handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.mask = mask
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = service.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        return service.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
}

final class DockInteractionService {
    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.leftMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
    ) { [weak self] type, event in
        self?.handle(type: type, event: event) ?? false
    }

    func start() { tap.start() }
    func stop() { tap.stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: PowerToolKeys.dockActionsEnabled),
              let target = DockTarget.target(at: event.location) else {
            return false
        }

        if type == .otherMouseDown, event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
            let raw = defaults.string(forKey: PowerToolKeys.middleClickBehavior) ?? DockMiddleClickBehavior.system.rawValue
            let behavior = DockMiddleClickBehavior(rawValue: raw) ?? .system
            guard behavior != .system else { return false }
            DispatchQueue.main.async {
                Self.performMiddleClick(behavior, app: target.app)
            }
            return true
        }

        guard type == .leftMouseDown else { return false }

        if event.flags.contains(.maskShift), defaults.bool(forKey: PowerToolKeys.shiftClickNewWindow) {
            DispatchQueue.main.async {
                WindowActionService.openNewWindow(for: target.app)
            }
            return true
        }

        let raw = defaults.string(forKey: PowerToolKeys.activeDockClickBehavior) ?? DockActiveClickBehavior.system.rawValue
        let behavior = DockActiveClickBehavior(rawValue: raw) ?? .system
        guard behavior != .system,
              target.app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }

        DispatchQueue.main.async {
            Self.performActiveClick(behavior, app: target.app)
        }
        return true
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
        guard let element = AXTools.element(at: point),
              let app = AXTools.runningApplication(for: element),
              app.bundleIdentifier == "com.apple.dock" else {
            return nil
        }

        let title = AXTools.string(element, kAXTitleAttribute) ??
            AXTools.string(element, kAXDescriptionAttribute) ??
            AXTools.string(element, kAXHelpAttribute)
        guard let title, !title.isEmpty else { return nil }

        if title == "Finder",
           let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            return DockTarget(app: finder)
        }

        let cleanedTitle = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let target = NSWorkspace.shared.runningApplications.first(where: { running in
            guard running.activationPolicy == .regular || running.bundleIdentifier == "com.apple.finder" else { return false }
            if running.localizedName == cleanedTitle { return true }
            if running.bundleURL?.deletingPathExtension().lastPathComponent == cleanedTitle { return true }
            return false
        }) else {
            return nil
        }

        return DockTarget(app: target)
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

    private func handle(event: CGEvent) -> Bool {
        guard !event.flags.contains(.maskAlternate),
              let element = AXTools.element(at: event.location),
              let subrole = AXTools.string(element, kAXSubroleAttribute) else {
            return false
        }

        let defaults = UserDefaults.standard

        if subrole == "AXZoomButton", defaults.bool(forKey: PowerToolKeys.greenButtonFillsWindow),
           let window = AXTools.window(containing: element) {
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

final class KeyboardPowerToolsService {
    private struct SafetyPressKey: Hashable {
        let processIdentifier: pid_t
        let keyCode: Int64
    }

    private var lastSafetyPress: [SafetyPressKey: Date] = [:]

    private lazy var tap = EventTapService(
        mask: CGEventMask(1 << CGEventType.keyDown.rawValue)
    ) { [weak self] _, event in
        self?.handle(event: event) ?? false
    }

    func start() { tap.start() }

    func stop() {
        tap.stop()
        lastSafetyPress.removeAll()
    }

    private func handle(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let defaults = UserDefaults.standard
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if flags.contains(.maskCommand), !flags.contains(.maskShift), !flags.contains(.maskControl), !flags.contains(.maskAlternate) {
            if keyCode == KeyCode.q, defaults.bool(forKey: PowerToolKeys.commandQDoubleTap) {
                if isAutorepeat { return true }
                return blockFirstTap(keyCode: keyCode, app: NSWorkspace.shared.frontmostApplication)
            }
            if keyCode == KeyCode.w, defaults.bool(forKey: PowerToolKeys.commandWDoubleTap) {
                if isAutorepeat { return true }
                return blockFirstTap(keyCode: keyCode, app: NSWorkspace.shared.frontmostApplication)
            }
        }

        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier == "com.apple.finder",
              AXTools.canHandleFinderFileShortcut(in: frontmostApp) else {
            return false
        }

        if keyCode == KeyCode.returnKey,
           flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty,
           defaults.bool(forKey: PowerToolKeys.finderReturnOpens) {
            if isAutorepeat { return true }
            DispatchQueue.main.async {
                _ = FinderPowerToolsService.openFinderSelection()
            }
            return true
        }

        if flags.contains(.maskAlternate),
           !flags.contains(.maskCommand),
           !flags.contains(.maskShift),
           !flags.contains(.maskControl),
           keyCode == KeyCode.n,
           defaults.bool(forKey: PowerToolKeys.finderOptionNNewFile) {
            if isAutorepeat { return true }
            DispatchQueue.main.async {
                _ = FinderPowerToolsService().createTextFile(markdown: false)
            }
            return true
        }

        if flags.contains(.maskCommand),
           !flags.contains(.maskShift),
           !flags.contains(.maskControl),
           !flags.contains(.maskAlternate),
           defaults.bool(forKey: PowerToolKeys.finderCutPaste) {
            if keyCode == KeyCode.x {
                if isAutorepeat { return true }
                DispatchQueue.main.async {
                    _ = FinderPowerToolsService.shared.prepareCut()
                }
                return true
            }
            if keyCode == KeyCode.v, FinderPowerToolsService.shared.hasCutSession {
                if isAutorepeat { return true }
                DispatchQueue.main.async {
                    _ = FinderPowerToolsService.shared.pasteCut()
                }
                return true
            }
        }

        return false
    }

    private func blockFirstTap(keyCode: Int64, app: NSRunningApplication?) -> Bool {
        let appPID = app?.processIdentifier ?? 0
        let safetyKey = SafetyPressKey(processIdentifier: appPID, keyCode: keyCode)
        let now = Date()
        lastSafetyPress = lastSafetyPress.filter { now.timeIntervalSince($0.value) < 2 }
        let previous = lastSafetyPress[safetyKey]
        lastSafetyPress[safetyKey] = now
        if let previous, now.timeIntervalSince(previous) < 1.15 {
            lastSafetyPress[safetyKey] = nil
            return false
        }
        DispatchQueue.main.async {
            NSSound.beep()
        }
        return true
    }
}

private enum KeyCode {
    static let q: Int64 = 12
    static let w: Int64 = 13
    static let x: Int64 = 7
    static let v: Int64 = 9
    static let n: Int64 = 45
    static let returnKey: Int64 = 36
}

final class WindowActionService {
    private var activationObserver: NSObjectProtocol?

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
            Self.unminimizeWindows(of: app, firstOnly: false)
        }
    }

    func stopActivationObserver() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
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
            KeyboardPoster.post(keyCode: KeyCode.n, flags: .maskCommand)
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
    static let shared = FinderPowerToolsService()
    private(set) var cutItems: [URL] = []

    var hasCutSession: Bool { !cutItems.isEmpty }

    func createTextFile(markdown: Bool) -> PowerToolResult {
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        let ext = markdown ? "md" : "txt"
        let url = Self.uniqueFileURL(in: directory, base: "Untitled", ext: ext)
        let contents = markdown ? "# Untitled\n" : ""
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .success("Created \(url.lastPathComponent).")
        } catch {
            return .failure("Could not create file: \(error.localizedDescription)")
        }
    }

    func copySelectedPaths() -> PowerToolResult {
        let urls = Self.selectedFileURLs()
        guard !urls.isEmpty else { return .warning("No Finder selection.") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return .success("Copied \(urls.count) path\(urls.count == 1 ? "" : "s").")
    }

    func copyChecksumSHA256() -> PowerToolResult {
        let urls = Self.selectedFileURLs().filter { !$0.hasDirectoryPath }
        guard !urls.isEmpty else { return .warning("Select one or more files in Finder.") }

        var lines: [String] = []
        for url in urls {
            let result = Shell.run("/usr/bin/shasum", ["-a", "256", url.path])
            guard result.status == 0 else {
                return .failure("Checksum failed for \(url.lastPathComponent).")
            }
            lines.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        return .success("Copied SHA-256 for \(urls.count) file\(urls.count == 1 ? "" : "s").")
    }

    func openTerminalHere() -> PowerToolResult {
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        let status = Shell.run("/usr/bin/open", ["-a", "Terminal", directory.path]).status
        return status == 0 ? .success("Opened Terminal in \(directory.lastPathComponent).") : .failure("Could not open Terminal.")
    }

    func chooseDestinationAndTransfer(copy: Bool) -> PowerToolResult {
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

        return Self.transfer(urls, to: destination, copy: copy)
    }

    func prepareCut() -> PowerToolResult {
        let urls = Self.selectedFileURLs()
        guard !urls.isEmpty else { return .warning("No Finder selection.") }
        cutItems = urls
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
        return .success("Cut \(urls.count) item\(urls.count == 1 ? "" : "s").")
    }

    func pasteCut() -> PowerToolResult {
        guard !cutItems.isEmpty else { return .warning("Nothing to paste.") }
        guard let directory = Self.frontFinderDirectory() else {
            return .failure("Could not find the current Finder folder.")
        }
        let message = Self.transfer(cutItems, to: directory, copy: false)
        cutItems.removeAll()
        return message
    }

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

    private static func selectedFileURLs() -> [URL] {
        let script = """
        tell application "Finder"
            set selectedItems to selection as alias list
            set output to ""
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of selectedItem & linefeed
            end repeat
            return output
        end tell
        """
        let result = Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }

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

final class SystemPowerToolsService {
    func clearClipboard() -> PowerToolResult {
        NSPasteboard.general.clearContents()
        return .success("Cleared the clipboard.")
    }

    func sleepDisplays() -> PowerToolResult {
        let result = Shell.run("/usr/bin/pmset", ["displaysleepnow"])
        return result.status == 0 ? .success("Put displays to sleep.") : .failure("Could not sleep displays: \(shortErrorText(result.output))")
    }

    func ejectAllDisks() -> PowerToolResult {
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
        if ejected == 0 && failed == 0 { return .warning("No ejectable disks found.") }
        return failed == 0 ? .success("Ejected \(ejected) disk\(ejected == 1 ? "" : "s").") : .warning("Ejected \(ejected); \(failed) failed.")
    }

    func emptyTrash() -> PowerToolResult {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: trash,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [])
        } catch {
            return .failure("Could not read the Trash: \(error.localizedDescription)")
        }
        guard !contents.isEmpty else { return .warning("Trash is already empty.") }

        var removed = 0
        var failures: [(name: String, error: String)] = []
        for url in contents {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                if Self.destroyWithWorkspace(url) {
                    removed += 1
                } else {
                    failures.append((url.lastPathComponent, error.localizedDescription))
                }
            }
        }
        if failures.isEmpty {
            return .success("Emptied \(removed) Trash item\(removed == 1 ? "" : "s").")
        }

        let failed = failures.count
        let first = failures[0]
        let message = "Could not empty \(failed) Trash item\(failed == 1 ? "" : "s")" +
            " (\(first.name): \(first.error))."
        if removed > 0 {
            return .warning("Emptied \(removed); \(message)")
        }
        return .failure(message)
    }

    private static func destroyWithWorkspace(_ url: URL) -> Bool {
        var tag = 0
        let parent = url.deletingLastPathComponent()
        return NSWorkspace.shared.performFileOperation(.destroyOperation,
                                                       source: parent.path,
                                                       destination: "",
                                                       files: [url.lastPathComponent],
                                                       tag: &tag)
    }
}

/// Trimmed command output for user-facing failure messages, never empty.
private func shortErrorText(_ output: String) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "unknown error" : trimmed
}

private enum KeyboardPoster {
    static func post(keyCode: Int64, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private enum AXTools {
    private struct RestoreFrame {
        let window: AXUIElement
        let frame: CGRect
    }

    private static var restoreFrames: [RestoreFrame] = []

    static func element(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success else {
            return nil
        }
        return element
    }

    static func runningApplication(for element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return array(appElement, kAXWindowsAttribute)
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return value(appElement, kAXFocusedWindowAttribute, as: AXUIElement.self)
    }

    static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return value(appElement, kAXFocusedUIElementAttribute, as: AXUIElement.self)
    }

    static func canHandleFinderFileShortcut(in app: NSRunningApplication) -> Bool {
        guard let focusedElement = focusedElement(of: app) else {
            return true
        }
        return !isTextEntryElement(focusedElement)
    }

    static func window(containing element: AXUIElement) -> AXUIElement? {
        if let window = value(element, kAXWindowAttribute, as: AXUIElement.self) {
            return window
        }

        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let parent = current.flatMap({ value($0, kAXParentAttribute, as: AXUIElement.self) }) else { break }
            if string(parent, kAXRoleAttribute) == kAXWindowRole {
                return parent
            }
            current = parent
        }
        return nil
    }

    static func setMinimized(_ minimized: Bool, for window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean)
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        value(window, kAXMinimizedAttribute, as: Bool.self) ?? false
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

    private static func isTextEntryElement(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let candidate = current else { break }
            let role = string(candidate, kAXRoleAttribute)
            let subrole = string(candidate, kAXSubroleAttribute)
            if role == kAXTextFieldRole ||
                role == kAXTextAreaRole ||
                role == kAXComboBoxRole ||
                subrole == "AXSearchField" ||
                subrole == "AXSecureTextField" {
                return true
            }
            current = value(candidate, kAXParentAttribute, as: AXUIElement.self)
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
}
