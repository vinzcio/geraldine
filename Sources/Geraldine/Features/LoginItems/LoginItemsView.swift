import AppKit
import SwiftUI

struct LoginItemsView: View {
    @StateObject private var vm = LoginItemsViewModel()
    @State private var pendingRemoval: LaunchItem?
    @State private var expandedLockedItems: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            ScreenContent(widthRole: .readable) {
                PageHeader(module: .loginItems, style: .utility) {
                    Label("Changes Apply At Next Login", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            WorkflowPhaseHost(phase: phase) {
                phaseContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if vm.items.isEmpty { vm.load() } }
        // `presenting:` hands the item to the buttons directly. SwiftUI writes
        // isPresented back to false *before* running the chosen button's
        // action, so the buttons must not depend on reading `pendingRemoval`.
        .confirmationDialog("Remove login item?",
                            isPresented: Binding(
                                get: { pendingRemoval != nil },
                                set: { if !$0 { pendingRemoval = nil } }
                            ),
                            presenting: pendingRemoval) { item in
            Button("Move Login Item to Trash", role: .destructive) {
                vm.remove(item)
            }
            Button("Cancel", role: .cancel) {
                vm.noteRemovalCancelled(item)
            }
        } message: { _ in
            Text("This moves the selected LaunchAgent plist to the Trash. The app or helper will stop launching automatically at your next login.")
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch phase {
        case .scanning:
            ScanningState(tint: Module.loginItems.tint,
                          icon: Module.loginItems.systemImage,
                          label: "Reading startup items…")
        case .empty:
            ScanEmptyState(icon: "powerplug",
                           title: "No Login Items Found",
                           message: vm.diagnostics.hasVisibleIssues
                               ? "Geraldine could not read every startup item location."
                               : "No editable or system startup items were found.",
                           tint: Module.loginItems.tint,
                           diagnostics: vm.diagnostics,
                           actionTitle: "Check Again",
                           action: vm.load)
        case .ledger:
            ledger
        }
    }

    private var ledger: some View {
        VStack(spacing: 0) {
            statusBanner

            List {
                ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                    let rows = vm.items(in: scope)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { item in
                                LoginItemLedgerRow(
                                    item: item,
                                    actionState: vm.actionState(for: item),
                                    explanationExpanded: expandedLockedItems.contains(item.id),
                                    toggle: { vm.toggle(item) },
                                    remove: { pendingRemoval = item },
                                    toggleExplanation: { toggleExplanation(for: item) }
                                )
                                .listRowInsets(EdgeInsets(top: 3, leading: 14, bottom: 3, trailing: 14))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Text(scope.rawValue)
                                Spacer()
                                Text("\(rows.count)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.geraldineLabel)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .geraldineAnimation(.standard, value: vm.latestOutcome?.id)
    }

    @ViewBuilder private var statusBanner: some View {
        if let outcome = vm.latestOutcome {
            LoginItemsOutcomeBanner(outcome: outcome)
                .padding(.horizontal, Theme.Layout.pagePadding)
                .padding(.bottom, Theme.Spacing.xs)
                .transition(.opacity)
        } else if let lastError = vm.lastError {
            LoginItemsBanner(message: lastError)
                .padding(.horizontal, Theme.Layout.pagePadding)
                .padding(.bottom, Theme.Spacing.xs)
        } else if vm.diagnostics.hasVisibleIssues {
            ScanDiagnosticsBanner(diagnostics: vm.diagnostics)
                .padding(.horizontal, Theme.Layout.pagePadding)
                .padding(.bottom, Theme.Spacing.xs)
        }
    }

    private var phase: LoginItemsPhase {
        if vm.loading && vm.items.isEmpty { return .scanning }
        return vm.items.isEmpty ? .empty : .ledger
    }

    private func toggleExplanation(for item: LaunchItem) {
        if expandedLockedItems.contains(item.id) {
            expandedLockedItems.remove(item.id)
        } else {
            expandedLockedItems.insert(item.id)
        }
    }
}

private enum LoginItemsPhase: Hashable {
    case scanning
    case empty
    case ledger
}

private struct LoginItemLedgerRow: View {
    let item: LaunchItem
    let actionState: LoginItemActionState?
    let explanationExpanded: Bool
    let toggle: () -> Void
    let remove: () -> Void
    let toggleExplanation: () -> Void

    @State private var isHovered = false

    var body: some View {
        CareLedgerRow(
            tint: rowTint,
            title: item.displayName,
            detail: detail,
            status: ledgerStatus
        ) {
            LaunchItemBadge(item: item, tint: rowTint)
        } accessory: {
            accessory
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(rowBackground)
        }
        .onHover { isHovered = $0 }
        .geraldineAnimation(.quick, value: isHovered)
        .geraldineAnimation(.standard, value: actionState)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var accessory: some View {
        if actionState == .working {
            ProgressView()
                .controlSize(.small)
                .frame(width: 72, height: Theme.Layout.minimumHitArea)
                .accessibilityLabel("Updating \(item.displayName)")
        } else if item.editable {
            HStack(spacing: Theme.Spacing.xs) {
                Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in toggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(item.enabled ? "Disable \(item.displayName)" : "Enable \(item.displayName)")
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.quiet(Theme.bad))
                .help("Remove this startup item")
                .accessibilityLabel("Remove \(item.displayName)")
            }
        } else {
            Button(action: toggleExplanation) {
                HStack(spacing: 5) {
                    Text("System").font(.caption2.weight(.semibold))
                    ContextualSymbol(inactive: "info.circle",
                                     active: "chevron.up.circle",
                                     isActive: explanationExpanded,
                                     tint: .secondary,
                                     size: 12)
                }
            }
            .buttonStyle(.quiet())
            .help(explanationExpanded ? "Hide locked-item explanation" : "Explain why this item is locked")
        }
    }

    private var detail: String? {
        if !item.editable && explanationExpanded {
            return "Managed by macOS or an administrator. Geraldine can inspect this item but cannot change it."
        }
        if item.label != item.displayName { return item.label }
        if !item.program.isEmpty { return item.program }
        return item.enabled ? "Enabled For Your Account" : "Disabled By Geraldine"
    }

    private var rowTint: Color {
        item.editable ? Module.loginItems.tint : Color.secondary
    }

    private var ledgerStatus: LedgerStatus {
        switch actionState {
        case .working: return .working
        case .success, .failure, .cancelled: return .neutral
        case nil: return item.enabled && item.editable ? .selected : .neutral
        }
    }

    private var rowBackground: Color {
        switch actionState {
        case .success: return Theme.good.opacity(0.08)
        case .failure: return Theme.bad.opacity(0.08)
        case .cancelled: return Color.secondary.opacity(0.06)
        case .working, nil: return isHovered ? rowTint.opacity(0.06) : Color.clear
        }
    }
}

/// The row identity: the owning app's real icon when the launch item points
/// into an .app bundle, otherwise a tinted monogram of the display name.
private struct LaunchItemBadge: View {
    let item: LaunchItem
    let tint: Color
    var size: CGFloat = 36

    var body: some View {
        if let appURL = item.appURL {
            AppIconPlate(size: size) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
            .accessibilityHidden(true)
        } else {
            MonogramPlate(text: item.displayName, tint: tint, size: size)
        }
    }
}

private struct LoginItemsOutcomeBanner: View {
    let outcome: LoginItemOutcome

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(outcome.message).font(.caption.weight(.medium))
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(tint.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch outcome.kind {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .cancelled: "arrow.uturn.backward.circle"
        }
    }

    private var tint: Color {
        switch outcome.kind {
        case .success: Theme.good
        case .failure: Theme.bad
        case .cancelled: Color.secondary
        }
    }
}

private struct LoginItemsBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.warn.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
