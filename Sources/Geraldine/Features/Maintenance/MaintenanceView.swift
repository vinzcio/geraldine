import SwiftUI

struct MaintenanceView: View {
    @StateObject private var vm = MaintenanceViewModel()
    @State private var pendingTask: MaintenanceTask?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .maintenance)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(vm.tasks) { task in
                        TaskCard(task: task,
                                 status: vm.status(task.id),
                                 lastRun: vm.lastRun(task.id)) {
                            pendingTask = task
                        }
                    }
                }
                .padding(20)
            }
        }
        .confirmationDialog(pendingTask.map { "Run \($0.title)?" } ?? "Run maintenance task?",
                            isPresented: Binding(
                                get: { pendingTask != nil },
                                set: { if !$0 { pendingTask = nil } }
                            )) {
            Button(pendingTask?.needsAdmin == true ? "Run with Password" : "Run Task",
                   role: .destructive) {
                if let task = pendingTask { vm.run(task) }
                pendingTask = nil
            }
            Button("Cancel", role: .cancel) { pendingTask = nil }
        } message: {
            Text(pendingTask?.confirmationMessage ?? "")
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let status: TaskStatus
    let lastRun: MaintenanceRun?
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Module.maintenance.tint.opacity(0.16)).frame(width: 40, height: 40)
                    Image(systemName: task.icon).foregroundStyle(Module.maintenance.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.rounded(15, .semibold))
                        if task.needsAdmin {
                            Text("Password").font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.warn.opacity(0.2), in: Capsule())
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    Text(task.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                control
            }

            if let lastRun {
                HStack(spacing: 6) {
                    Image(systemName: lastRun.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(lastRun.ok ? Theme.good : Theme.warn)
                    Text("Last Run \(lastRun.finishedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !lastRun.ok {
                    Text(outputText(lastRun))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
        .card(padding: 14)
    }

    @ViewBuilder private var control: some View {
        switch status {
        case .idle:    Button("Run", action: run).buttonStyle(.borderedProminent).tint(Module.maintenance.tint)
        case .running: ProgressView().controlSize(.small)
        case .done:    Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good).font(.callout)
        case .failed:  Button("Retry", action: run).buttonStyle(.bordered).tint(Theme.bad)
        }
    }

    private func outputText(_ run: MaintenanceRun) -> String {
        let trimmed = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Command failed without output: \(run.command)"
    }
}
