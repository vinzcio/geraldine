import SwiftUI

struct CleanupView: View {
    @StateObject private var vm = CleanupViewModel()
    @State private var showPermanentDeleteConfirmation = false
    @State private var cancellationMessage: String?
    @State private var cancellationClearTask: Task<Void, Never>?

    private enum VisualPhase: Hashable { case idle, scanning, review, done }

    private var visualPhase: VisualPhase {
        switch vm.phase {
        case .idle: .idle
        case .scanning: .scanning
        case .results, .cleaning: .review
        case .done: .done
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .cleanup) {
                if vm.phase == .results || vm.phase == .done {
                    Button { rescan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }

            WorkflowPhaseHost(phase: visualPhase) {
                switch vm.phase {
                case .idle:
                    ScanStart(module: .cleanup,
                              message: "Geraldine will look through your caches, logs, Trash, and old installers — then let you review everything before it moves a single file.",
                              action: startScan)
                case .scanning:
                    ScanningState(tint: Module.cleanup.tint,
                                  label: "Looking For Junk",
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
                                       action: rescan)
                    } else {
                        VStack(spacing: 0) {
                            ScanResultsView(groups: vm.groups, selection: $vm.selection,
                                            diagnostics: vm.diagnostics,
                                            actionTitle: vm.selectedIncludesTrash ? "Clean Selected" : "Move to Trash",
                                            isBusy: vm.phase == .cleaning) {
                                if vm.selectedIncludesTrash {
                                    clearCancellation()
                                    showPermanentDeleteConfirmation = true
                                } else {
                                    beginClean()
                                }
                            }
                            if let cancellationMessage {
                                CancellationReturnNotice(message: cancellationMessage)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
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
                        .geraldineAnimation(.standard, value: cancellationMessage)
                    }
                case .done:
                    CleanDoneState(result: vm.lastResult, again: rescan)
                }
            }
        }
        .confirmationDialog("Remove selected Trash items permanently?",
                            isPresented: $showPermanentDeleteConfirmation) {
            Button("Permanently Delete Trash Items", role: .destructive) { beginClean() }
            Button("Cancel", role: .cancel) {
                noteCancellation("Cleanup cancelled · Selected files were not changed.")
            }
        } message: {
            Text("Items already in the Trash cannot be restored after this. Other selected items will only be moved to the Trash.")
        }
        .onDisappear { cancellationClearTask?.cancel() }
    }

    private func startScan() {
        clearCancellation()
        vm.scan()
    }

    private func rescan() {
        clearCancellation()
        vm.reset()
        vm.scan()
    }

    private func beginClean() {
        clearCancellation()
        vm.clean()
    }

    private func clearCancellation() {
        cancellationClearTask?.cancel()
        cancellationClearTask = nil
        cancellationMessage = nil
    }

    private func noteCancellation(_ message: String) {
        cancellationClearTask?.cancel()
        cancellationMessage = message
        cancellationClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled, cancellationMessage == message else { return }
            cancellationMessage = nil
            cancellationClearTask = nil
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
            WorkflowMark(state: .idle, tint: module.tint,
                         idleIcon: module.systemImage, size: 96)
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
            WorkflowMark(state: .working, tint: tint, idleIcon: icon, size: 76)
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

/// A neutral return from a cancelled destructive confirmation. It confirms
/// the user's choice without borrowing warning or success semantics.
struct CancellationReturnNotice: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.decorativeFill(Color.secondary, strength: .subtle),
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
        .transition(GeraldineMotion.stateTransition(
            reduceMotion: reduceMotion || !surfaceActive
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
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
            WorkflowMark(state: diagnostics.hasVisibleIssues ? .warning : .success,
                         tint: tint, idleIcon: icon, size: 82)
            Text(title).font(.rounded(20, .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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
    var actionTitle = "Scan Again"
    var actionIcon = "arrow.clockwise"
    var again: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            WorkflowMark(state: markState, tint: Theme.good,
                         idleIcon: "sparkles", size: 96)
            CompletionSweep(tint: outcomeTint)
                .frame(width: 180)
            if let r = result, r.removed > 0 {
                HStack(spacing: 5) {
                    Text("Freed")
                    AnimatedNumberText(Fmt.size(r.freed), value: Double(r.freed))
                }
                .font(.rounded(24, .bold))
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
            Button(action: again) { Label(actionTitle, systemImage: actionIcon) }
                .buttonStyle(.soft(outcomeTint))
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var markState: WorkflowMarkState {
        guard let result else { return .success }
        if result.removed == 0, !result.failures.isEmpty { return .failure }
        return result.failures.isEmpty ? .success : .warning
    }

    private var outcomeTint: Color {
        switch markState {
        case .success: Theme.good
        case .failure: Theme.bad
        case .warning: Theme.warn
        case .idle, .working: Theme.good
        }
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

private struct CompletionSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    @State private var completed = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [tint.opacity(0.08), tint, tint.opacity(0.08)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 2)
            .scaleEffect(x: reduceMotion || completed ? 1 : 0.08, anchor: .leading)
            .opacity(completed ? 0.65 : 0)
            .onAppear {
                if let animation = GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion) {
                    withAnimation(animation) { completed = true }
                } else {
                    completed = true
                }
            }
    }
}
