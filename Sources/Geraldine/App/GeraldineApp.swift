import AppKit
import SwiftUI

@main
struct GeraldineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Geraldine", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.monitor)
                .environmentObject(state.network)
                .environmentObject(state.keepAwake)
                .environmentObject(state.powerTools)
                .environmentObject(state.calendar)
                .environmentObject(state.aiUsage)
                .environmentObject(state.updates)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updates: state.updates)
            }
            CommandGroup(replacing: .newItem) {}   // no "New Window"
            CommandGroup(after: .newItem) {
                Button("Search Pages and Actions…") {
                    state.showMainWindow()
                    state.showsCommandSearch = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.monitor)
                .environmentObject(state.keepAwake)
                .environmentObject(state.powerTools)
                .environmentObject(state.aiUsage)
        }
    }
}
