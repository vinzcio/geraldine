import SwiftUI

struct MaintenanceView: View {
    @StateObject private var vm = MaintenanceViewModel()
    @State private var pendingTask: MaintenanceTask?
    @State private var acceptedTaskID: String?
    @State private var recentlyCancelledTaskID: String?

    var body: some View {
        ModulePage(module: .maintenance, headerStyle: .utility, widthRole: .readable) {
            LazyVStack(spacing: Theme.Spacing.md) {
                ForEach(vm.tasks) { task in
                    TaskCard(
                        task: task,
                        status: vm.status(task.id),
                        lastRun: vm.lastRun(task.id),
                        recentlyCancelled: recentlyCancelledTaskID == task.id
                    ) {
                        acceptedTaskID = nil
                        pendingTask = task
                    }
                }
            }
        }
        .confirmationDialog(pendingTask.map { "Run \($0.title)?" } ?? "Run maintenance task?",
                            isPresented: Binding(
                                get: { pendingTask != nil },
                                set: { presented in
                                    guard !presented else { return }
                                    if let task = pendingTask, acceptedTaskID != task.id {
                                        markCancelled(task.id)
                                    }
                                    pendingTask = nil
                                    acceptedTaskID = nil
                                }
                            )) {
            Button(pendingTask?.needsAdmin == true ? "Run with Password" : "Run Task",
                   role: .destructive) {
                if let task = pendingTask {
                    acceptedTaskID = task.id
                    recentlyCancelledTaskID = nil
                    vm.run(task)
                }
                pendingTask = nil
            }
            Button("Cancel", role: .cancel) {
                if let task = pendingTask { markCancelled(task.id) }
                pendingTask = nil
            }
        } message: {
            Text(pendingTask?.confirmationMessage ?? "")
        }
    }

    private func markCancelled(_ id: String) {
        recentlyCancelledTaskID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if recentlyCancelledTaskID == id {
                recentlyCancelledTaskID = nil
            }
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let status: TaskStatus
    let lastRun: MaintenanceRun?
    let recentlyCancelled: Bool
    let run: () -> Void

    @State private var showsFailureOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 14) {
                ModuleGlyph(systemImage: task.icon, tint: Module.maintenance.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.rounded(15, .semibold))
                        if task.needsAdmin {
                            Label("Password", systemImage: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.warn.opacity(0.12), in: Capsule())
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                control
            }

            Divider().opacity(0.45)

            WorkflowPhaseHost(phase: phase) {
                phaseSummary
            }
            .frame(height: 40, alignment: .leading)

            if showsFailureOutput, let lastRun, !lastRun.ok {
                Text(outputText(lastRun))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                    .transition(.opacity)
            }
        }
        .interactiveCard(
            padding: Theme.Spacing.md,
            tier: cardTier
        )
        .onChange(of: status) { _, newStatus in
            if newStatus != .failed { showsFailureOutput = false }
        }
        .geraldineAnimation(.standard, value: showsFailureOutput)
    }

    private var control: some View {
        StatefulActionButton(
            state: actionState,
            idleTitle: "Run",
            workingTitle: "Running",
            successTitle: "Done",
            failureTitle: "Retry",
            idleIcon: task.needsAdmin ? "lock.fill" : "play.fill",
            tint: Module.maintenance.tint,
            action: run
        )
        .allowsHitTesting(status != .done)
    }

    @ViewBuilder private var phaseSummary: some View {
        switch phase {
        case .cancelled:
            Label("Cancelled · Nothing changed", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .status(.idle):
            Label(task.needsAdmin ? "Ready · macOS will ask for your password" : "Ready to run",
                  systemImage: task.needsAdmin ? "lock.shield" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .status(.running):
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Running \(task.title.lowercased())…")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Module.maintenance.tint)
        case .status(.done):
            Label(lastRun.map { "Completed at \($0.finishedAt.formatted(date: .omitted, time: .shortened))" }
                  ?? "Completed", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.good)
        case .status(.failed):
            HStack(spacing: Theme.Spacing.xs) {
                Label(lastRun.map { "Failed at \($0.finishedAt.formatted(date: .omitted, time: .shortened))" }
                      ?? "Task failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.bad)
                Spacer()
                if lastRun != nil {
                    Button(showsFailureOutput ? "Hide Details" : "Details") {
                        showsFailureOutput.toggle()
                    }
                    .buttonStyle(.quiet(Theme.bad))
                }
            }
        }
    }

    private var phase: TaskCardPhase {
        recentlyCancelled ? .cancelled : .status(status)
    }

    private var actionState: StatefulActionState {
        switch status {
        case .idle: .idle
        case .running: .working
        case .done: .success
        case .failed: .failure
        }
    }

    private var cardTier: CardTier {
        switch status {
        case .running: return .tinted(Module.maintenance.tint)
        case .done: return .tinted(Theme.good)
        case .failed: return .tinted(Theme.bad)
        case .idle: return .raised
        }
    }

    private func outputText(_ run: MaintenanceRun) -> String {
        let trimmed = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Command failed without output: \(run.command)"
    }
}

private enum TaskCardPhase: Hashable {
    case cancelled
    case status(TaskStatus)
}
