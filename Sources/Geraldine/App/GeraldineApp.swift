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
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no "New Window"
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.monitor)
        }
    }
}
