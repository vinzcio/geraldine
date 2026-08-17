import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var clipboardPicker: ClipboardPickerCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared
        state.applyActivationPolicy()
        state.refreshFullDiskAccess()
        state.monitor.start()
        state.network.start()
        state.devices.start()
        state.powerTools.start()
        state.clipboard.start()
        menuBarController = MenuBarController(state: state)
        clipboardPicker = ClipboardPickerCoordinator(clipboard: state.clipboard)
        clipboardPicker?.start()

        #if DEBUG
        // Dev helper: `--appearance dark|light` forces the app's appearance for
        // design QA without flipping the whole system's setting.
        if let index = CommandLine.arguments.firstIndex(of: "--appearance"),
           index + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[index + 1] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: break
            }
        }

        // Dev helper: `--open-module <rawValue>` opens the full window straight to a module,
        // so a specific page can be inspected/screenshotted without clicking the sidebar.
        if let index = CommandLine.arguments.firstIndex(of: "--open-module"),
           index + 1 < CommandLine.arguments.count,
           let module = Module(rawValue: CommandLine.arguments[index + 1]) {
            DispatchQueue.main.async {
                state.selection = module
                state.showMainWindow()
                // Widen the window so wide-layout alignment can be inspected/screenshotted.
                if CommandLine.arguments.contains("--wide") {
                    state.mainWindow?.setContentSize(NSSize(width: 1280, height: 820))
                    state.mainWindow?.center()
                }
            }
        }

        // Dev helper: `--open-picker` shows the clipboard picker panel without
        // needing the global shortcut, so it can be inspected/screenshotted.
        if CommandLine.arguments.contains("--open-picker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.clipboardPicker?.show()
            }
        }
        #endif
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
        clipboardPicker?.stop()
        AppState.shared.clipboard.stop()
        AppState.shared.monitor.stop()
        AppState.shared.monitor.flushHistory()
        AppState.shared.keepAwake.shutdown()
        AppState.shared.powerTools.stop()
    }
}
