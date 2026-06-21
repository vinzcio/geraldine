import SwiftUI

struct MaintenanceView: View {
    @StateObject private var vm = MaintenanceViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .maintenance)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(vm.tasks) { task in
                        TaskCard(task: task, status: vm.status(task.id)) { vm.run(task) }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct TaskCard: View {
    let task: MaintenanceTask
    let status: TaskStatus
    let run: () -> Void

    var body: some View {
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
                        Text("password").font(.caption2.weight(.medium))
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
}
