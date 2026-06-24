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
                ScanningState(tint: Module.cleanup.tint, label: "Looking for junk…")
            case .results, .cleaning:
                ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                actionTitle: vm.selectedIncludesTrash ? "Clean Selected" : "Move to Trash",
                                isBusy: vm.phase == .cleaning) {
                    if vm.selectedIncludesTrash {
                        showPermanentDeleteConfirmation = true
                    } else {
                        vm.clean()
                    }
                }
            case .done:
                CleanDoneState(result: vm.lastResult, again: { vm.reset(); vm.scan() })
            }
        }
        .confirmationDialog("Remove selected Trash items permanently?",
                            isPresented: $showPermanentDeleteConfirmation) {
            Button("Clean Selected", role: .destructive) { vm.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items already in the Trash will be permanently deleted. Other selected items will be moved to the Trash.")
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
            ZStack {
                Circle().fill(module.tint.opacity(0.12)).frame(width: 96, height: 96)
                Image(systemName: module.systemImage).font(.system(size: 40, weight: .medium))
                    .foregroundStyle(module.tint)
            }
            Text("Scan for \(module.title.lowercased())").font(.rounded(20, .semibold))
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
    var label: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large).tint(tint)
            Text(label).font(.rounded(16, .medium)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CleanDoneState: View {
    var result: TrashService.Result?
    var again: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Theme.good.opacity(0.14)).frame(width: 96, height: 96)
                Image(systemName: "checkmark").font(.system(size: 42, weight: .bold)).foregroundStyle(Theme.good)
            }
            if let r = result, r.removed > 0 {
                Text("Freed \(Fmt.size(r.freed))").font(.rounded(24, .bold))
                Text(resultMessage(r))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("All clean").font(.rounded(24, .bold))
                Text("Nothing to tidy up right now.").font(.callout).foregroundStyle(.secondary)
            }
            Button(action: again) { Label("Scan again", systemImage: "arrow.clockwise") }
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
        if !result.failed.isEmpty {
            parts.append("\(result.failed.count) needed permission")
        }
        return parts.joined(separator: " · ")
    }
}
