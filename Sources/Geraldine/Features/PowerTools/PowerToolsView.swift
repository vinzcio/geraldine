import SwiftUI

struct PowerToolsView: View {
    @EnvironmentObject private var powerTools: PowerToolsController
    @State private var showEmptyTrashConfirmation = false

    private var tint: Color { Module.powerTools.tint }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .powerTools) {
                Button {
                    powerTools.refreshAccessibility(prompt: true)
                } label: {
                    Label(powerTools.accessibilityTrusted ? "Accessibility On" : "Grant Access",
                          systemImage: powerTools.accessibilityTrusted ? "checkmark.shield.fill" : "lock.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(powerTools.accessibilityTrusted ? tint : Theme.warn)
            }

            ScrollView {
                VStack(spacing: 16) {
                    permissionCard
                    dockCard
                    windowCard
                    safetyCard
                    finderCard
                    utilitiesCard
                    if let result = powerTools.lastResult {
                        resultCard(result)
                    }
                }
                .padding(20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .alert("Empty Trash permanently?", isPresented: $showEmptyTrashConfirmation) {
            Button("Empty Trash", role: .destructive) {
                powerTools.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the items currently in your Trash. It cannot be undone.")
        }
        .onAppear {
            powerTools.refreshAccessibility()
        }
    }

    private var permissionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: powerTools.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(powerTools.accessibilityTrusted ? Theme.good : Theme.warn)
            VStack(alignment: .leading, spacing: 3) {
                Text(powerTools.accessibilityTrusted ? "Input Controls Are Ready" : "Accessibility Is Required")
                    .font(.rounded(15, .semibold))
                Text("Dock clicks, traffic-light rewrites, keyboard safety, and Finder key handling need Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                Permissions.openAccessibilitySettings()
            }
        }
        .card(padding: 14)
    }

    private var dockCard: some View {
        ToolSection(title: "Dock", subtitle: "Windows-like Dock actions for running apps.", icon: "dock.rectangle", tint: tint) {
            Toggle("Enable Dock click actions", isOn: $powerTools.dockActionsEnabled)
                .toggleStyle(.switch)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Active App Click").foregroundStyle(.secondary)
                    Picker("Active App Click", selection: $powerTools.activeDockClickBehavior) {
                        ForEach(DockActiveClickBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                GridRow {
                    Text("Middle Click").foregroundStyle(.secondary)
                    Picker("Middle Click", selection: $powerTools.middleClickBehavior) {
                        ForEach(DockMiddleClickBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Toggle("Shift-click a running Dock app opens a new window", isOn: $powerTools.shiftClickNewWindow)
                .toggleStyle(.switch)
            Toggle("Unminimize windows when an app is activated", isOn: $powerTools.unminimizeOnActivation)
                .toggleStyle(.switch)
        }
    }

    private var windowCard: some View {
        ToolSection(title: "Windows", subtitle: "Fast window actions and traffic-light behavior.", icon: "macwindow.stack", tint: tint) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ToolButton(title: "Hide All", icon: "rectangle.compress.vertical") {
                    powerTools.hideAllWindows()
                }
                ToolButton(title: "Isolate", icon: "rectangle.on.rectangle.slash") {
                    powerTools.isolateFrontWindow()
                }
                ToolButton(title: "Minimize All", icon: "arrow.down.right.and.arrow.up.left") {
                    powerTools.minimizeAllWindows()
                }
            }

            Divider()

            Toggle("Green traffic-light fills/restores the window", isOn: $powerTools.greenButtonFillsWindow)
                .toggleStyle(.switch)
            Toggle("Yellow traffic-light hides the app", isOn: $powerTools.yellowButtonHidesApp)
                .toggleStyle(.switch)
            Text("Hold Option while clicking a traffic-light button to let macOS handle the original action.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        ToolSection(title: "Safety Keys", subtitle: "Guard accidental quits and closes.", icon: "keyboard", tint: tint) {
            Toggle("Require a quick second press for Command-Q", isOn: $powerTools.commandQDoubleTap)
                .toggleStyle(.switch)
            Toggle("Require a quick second press for Command-W", isOn: $powerTools.commandWDoubleTap)
                .toggleStyle(.switch)
            Text("The first press is swallowed with a short beep; pressing the same shortcut again within about a second allows it through.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finderCard: some View {
        ToolSection(title: "Finder", subtitle: "File actions without adding OCR or App Intents.", icon: "folder", tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Return opens the Finder selection", isOn: $powerTools.finderReturnOpens)
                    .toggleStyle(.switch)
                Toggle("Command-X / Command-V cuts and moves Finder items", isOn: $powerTools.finderCutPaste)
                    .toggleStyle(.switch)
                Toggle("Option-N creates a new text file in Finder", isOn: $powerTools.finderOptionNNewFile)
                    .toggleStyle(.switch)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ToolButton(title: "New Text File", icon: "doc.badge.plus") {
                    powerTools.newFinderTextFile()
                }
                ToolButton(title: "New Markdown", icon: "doc.plaintext") {
                    powerTools.newFinderTextFile(markdown: true)
                }
                ToolButton(title: "Copy Paths", icon: "doc.on.doc") {
                    powerTools.copyFinderPaths()
                }
                ToolButton(title: "Copy SHA-256", icon: "number") {
                    powerTools.copyFinderSHA256()
                }
                ToolButton(title: "Open Terminal", icon: "terminal") {
                    powerTools.openFinderTerminal()
                }
                ToolButton(title: "Copy To", icon: "arrowshape.turn.up.right") {
                    powerTools.copyFinderSelectionToFolder()
                }
                ToolButton(title: "Move To", icon: "arrow.right.doc.on.clipboard") {
                    powerTools.moveFinderSelectionToFolder()
                }
            }
        }
    }

    private var utilitiesCard: some View {
        ToolSection(title: "Utilities", subtitle: "Selected system utilities from the Supercharge list.", icon: "switch.2", tint: tint) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ToolButton(title: "Clear Clipboard", icon: "clipboard") {
                    powerTools.clearClipboard()
                }
                ToolButton(title: "Sleep Displays", icon: "display") {
                    powerTools.sleepDisplays()
                }
                ToolButton(title: "Eject Disks", icon: "externaldrive.badge.eject") {
                    powerTools.ejectDisks()
                }
                ToolButton(title: "Empty Trash…", icon: "trash", role: .destructive) {
                    showEmptyTrashConfirmation = true
                }
            }
        }
    }

    private func resultCard(_ result: PowerToolResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: resultIcon(result.status))
                .foregroundStyle(resultColor(result.status))
            Text(result.message)
                .font(.callout)
            Spacer()
        }
        .card(padding: 14)
    }

    private func resultIcon(_ status: PowerToolResultStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    private func resultColor(_ status: PowerToolResultStatus) -> Color {
        switch status {
        case .success: return tint
        case .warning: return Theme.warn
        case .failure: return Theme.bad
        }
    }
}

private struct ToolSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint)
                }
                SectionHeader(title, subtitle: subtitle)
            }

            content()
        }
        .card()
    }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                    .font(.rounded(13, .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Theme.bad : .primary)
    }
}
