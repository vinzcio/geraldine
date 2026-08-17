import SwiftUI
import AppKit
import Combine

/// How the app presents itself. Switchable at runtime from Settings.
enum AppShape: String, CaseIterable, Identifiable {
    case menuBarAndWindow
    case menuBarOnly
    case windowOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBarAndWindow: return "Menu Bar And Dock"
        case .menuBarOnly:      return "Menu Bar Only"
        case .windowOnly:       return "Dock Only"
        }
    }

    var detail: String {
        switch self {
        case .menuBarAndWindow: return "Shows the menu bar monitor and keeps Geraldine in the Dock."
        case .menuBarOnly:      return "Shows the menu bar monitor. The full window can open without adding a Dock icon."
        case .windowOnly:       return "Shows Geraldine in the Dock without a menu bar item."
        }
    }

    var systemImage: String {
        switch self {
        case .menuBarAndWindow: return "menubar.dock.rectangle"
        case .menuBarOnly:      return "menubar.rectangle"
        case .windowOnly:       return "macwindow"
        }
    }

    var showsMenuBar: Bool { self != .windowOnly }
    var showsDock: Bool { self != .menuBarOnly }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let monitor = SystemMonitor()
    let network = NetworkMonitor()
    let devices = DeviceMonitor()
    let layout = WidgetLayoutStore()
    let keepAwake = KeepAwakeController()
    let powerTools = PowerToolsController()
    let clipboard = ClipboardHistoryController()
    let calendar = CalendarSettingsStore()
    let hardware = HardwareInfo.current

    /// Plain storage, not @Published: both only ever change together with
    /// `selection`, whose own publish triggers the re-render that reads them.
    /// Publishing again from `didSet` would re-enter SwiftUI mid-update while
    /// the sidebar List is applying its selection, which makes the highlight
    /// stutter or revert.
    private(set) var previousSelection: Module = .dashboard
    private(set) var navigationDirection = 1
    @Published var selection: Module? = .dashboard {
        didSet {
            guard let newSelection = selection,
                  newSelection != oldValue else { return }
            let oldSelection = oldValue ?? previousSelection
            previousSelection = oldSelection
            navigationDirection = newSelection.navigationIndex >= oldSelection.navigationIndex ? 1 : -1
        }
    }
    @Published private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess()
    @Published private(set) var hasAccessibility = Permissions.hasAccessibilityAccess()
    @Published private(set) var mainWindowVisible = true
    /// The window is open on screen (regardless of occlusion). While false the
    /// shell unmounts its content so a hidden window stops re-evaluating live
    /// metrics every tick.
    @Published private(set) var mainWindowPresented = true
    @Published private(set) var menuBarPopoverVisible = false

    @Published var appShape: AppShape {
        didSet {
            UserDefaults.standard.set(appShape.rawValue, forKey: "appShape")
            applyActivationPolicy()
        }
    }

    /// The main window, captured once it exists (see WindowAccessor).
    weak var mainWindow: NSWindow?
    private var windowVisibilityObservers: [NSObjectProtocol] = []
    private var windowVisibilityCancellable: AnyCancellable?

    private init() {
        let raw = UserDefaults.standard.string(forKey: "appShape") ?? AppShape.menuBarAndWindow.rawValue
        appShape = AppShape(rawValue: raw) ?? .menuBarAndWindow
        mainWindowVisible = appShape != .menuBarOnly
        mainWindowPresented = appShape != .menuBarOnly
    }

    // MARK: - Presentation

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(appShape.showsDock ? .regular : .accessory)
    }

    func bind(window: NSWindow) {
        guard mainWindow !== window else { return }
        let isInitialBind = mainWindow == nil
        removeWindowVisibilityObservers()
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        observeVisibility(of: window)
        if isInitialBind { hideInitialWindowIfNeeded() }
        applyActivationPolicy()
        refreshMainWindowVisibility()
    }

    func hideInitialWindowIfNeeded() {
        guard let window = mainWindow else { return }
        if appShape == .menuBarOnly {
            window.orderOut(nil)
            refreshMainWindowVisibility()
        }
    }

    func showMainWindow() {
        applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        refreshMainWindowVisibility()
    }

    /// Navigate to a module and bring the window forward.
    func open(_ module: Module) {
        selection = module
        showMainWindow()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    func refreshAccessibility() {
        hasAccessibility = Permissions.hasAccessibilityAccess()
    }

    /// Re-check every permission the Permissions page shows. Cheap, so it's safe to call
    /// on appear and whenever the app comes back to the foreground.
    func refreshPermissions() {
        refreshFullDiskAccess()
        refreshAccessibility()
    }

    func setMenuBarPopoverVisible(_ isVisible: Bool) {
        menuBarPopoverVisible = isVisible
    }

    private func observeVisibility(of window: NSWindow) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ]
        windowVisibilityObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMainWindowVisibility() }
            }
        }
        windowVisibilityCancellable = window.publisher(for: \.isVisible, options: [.initial, .new])
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshMainWindowVisibility() }
            }
    }

    private func removeWindowVisibilityObservers() {
        for observer in windowVisibilityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowVisibilityObservers.removeAll()
        windowVisibilityCancellable?.cancel()
        windowVisibilityCancellable = nil
    }

    private func refreshMainWindowVisibility() {
        guard let mainWindow else {
            mainWindowVisible = false
            mainWindowPresented = false
            return
        }
        // Presented = the window exists on screen (open, not miniaturized),
        // regardless of whether other apps currently cover it. Occlusion only
        // pauses decorative animation; presentation decides whether the shell
        // content is mounted at all, so it must not flap with window layering.
        let presented = mainWindow.isVisible && !mainWindow.isMiniaturized
        if mainWindowPresented != presented { mainWindowPresented = presented }
        mainWindowVisible = presented && mainWindow.occlusionState.contains(.visible)
    }
}
