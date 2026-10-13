import SwiftUI

struct ProcessDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let group: ProcessGroup
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.title2.weight(.semibold))
                    Text(isCurrent ? "Sampled app activity" : "No longer in the current sample")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 28) {
                summary("CPU", value: group.cpu)
                summary("Memory share", value: group.memory)
            }
            if let path = group.applicationPath {
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(isCurrent
                 ? "Includes only processes in the current sample, not every helper owned by this app. CPU is measured per core and may exceed 100%."
                 : "Showing the last sampled values. This app may still be running outside the top sampled processes.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("Process / PID").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: 70, alignment: .trailing)
                        Text("Memory").frame(width: 70, alignment: .trailing)
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.processes) { process in
                        Divider().padding(.vertical, 8)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.name).lineLimit(2)
                                Text("PID \(process.id)").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.1f%%", process.cpu)).frame(width: 70, alignment: .trailing)
                            Text(String(format: "%.1f%%", process.mem)).frame(width: 70, alignment: .trailing)
                        }.font(.callout.monospacedDigit())
                    }
                }
            }
        }
        .padding(24).frame(width: 580, height: 480)
    }

    private func summary(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f%%", value)).font(.title2.monospacedDigit())
        }
    }
}
