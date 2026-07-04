import SwiftUI

struct CleanupView: View {
    @StateObject private var vm = CleanupViewModel()
    @State private var showPermanentDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .cleanup) {
                if vm.phase == .results || vm.phase == .done {
                    Button { vm.reset(); vm.scan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }

            switch vm.phase {
            case .idle:
                ScanStart(module: .cleanup,
                          message: "Geraldine will look through your caches, logs, Trash, and old installers — then let you review everything before it moves a single file.",
                          action: vm.scan)
            case .scanning:
                ScanningState(tint: Module.cleanup.tint,
                              label: "Looking for junk…",
                              progressText: vm.scanProgressText,
                              onCancel: vm.cancelScan)
            case .results, .cleaning:
                if vm.groups.isEmpty {
                    ScanEmptyState(icon: "checkmark.seal.fill",
                                   title: "No Cleanup Items Found",
                                   message: vm.emptyMessage,
                                   tint: Module.cleanup.tint,
                                   diagnostics: vm.diagnostics,
                                   actionTitle: "Scan Again",
                                   action: { vm.reset(); vm.scan() })
                } else {
                    ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                    diagnostics: vm.diagnostics,
                                    actionTitle: vm.selectedIncludesTrash ? "Clean Selected" : "Move to Trash",
                                    isBusy: vm.phase == .cleaning) {
                        if vm.selectedIncludesTrash {
                            showPermanentDeleteConfirmation = true
                        } else {
                            vm.clean()
                        }
                    }
                    if vm.selectedIncludesTrash {
                        Text("Selected Trash items will be permanently deleted. Other selected files move to the Trash.")
                            .font(.caption).foregroundStyle(Theme.bad)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    } else {
                        Text("Files outside the Trash are moved to the Trash first, so you can restore them from Finder.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
            case .done:
                CleanDoneState(result: vm.lastResult, again: { vm.reset(); vm.scan() })
            }
        }
        .confirmationDialog("Remove selected Trash items permanently?",
                            isPresented: $showPermanentDeleteConfirmation) {
            Button("Permanently Delete Trash Items", role: .destructive) { vm.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items already in the Trash cannot be restored after this. Other selected items will only be moved to the Trash.")
        }
    }
}

// MARK: - Shared scan-flow states (reused by other cleaning modules)

struct ScanStart: View {
    var module: Module
    var message: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            IconBadge(icon: module.systemImage, tint: module.tint, size: 96)
            Text("Scan For \(module.title)").font(.rounded(20, .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            PrimaryButton(title: "Scan", icon: "magnifyingglass", action: action)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanningState: View {
    var tint: Color
    var icon: String = "sparkles"
    var label: String
    var progressText: String? = nil
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            BrandSpinner(tint: tint, icon: icon)
            Text(label).font(.rounded(16, .medium)).foregroundStyle(.secondary)
            if let progressText {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let onCancel {
                Button("Cancel Scan", action: onCancel)
                    .buttonStyle(.soft(tint))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ScanEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color
    var diagnostics: ScanDiagnostics = .empty
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            EmptyState(icon: icon, title: title, message: message, tint: tint)
                .frame(maxHeight: 220)
            if diagnostics.hasVisibleIssues {
                ScanDiagnosticsBanner(diagnostics: diagnostics)
                    .frame(maxWidth: 460)
            }
            Button(action: action) { Label(actionTitle, systemImage: "arrow.clockwise") }
                .buttonStyle(.soft(tint))
                .padding(.top, 2)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CleanDoneState: View {
    var result: TrashService.Result?
    var again: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            IconBadge(icon: "checkmark", tint: Theme.good, size: 96)
            if let r = result, r.removed > 0 {
                Text("Freed \(Fmt.size(r.freed))").font(.rounded(24, .bold))
                Text(resultMessage(r))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(result?.failures.isEmpty == false ? "Some Items Need Attention" : "All Clean")
                    .font(.rounded(24, .bold))
                Text(result.map(resultMessage) ?? "Nothing to tidy up right now.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let failure = result?.failures.first {
                Text("\(failure.url.path): \(failure.message)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: 460)
            }
            Button(action: again) { Label("Scan Again", systemImage: "arrow.clockwise") }
                .buttonStyle(.soft(Theme.good))
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultMessage(_ result: TrashService.Result) -> String {
        var parts: [String] = []
        if result.trashed > 0 {
            parts.append("\(result.trashed) item\(result.trashed == 1 ? "" : "s") moved to the Trash")
        }
        if result.permanentlyDeleted > 0 {
            parts.append("\(result.permanentlyDeleted) item\(result.permanentlyDeleted == 1 ? "" : "s") permanently deleted")
        }
        if parts.isEmpty {
            parts.append("\(result.removed) item\(result.removed == 1 ? "" : "s") cleaned")
        }
        if !result.failures.isEmpty {
            parts.append("\(result.failures.count) failed or needed permission")
        }
        return parts.joined(separator: " · ")
    }
}
