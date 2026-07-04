import SwiftUI

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var consumers: [ProcUsage] = []
    @Published var sortByMemory = false
    private var timer: Timer?

    var sorted: [ProcUsage] {
        sortByMemory ? consumers.sorted { $0.mem > $1.mem } : consumers.sorted { $0.cpu > $1.cpu }
    }

    func start() {
        sample()
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        t.tolerance = 1
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        Task {
            let procs = await Task.detached { ProcessSampler.sample(limit: 8) }.value
            self.consumers = procs
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var monitor: SystemMonitor
    @StateObject private var vm = ActivityViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ModuleHeader(module: .activity)
                    .padding(.horizontal, -26)   // header has its own padding

                graphCard("CPU", systemImage: "cpu",
                          value: Fmt.percent(monitor.cpuUsage),
                          valueAnimationValue: monitor.cpuUsage * 100,
                          history: monitor.cpuHistory,
                          tint: Theme.status(for: monitor.cpuUsage),
                          footnote: String(format: "Load Average %.2f", monitor.loadAverage),
                          footnoteAnimationValue: monitor.loadAverage)

                graphCard("Memory", systemImage: "memorychip",
                          value: Fmt.percent(monitor.memoryFraction),
                          valueAnimationValue: monitor.memoryFraction * 100,
                          history: monitor.memHistory,
                          tint: Theme.status(for: monitor.memoryFraction),
                          footnote: "\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal)) used",
                          footnoteAnimationValue: monitor.memoryUsed)

                temperatureCard

                HStack(spacing: 16) {
                    miniCard("Uptime", SystemMonitor.uptimeString(monitor.uptime), "clock.arrow.circlepath",
                             animationValue: Double(monitor.uptime))
                    miniCard("Load", String(format: "%.2f", monitor.loadAverage), "speedometer",
                             animationValue: monitor.loadAverage)
                }

                topConsumers
            }
            .padding(26)
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private func graphCard(_ title: String, systemImage: String, value: String, valueAnimationValue: Double,
                           history: [Double], tint: Color, footnote: String, footnoteAnimationValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage).font(.rounded(14, .semibold))
                Spacer()
                AnimatedNumberText(value, value: valueAnimationValue)
                    .font(.rounded(22, .bold)).monospacedDigit().foregroundStyle(tint)
            }
            SparkGraph(values: history, tint: tint).frame(height: 88)
            AnimatedNumberText(footnote, value: footnoteAnimationValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    @ViewBuilder private var temperatureCard: some View {
        let th = monitor.thermal
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Temperature", systemImage: "thermometer.medium").font(.rounded(14, .semibold))
                Spacer()
                if th.available {
                    AnimatedNumberText("\(Int(th.cpu.rounded()))°C", value: th.cpu)
                        .font(.rounded(26, .bold))
                        .foregroundStyle(Thermal.color(th.cpu))
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
                                    .foregroundStyle(Thermal.color(s.temp))
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
        .card()
    }

    private func tempChip(_ label: String, _ temp: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            AnimatedNumberText("\(Int(temp.rounded()))°C", value: temp)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Thermal.color(temp))
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
        .card()
    }

    private var topConsumers: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    HStack(spacing: 10) {
                        Text(p.name).lineLimit(1)
                        Spacer()
                        AnimatedNumberText(String(format: "%.1f%%", vm.sortByMemory ? p.mem : p.cpu),
                                           value: vm.sortByMemory ? p.mem : p.cpu)
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    if idx < vm.sorted.count - 1 { Divider() }
                }
                if vm.sorted.isEmpty {
                    Text("Sampling…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
            }
            .card()
        }
    }
}
