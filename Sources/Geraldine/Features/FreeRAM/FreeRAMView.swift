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

    enum Phase: Hashable { case ready, working, done, failed }
    @State private var phase: Phase = .ready
    @State private var before: Double = 0
    @State private var freed: Double = 0

    var body: some View {
        VStack(spacing: 18) {
            MemoryChipWorkflowMark(phase: phase, size: 92)

            WorkflowPhaseHost(phase: phase) {
                VStack(spacing: 14) {
                    switch phase {
                    case .ready:
                        Text("Free Up Memory").font(.rounded(20, .bold))
                        Text("\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal)) in use. Geraldine will ask for your password, then reclaim inactive memory.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        PrimaryButton(title: "Free Up Memory", icon: "wand.and.sparkles", action: run)
                    case .working:
                        Text("Reclaiming Memory")
                            .font(.rounded(18, .semibold))
                        Text("macOS is releasing inactive memory. Geraldine will show a result only after the command returns.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    case .done:
                        if freed > 0 {
                            HStack(spacing: 5) {
                                Text("Freed")
                                AnimatedNumberText(Fmt.size(freed), value: freed)
                            }
                            .font(.rounded(22, .bold))
                        } else {
                            Text("Memory Optimized").font(.rounded(22, .bold))
                        }
                        HStack(spacing: 4) {
                            Text("Now")
                            AnimatedNumberText(Fmt.size(monitor.memoryUsed), value: monitor.memoryUsed)
                            Text("in use.")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Button("Done") { dismiss() }
                            .buttonStyle(.soft(Theme.good))
                    case .failed:
                        Text("Couldn't Free Memory").font(.rounded(20, .semibold))
                        Text("The action was cancelled or denied. No successful result was recorded.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Close") { dismiss() }
                            .buttonStyle(.soft(Theme.bad))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(width: 380)
        .frame(minHeight: 310)
    }

    private func run() {
        guard phase == .ready else { return }
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

/// A fixed-footprint workflow mark whose memory chip never gets replaced.
/// Only the surrounding activity arc and the local result treatment change.
private struct MemoryChipWorkflowMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let phase: FreeRAMView.Phase
    var size: CGFloat

    @State private var arcRotated = false
    @State private var arcGeneration = 0

    private var isWorking: Bool { phase == .working }
    private var isResult: Bool { phase == .done || phase == .failed }
    private var motionDisabled: Bool { reduceMotion || !surfaceActive }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.decorativeFill(resultTint ?? Theme.accent, strength: .subtle))

            Circle()
                .stroke(Theme.separator, lineWidth: 2)
                .padding(4)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    AngularGradient(
                        colors: [Theme.accent.opacity(0.05), Theme.accent],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(arcRotated ? 270 : -90))
                .opacity(isWorking ? 1 : 0)
                .padding(4)

            Circle()
                .stroke(resultTint ?? .clear, lineWidth: 3)
                .scaleEffect(isResult ? 1 : 0.88)
                .opacity(isResult ? 0.46 : 0)
                .padding(4)

            ModuleGlyph(systemImage: "memorychip", tint: Theme.accent, size: size * 0.63)

            ZStack {
                resultBadge(icon: "checkmark", tint: Theme.good, isVisible: phase == .done)
                resultBadge(icon: "xmark", tint: Theme.bad, isVisible: phase == .failed)
            }
            .offset(x: size * 0.34, y: size * 0.34)
        }
        .frame(width: size, height: size)
        .animation(
            GeraldineMotion.animation(.gentleSpring, reduceMotion: motionDisabled),
            value: phase
        )
        .onAppear(perform: updateActivityArc)
        .onDisappear {
            arcGeneration &+= 1
            arcRotated = false
        }
        .onChange(of: phase) { _, _ in updateActivityArc() }
        .onChange(of: surfaceActive) { _, _ in updateActivityArc() }
        .onChange(of: reduceMotion) { _, _ in updateActivityArc() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resultTint: Color? {
        switch phase {
        case .done: Theme.good
        case .failed: Theme.bad
        case .ready, .working: nil
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .ready: "Memory cleanup ready"
        case .working: "Reclaiming memory"
        case .done: "Memory cleanup complete"
        case .failed: "Memory cleanup failed"
        }
    }

    private func resultBadge(icon: String, tint: Color, isVisible: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Theme.surfaceRaised)
                .shadow(color: tint.opacity(0.18), radius: 4, y: 2)
            Image(systemName: icon)
                .font(.system(size: size * 0.13, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size * 0.28, height: size * 0.28)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(motionDisabled || isVisible ? 1 : GeraldineMotion.iconSwapScale)
        .blur(radius: motionDisabled || isVisible ? 0 : GeraldineMotion.iconSwapBlur)
    }

    private func updateActivityArc() {
        arcGeneration &+= 1
        let generation = arcGeneration
        guard isWorking, !motionDisabled else {
            arcRotated = false
            return
        }
        arcRotated = false
        DispatchQueue.main.async {
            guard generation == arcGeneration,
                  isWorking, !motionDisabled,
                  let animation = GeraldineMotion.spinner(reduceMotion: false) else { return }
            withAnimation(animation) {
                arcRotated = true
            }
        }
    }
}
