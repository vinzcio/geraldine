import SwiftUI

enum MemoryActions {
    /// Reclaims inactive memory via `purge` (needs one admin prompt).
    static func freeUpRAM() async -> Bool {
        await Task.detached {
            Shell.runAdmin("/usr/sbin/purge").ok
        }.value
    }
}

struct FreeRAMView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.dismiss) private var dismiss

    enum Phase { case ready, working, done, failed }
    @State private var phase: Phase = .ready
    @State private var before: Double = 0
    @State private var freed: Double = 0

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: "memorychip").font(.system(size: 38, weight: .medium)).foregroundStyle(Theme.accent)
            }

            switch phase {
            case .ready:
                Text("Free Up Memory").font(.rounded(20, .bold))
                Text("\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal)) in use. Geraldine will ask for your password, then reclaim inactive memory.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                PrimaryButton(title: "Free Up Memory", icon: "wand.and.sparkles", action: run)
            case .working:
                ProgressView().controlSize(.large)
                Text("Reclaiming memory…").foregroundStyle(.secondary)
            case .done:
                Text(freed > 0 ? "Freed \(Fmt.size(freed))" : "Memory optimized").font(.rounded(22, .bold))
                Text("Now \(Fmt.size(monitor.memoryUsed)) in use.").font(.callout).foregroundStyle(.secondary)
                Button("Done") { dismiss() }
            case .failed:
                Text("Couldn't free memory").font(.rounded(20, .semibold))
                Text("The action was cancelled or denied.").font(.callout).foregroundStyle(.secondary)
                Button("Close") { dismiss() }
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private func run() {
        before = monitor.memoryUsed
        phase = .working
        Task {
            let ok = await MemoryActions.freeUpRAM()
            monitor.refresh()
            freed = max(0, before - monitor.memoryUsed)
            phase = ok ? .done : .failed
        }
    }
}
