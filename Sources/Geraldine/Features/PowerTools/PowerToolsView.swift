import AppKit
import SwiftUI

struct PowerToolsView: View {
    @EnvironmentObject private var powerTools: PowerToolsController
    @State private var showEmptyTrashConfirmation = false
    @State private var activeSection: ToolSectionID?
    @State private var activeActionID: String?
    @State private var workingActionID: String?
    @State private var cancellationMessage: String?
    @State private var permissionHandoffPending = false
    @State private var permissionReturnTone: OutcomeTone?

    private var tint: Color { Module.powerTools.tint }

    var body: some View {
        ModulePage(
            module: .powerTools,
            headerStyle: .utility,
            widthRole: .readable,
            trailing: { permissionControl }
        ) {
            permissionCard
            dockCard
            windowCard
            safetyCard
            finderCard
            utilitiesCard
        }
        .alert("Empty Trash Permanently?", isPresented: $showEmptyTrashConfirmation) {
            Button("Empty Trash", role: .destructive) {
                perform(section: .utilities, actionID: "emptyTrash") {
                    powerTools.emptyTrash()
                }
            }
            Button("Cancel", role: .cancel) {
                noteCancellation(section: .utilities, message: "Cancelled · Trash was not changed.")
            }
        } message: {
            Text("This removes the items currently in your Trash. It cannot be undone.")
        }
        .onAppear { powerTools.refreshAccessibility() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            acknowledgePermissionReturnIfNeeded()
        }
    }

    private var permissionControl: some View {
        Button(action: requestAccessibility) {
            Label(powerTools.accessibilityTrusted ? "Accessibility On" : "Grant Access",
                  systemImage: powerTools.accessibilityTrusted ? "checkmark.shield.fill" : "lock.shield")
        }
        .buttonStyle(.soft(powerTools.accessibilityTrusted ? tint : Theme.warn))
    }

    private var permissionCard: some View {
        HStack(spacing: Theme.Spacing.md) {
            ContextualSymbol(
                inactive: "exclamationmark.triangle.fill",
                active: "checkmark.circle.fill",
                isActive: powerTools.accessibilityTrusted,
                tint: powerTools.accessibilityTrusted ? Theme.good : Theme.warn,
                size: 24
            )
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(powerTools.accessibilityTrusted ? "Input Controls Are Ready" : "Accessibility Is Required")
                    .font(.geraldineSection)
                Text("Dock clicks, traffic-light rewrites, keyboard safety, and Finder key handling need Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                permissionHandoffPending = true
                Permissions.openAccessibilitySettings()
            }
            .buttonStyle(.quiet(powerTools.accessibilityTrusted ? tint : Theme.warn))
        }
        .outcomeWash(permissionReturnTone)
        .card(padding: Theme.Spacing.md,
              tier: .tinted(powerTools.accessibilityTrusted ? Theme.good : Theme.warn))
    }

    private var dockCard: some View {
        ToolSection(
            title: "Dock",
            subtitle: "Windows-like Dock actions for running apps.",
            icon: "dock.rectangle",
            tint: tint,
            isActive: activeSection == .dock,
            result: result(for: .dock),
            cancellationMessage: cancellation(for: .dock)
        ) {
            Toggle("Enable Dock Click Actions",
                   isOn: tracking($powerTools.dockActionsEnabled, section: .dock))
                .toggleStyle(.switch)

            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                GridRow {
                    Text("Active App Click").foregroundStyle(.secondary)
                    Picker("Active App Click",
                           selection: tracking($powerTools.activeDockClickBehavior, section: .dock)) {
                        ForEach(DockActiveClickBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                GridRow {
                    Text("Middle Click").foregroundStyle(.secondary)
                    Picker("Middle Click",
                           selection: tracking($powerTools.middleClickBehavior, section: .dock)) {
                        ForEach(DockMiddleClickBehavior.allCases) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Toggle("Shift-Click A Running Dock App Opens A New Window",
                   isOn: tracking($powerTools.shiftClickNewWindow, section: .dock))
                .toggleStyle(.switch)
            Toggle("Unminimize Windows When An App Is Activated",
                   isOn: tracking($powerTools.unminimizeOnActivation, section: .dock))
                .toggleStyle(.switch)
        }
    }

    private var windowCard: some View {
        ToolSection(
            title: "Windows",
            subtitle: "Fast window actions and traffic-light behavior.",
            icon: "macwindow.stack",
            tint: tint,
            isActive: activeSection == .windows,
            result: result(for: .windows),
            cancellationMessage: cancellation(for: .windows)
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.sm)],
                      spacing: Theme.Spacing.sm) {
                ToolButton(title: "Hide All", icon: "rectangle.compress.vertical",
                           state: actionState("hideAll"), tint: tint) {
                    perform(section: .windows, actionID: "hideAll") { powerTools.hideAllWindows() }
                }
                ToolButton(title: "Isolate", icon: "rectangle.on.rectangle.slash",
                           state: actionState("isolate"), tint: tint) {
                    perform(section: .windows, actionID: "isolate") { powerTools.isolateFrontWindow() }
                }
                ToolButton(title: "Minimize All", icon: "arrow.down.right.and.arrow.up.left",
                           state: actionState("minimizeAll"), tint: tint) {
                    perform(section: .windows, actionID: "minimizeAll") { powerTools.minimizeAllWindows() }
                }
            }

            Divider()

            Toggle("Green Traffic-Light Fills Or Restores The Window",
                   isOn: tracking($powerTools.greenButtonFillsWindow, section: .windows))
                .toggleStyle(.switch)
            Toggle("Yellow Traffic-Light Hides The App",
                   isOn: tracking($powerTools.yellowButtonHidesApp, section: .windows))
                .toggleStyle(.switch)
            Toggle("Two-Finger Tap Closes A Window In Mission Control",
                   isOn: tracking($powerTools.missionControlTwoFingerClose, section: .windows))
                .toggleStyle(.switch)
            Text("Hold Option while clicking a traffic-light button to let macOS handle the original action.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Uses the trackpad’s two-finger secondary click while the Mission Control window overview is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var safetyCard: some View {
        ToolSection(
            title: "Safety Keys",
            subtitle: "Guard accidental quits and closes.",
            icon: "keyboard",
            tint: tint,
            isActive: activeSection == .safety,
            result: result(for: .safety),
            cancellationMessage: cancellation(for: .safety)
        ) {
            Toggle("Require A Quick Second Press For Command-Q",
                   isOn: tracking($powerTools.commandQDoubleTap, section: .safety))
                .toggleStyle(.switch)
            Toggle("Require A Quick Second Press For Command-W",
                   isOn: tracking($powerTools.commandWDoubleTap, section: .safety))
                .toggleStyle(.switch)
            Text("The first press is swallowed with a short beep; pressing the same shortcut again within about a second allows it through.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var finderCard: some View {
        ToolSection(
            title: "Finder",
            subtitle: "File actions without replacing macOS-owned pickers or prompts.",
            icon: "folder",
            tint: tint,
            isActive: activeSection == .finder,
            result: result(for: .finder),
            cancellationMessage: cancellation(for: .finder)
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Toggle("Return Opens The Finder Selection",
                       isOn: tracking($powerTools.finderReturnOpens, section: .finder))
                    .toggleStyle(.switch)
                Toggle("Command-X / Command-V Cuts And Moves Finder Items",
                       isOn: tracking($powerTools.finderCutPaste, section: .finder))
                    .toggleStyle(.switch)
                Toggle("Option-N Creates A New Text File In Finder",
                       isOn: tracking($powerTools.finderOptionNNewFile, section: .finder))
                    .toggleStyle(.switch)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Theme.Spacing.sm)],
                      spacing: Theme.Spacing.sm) {
                ToolButton(title: "New Text File", icon: "doc.badge.plus",
                           state: actionState("newText"), tint: tint) {
                    perform(section: .finder, actionID: "newText") { powerTools.newFinderTextFile() }
                }
                ToolButton(title: "New Markdown", icon: "doc.plaintext",
                           state: actionState("newMarkdown"), tint: tint) {
                    perform(section: .finder, actionID: "newMarkdown") { powerTools.newFinderTextFile(markdown: true) }
                }
                ToolButton(title: "Copy Paths", icon: "doc.on.doc",
                           state: actionState("copyPaths"), tint: tint) {
                    perform(section: .finder, actionID: "copyPaths") { powerTools.copyFinderPaths() }
                }
                ToolButton(title: "Copy SHA-256", icon: "number",
                           state: actionState("copyHash"), tint: tint) {
                    perform(section: .finder, actionID: "copyHash") { powerTools.copyFinderSHA256() }
                }
                ToolButton(title: "Open Terminal", icon: "terminal",
                           state: actionState("terminal"), tint: tint) {
                    perform(section: .finder, actionID: "terminal") { powerTools.openFinderTerminal() }
                }
                ToolButton(title: "Copy To", icon: "arrowshape.turn.up.right",
                           state: actionState("copyTo"), tint: tint) {
                    perform(section: .finder, actionID: "copyTo") { powerTools.copyFinderSelectionToFolder() }
                }
                ToolButton(title: "Move To", icon: "arrow.right.doc.on.clipboard",
                           state: actionState("moveTo"), tint: tint) {
                    perform(section: .finder, actionID: "moveTo") { powerTools.moveFinderSelectionToFolder() }
                }
            }
        }
    }

    private var utilitiesCard: some View {
        ToolSection(
            title: "Utilities",
            subtitle: "Small system actions with results kept beside their owner.",
            icon: "switch.2",
            tint: tint,
            isActive: activeSection == .utilities,
            result: result(for: .utilities),
            cancellationMessage: cancellation(for: .utilities)
        ) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.sm)],
                      spacing: Theme.Spacing.sm) {
                ToolButton(title: "Clear Clipboard", icon: "clipboard",
                           state: actionState("clearClipboard"), tint: tint) {
                    perform(section: .utilities, actionID: "clearClipboard") { powerTools.clearClipboard() }
                }
                ToolButton(title: "Sleep Displays", icon: "display",
                           state: actionState("sleepDisplays"), tint: tint) {
                    perform(section: .utilities, actionID: "sleepDisplays") { powerTools.sleepDisplays() }
                }
                ToolButton(title: "Eject Disks", icon: "externaldrive.badge.eject",
                           state: actionState("ejectDisks"), tint: tint) {
                    perform(section: .utilities, actionID: "ejectDisks") { powerTools.ejectDisks() }
                }
                ToolButton(title: "Empty Trash…", icon: "trash",
                           state: actionState("emptyTrash"), tint: tint, role: .destructive) {
                    activeSection = .utilities
                    activeActionID = "emptyTrash"
                    cancellationMessage = nil
                    powerTools.lastResult = nil
                    showEmptyTrashConfirmation = true
                }
            }
        }
    }

    private func tracking<Value>(_ binding: Binding<Value>, section: ToolSectionID) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                markActive(section)
                binding.wrappedValue = value
            }
        )
    }

    private func markActive(_ section: ToolSectionID) {
        activeSection = section
        activeActionID = nil
        workingActionID = nil
        cancellationMessage = nil
        powerTools.lastResult = nil
    }

    private func perform(section: ToolSectionID, actionID: String, action: @escaping () -> Void) {
        activeSection = section
        activeActionID = actionID
        workingActionID = actionID
        cancellationMessage = nil
        powerTools.lastResult = nil

        Task { @MainActor in
            await Task.yield()
            action()
            workingActionID = nil
            if powerTools.lastResult?.status == .success {
                clearSuccessfulActionLater(actionID)
            }
        }
    }

    private func clearSuccessfulActionLater(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if activeActionID == id, powerTools.lastResult?.status == .success {
                activeActionID = nil
            }
        }
    }

    private func noteCancellation(section: ToolSectionID, message: String) {
        activeSection = section
        activeActionID = nil
        workingActionID = nil
        cancellationMessage = message
        powerTools.lastResult = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if cancellationMessage == message { cancellationMessage = nil }
        }
    }

    private func actionState(_ id: String) -> StatefulActionState {
        if workingActionID == id { return .working }
        guard activeActionID == id, let result = powerTools.lastResult else { return .idle }
        switch result.status {
        case .success: return .success
        case .warning, .failure: return .failure
        }
    }

    private func result(for section: ToolSectionID) -> PowerToolResult? {
        activeSection == section ? powerTools.lastResult : nil
    }

    private func cancellation(for section: ToolSectionID) -> String? {
        activeSection == section ? cancellationMessage : nil
    }

    private func requestAccessibility() {
        permissionHandoffPending = true
        powerTools.refreshAccessibility(prompt: true)
        showPermissionReturnTone()
    }

    private func acknowledgePermissionReturnIfNeeded() {
        guard permissionHandoffPending else { return }
        permissionHandoffPending = false
        powerTools.refreshAccessibility()
        showPermissionReturnTone()
    }

    private func showPermissionReturnTone() {
        permissionReturnTone = powerTools.accessibilityTrusted ? .success : .warning
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            permissionReturnTone = nil
        }
    }
}

private enum ToolSectionID: Hashable {
    case dock
    case windows
    case safety
    case finder
    case utilities
}

private struct ToolSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let isActive: Bool
    let result: PowerToolResult?
    let cancellationMessage: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                ModuleGlyph(systemImage: icon, tint: tint, size: 40)
                SectionHeader(title, subtitle: subtitle)
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.10), in: Capsule())
                }
            }

            content()

            if let result {
                ToolResultBanner(result: result)
                    .transition(.opacity)
            } else if let cancellationMessage {
                Label(cancellationMessage, systemImage: "arrow.uturn.backward.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(Theme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            }
        }
        .outcomeWash(result.map(outcomeTone))
        .interactiveCard(
            tier: isActive ? .tinted(tint) : .raised
        )
        .geraldineAnimation(.standard, value: feedbackKey)
    }

    private var feedbackKey: String {
        result?.message ?? cancellationMessage ?? ""
    }

    private func outcomeTone(_ result: PowerToolResult) -> OutcomeTone {
        switch result.status {
        case .success: .success
        case .warning: .warning
        case .failure: .failure
        }
    }
}

private struct ToolButton: View {
    let title: String
    let icon: String
    let state: StatefulActionState
    let tint: Color
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        WorkflowPhaseHost(phase: phase) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        if state == .success {
            HStack(spacing: Theme.Spacing.xs) {
                ContextualSymbol(inactive: icon,
                                 active: "checkmark",
                                 isActive: true,
                                 tint: Theme.good,
                                 size: 14)
                Text("Done").font(.rounded(13, .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .foregroundStyle(Theme.good)
            .background(Theme.good.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title) completed")
        } else {
            Button(role: role, action: action) {
                HStack(spacing: Theme.Spacing.xs) {
                    if state == .working {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        ContextualSymbol(inactive: icon,
                                         active: "arrow.clockwise",
                                         isActive: state == .failure,
                                         tint: resolvedTint,
                                         size: 14)
                    }
                    Text(label).font(.rounded(13, .semibold))
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.quiet(resolvedTint))
            .disabled(state == .working)
            .accessibilityLabel(label)
        }
    }

    private var phase: ToolButtonPhase {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .success: return .success
        case .failure: return .failure
        }
    }

    private var label: String {
        switch state {
        case .idle: title
        case .working: "Working…"
        case .success: "Done"
        case .failure: "Retry"
        }
    }

    private var resolvedTint: Color {
        if role == .destructive, state == .idle { return Theme.bad }
        switch state {
        case .success: return Theme.good
        case .failure: return Theme.bad
        case .idle, .working: return tint
        }
    }
}

private enum ToolButtonPhase: Hashable {
    case idle
    case working
    case success
    case failure
}

private struct ToolResultBanner: View {
    let result: PowerToolResult

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon).foregroundStyle(color)
            Text(result.message).font(.caption.weight(.medium))
            Spacer()
        }
        .padding(Theme.Spacing.xs)
        .background(color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch result.status {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch result.status {
        case .success: Theme.good
        case .warning: Theme.warn
        case .failure: Theme.bad
        }
    }
}
