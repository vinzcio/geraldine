import AppKit
import SwiftUI

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var consumers: [ProcUsage] = []
    @Published var sortByMemory = false
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?
    private var lifecycleID = UUID()

    var sorted: [ProcUsage] {
        // Rank the whole sampled pool by the active metric before trimming, so Memory
        // mode surfaces true memory hogs rather than only the CPU-ranked head.
        let ranked = sortByMemory ? consumers.sorted { $0.mem > $1.mem } : consumers.sorted { $0.cpu > $1.cpu }
        return Array(ranked.prefix(8))
    }

    func start() {
        timer?.invalidate()
        stopSampling()
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = 1
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopSampling()
    }

    private func sample() {
        guard sampleTask == nil else { return }
        let lifecycleID = self.lifecycleID
        sampleTask = Task { [weak self] in
            let procs = await Task.detached { ProcessSampler.sample() }.value
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleID == lifecycleID else { return }
            self.consumers = procs
            self.sampleTask = nil
        }
    }

    private func stopSampling() {
        lifecycleID = UUID()
        sampleTask?.cancel()
        sampleTask = nil
    }
}

struct ActivityView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @StateObject private var vm = ActivityViewModel()

    var body: some View {
        ModulePage(module: .activity, headerStyle: .data, widthRole: .fluid) {
            graphCard("CPU", systemImage: "cpu",
                      value: Fmt.percent(monitor.cpuUsage),
                      valueAnimationValue: monitor.cpuUsage * 100,
                      history: monitor.cpuHistory,
                      tint: MetricPresentationPolicy.usageReadoutColor(monitor.cpuUsage),
                      chartTint: Theme.Chart.status(for: monitor.cpuUsage),
                      footnote: String(format: "Load Average %.2f", monitor.loadAverage),
                      footnoteAnimationValue: monitor.loadAverage)

            graphCard("Memory", systemImage: "memorychip",
                      value: Fmt.percent(monitor.memoryFraction),
                      valueAnimationValue: monitor.memoryFraction * 100,
                      history: monitor.memHistory,
                      tint: MetricPresentationPolicy.usageReadoutColor(monitor.memoryFraction),
                      chartTint: Theme.Chart.status(for: monitor.memoryFraction),
                      footnote: "\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal)) used",
                      footnoteAnimationValue: monitor.memoryUsed)

            temperatureCard

            HStack(spacing: Theme.Spacing.md) {
                miniCard("Uptime", SystemMonitor.uptimeString(monitor.uptime), "clock.arrow.circlepath",
                         animationValue: Double(monitor.uptime))
                miniCard("Load", String(format: "%.2f", monitor.loadAverage), "speedometer",
                         animationValue: monitor.loadAverage)
            }

            topConsumers
        }
        .onAppear { if surfaceActive { vm.start() } }
        .onDisappear { vm.stop() }
        .onChange(of: surfaceActive) { _, isActive in
            isActive ? vm.start() : vm.stop()
        }
    }

    private func graphCard(_ title: String, systemImage: String, value: String, valueAnimationValue: Double,
                           history: [MetricSample], tint: Color, chartTint: Color,
                           footnote: String, footnoteAnimationValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage).font(.rounded(14, .semibold))
                Spacer()
                AnimatedNumberText(value, value: valueAnimationValue)
                    .font(.rounded(22, .bold)).monospacedDigit().foregroundStyle(tint)
            }
            TimelineSparkGraph(samples: history,
                               window: SystemMonitor.liveHistoryWindow,
                               now: Date(),
                               tint: chartTint,
                               gradient: MetricPresentationPolicy.usageGradient,
                               domain: MetricChartStyle.normalizedDomain,
                               sampleColor: MetricPresentationPolicy.usageChartColor,
                               gapThreshold: SystemMonitor.chartSampleGapThreshold,
                               maximumPointCount: 300,
                               inspectionValueFormatter: { Fmt.percent($0) },
                               inspectionAccessibilityLabel: "\(title) usage history")
                .frame(height: 88)
            AnimatedNumberText(footnote, value: footnoteAnimationValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(tier: .raised, cornerRadius: Theme.Radius.raised)
    }

    @ViewBuilder private var temperatureCard: some View {
        let th = monitor.thermal
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Temperature", systemImage: "thermometer.medium").font(.rounded(14, .semibold))
                Spacer()
                if th.available {
                    AnimatedNumberText("\(Int(th.cpu.rounded()))°C", value: th.cpu)
                        .font(.rounded(26, .bold))
                        .foregroundStyle(Thermal.readoutColor(th.cpu))
                } else {
                    Text("N/A").font(.callout).foregroundStyle(.secondary)
                }
            }
            if th.available {
                if th.hidCPUCandidateCount > 0 {
                    AnimatedNumberText("\(th.cpuSource) · HID peak \(Int(th.cpuPeak.rounded()))°C · avg \(Int(th.cpuAverage.rounded()))°C across \(th.hidCPUCandidateCount) HID CPU \(th.hidCPUCandidateCount == 1 ? "sensor" : "sensors")",
                                       value: th.cpuPeak)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(th.cpuSource)
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    tempChip("Sensor Peak", th.peak)
                    if let b = th.battery { tempChip("Battery", b) }
                    if let s = th.storage { tempChip("Storage", s) }
                }
                DisclosureGroup("All Sensors") {
                    VStack(spacing: 0) {
                        ForEach(th.sensors) { s in
                            HStack {
                                Text(s.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                AnimatedNumberText("\(Int(s.temp.rounded()))°C", value: s.temp)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption.weight(.medium)).tint(Theme.accent)
            } else {
                Text("Temperature sensors aren't available on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(tier: .raised, cornerRadius: Theme.Radius.raised)
    }

    private func tempChip(_ label: String, _ temp: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            AnimatedNumberText("\(Int(temp.rounded()))°C", value: temp)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }

    private func miniCard(_ title: String, _ value: String, _ icon: String, animationValue: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(Module.activity.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                AnimatedNumberText(value, value: animationValue)
                    .font(.rounded(16, .semibold))
            }
            Spacer()
        }
        .card(tier: .base)
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Top Consumers")
                Picker("", selection: $vm.sortByMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            VStack(spacing: 0) {
                ForEach(Array(vm.sorted.enumerated()), id: \.element.id) { idx, p in
                    CareLedgerRow(
                        tint: Module.activity.tint,
                        title: p.name,
                        detail: vm.sortByMemory ? "Memory share" : "CPU share"
                    ) {
                        ProcessIconPlate(pid: p.id, tint: Module.activity.tint)
                    } accessory: {
                        AnimatedNumberText(String(format: "%.1f%%", vm.sortByMemory ? p.mem : p.cpu),
                                           value: vm.sortByMemory ? p.mem : p.cpu)
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    if idx < vm.sorted.count - 1 { Divider() }
                }
                if vm.sorted.isEmpty {
                    Text("Sampling…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            .card(tier: .base)
        }
    }
}

/// A running process's app icon on the neutral plate used for third-party apps.
/// Daemons and helpers without a bundle icon fall back to the module glyph.
struct ProcessIconPlate: View {
    let pid: Int32
    var tint: Color
    var symbol: String = "app.fill"
    var size: CGFloat = 34

    var body: some View {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            AppIconPlate(size: size) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
        } else {
            ModuleGlyph(systemImage: symbol, tint: tint, size: size)
        }
    }
}
