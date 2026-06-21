import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.applyActivationPolicy()
        state.refreshFullDiskAccess()
        state.monitor.start()
        state.network.start()
        state.devices.start()
        menuBarController = MenuBarController(state: state)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshFullDiskAccess()
    }

    /// Clicking the Dock icon (or re-opening) brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.showMainWindow()
        AppState.shared.refreshFullDiskAccess()
        return true
    }

    /// Closing the full window hides it; Quit is the explicit way to end Geraldine.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
