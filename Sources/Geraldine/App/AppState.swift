import SwiftUI
import AppKit

/// How the app presents itself. Switchable at runtime from Settings.
enum AppShape: String, CaseIterable, Identifiable {
    case menuBarAndWindow
    case menuBarOnly
    case windowOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .menuBarAndWindow: return "Menu Bar and Dock"
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

    @Published var selection: Module? = .dashboard
    @Published private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess()

    @Published var appShape: AppShape {
        didSet {
            UserDefaults.standard.set(appShape.rawValue, forKey: "appShape")
            applyActivationPolicy()
        }
    }

    /// The main window, captured once it exists (see WindowAccessor).
    weak var mainWindow: NSWindow?

    private init() {
        let raw = UserDefaults.standard.string(forKey: "appShape") ?? AppShape.menuBarAndWindow.rawValue
        appShape = AppShape(rawValue: raw) ?? .menuBarAndWindow
    }

    // MARK: - Presentation

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(appShape.showsDock ? .regular : .accessory)
    }

    func bind(window: NSWindow) {
        guard mainWindow !== window else { return }
        let isInitialBind = mainWindow == nil
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        if isInitialBind { hideInitialWindowIfNeeded() }
        applyActivationPolicy()
    }

    func hideInitialWindowIfNeeded() {
        guard let window = mainWindow else { return }
        if appShape == .menuBarOnly {
            window.orderOut(nil)
        }
    }

    func showMainWindow() {
        applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Navigate to a module and bring the window forward.
    func open(_ module: Module) {
        selection = module
        showMainWindow()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }
}
