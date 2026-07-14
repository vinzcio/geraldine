import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var keyboardTransportHUD: KeyboardTransportHUDCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.applyActivationPolicy()
        state.refreshFullDiskAccess()
        state.monitor.start()
        state.network.start()
        state.devices.start()
        state.powerTools.start()
        menuBarController = MenuBarController(state: state)
        keyboardTransportHUD = KeyboardTransportHUDCoordinator()
        keyboardTransportHUD?.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if AppState.shared.keepAwake.handle(url: url) {
                return
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.refreshPermissions()
        AppState.shared.network.refreshNameAccess()
        AppState.shared.keepAwake.refreshIdleActivityAccess()
        AppState.shared.powerTools.refreshAccessibility()
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

    func applicationWillTerminate(_ notification: Notification) {
        keyboardTransportHUD?.stop()
        AppState.shared.keepAwake.shutdown()
        AppState.shared.powerTools.stop()
    }
}
