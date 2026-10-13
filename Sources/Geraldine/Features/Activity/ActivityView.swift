import AppKit
import SwiftUI

@MainActor
final class ActivityViewModel: ObservableObject {
    @Published var consumers: [ProcUsage] = []
    @Published var sortByMemory = false
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?
    private var lifecycleID = UUID()

    @Published var query = ""
    @Published var showsAll = false
    @Published private(set) var hasSampled = false

    var groups: [ProcessGroup] {
        ProcessGroup.ranked(consumers, byMemory: sortByMemory, query: query)
    }

    var visibleGroups: [ProcessGroup] {
        showsAll || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? groups : Array(groups.prefix(8))
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
            self.hasSampled = true
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
    @EnvironmentObject var state: AppState
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @StateObject private var vm = ActivityViewModel()
    @State private var inspectionTime: TimeInterval?
    @State private var selectedGroup: ProcessGroup?

    private var chartNow: Date { monitor.memHistory.last?.date ?? Date() }

    var body: some View {
        ScrollViewReader { proxy in
            ModulePage(module: .activity, headerStyle: .data, widthRole: .fluid) {
                Text("Hover or drag a chart to compare the same time across CPU, GPU, and memory. Use arrow keys when a chart is focused.")
                    .font(.caption).foregroundStyle(.secondary)
                graphCard("CPU", systemImage: "cpu",
                          value: Fmt.percent(monitor.cpuUsage),
                          valueAnimationValue: monitor.cpuUsage * 100,
                          history: monitor.cpuHistory,
                          tint: MetricPresentationPolicy.usageReadoutColor(monitor.cpuUsage),
                          chartTint: Theme.Chart.status(for: monitor.cpuUsage),
                          footnote: String(format: "Load Average %.2f", monitor.loadAverage),
                          footnoteAnimationValue: monitor.loadAverage)
                    .id(ActivitySection.cpu)

                gpuCard.id(ActivitySection.gpu)

                graphCard("Memory", systemImage: "memorychip",
                          value: Fmt.percent(monitor.memoryFraction),
                          valueAnimationValue: monitor.memoryFraction * 100,
                          history: monitor.memHistory,
                          tint: MetricPresentationPolicy.usageReadoutColor(monitor.memoryFraction),
                          chartTint: Theme.Chart.status(for: monitor.memoryFraction),
                          footnote: "\(Fmt.size(monitor.memoryUsed)) of \(Fmt.size(monitor.memoryTotal)) used",
                          footnoteAnimationValue: monitor.memoryUsed)
                    .id(ActivitySection.memory)

                temperatureCard

                HStack(spacing: Theme.Spacing.md) {
                    miniCard("Uptime", SystemMonitor.uptimeString(monitor.uptime), "clock.arrow.circlepath",
                             animationValue: Double(monitor.uptime))
                    miniCard("Load", String(format: "%.2f", monitor.loadAverage), "speedometer",
                             animationValue: monitor.loadAverage)
                }

                topConsumers.id(ActivitySection.processes)
            }
            .onAppear {
                if surfaceActive { vm.start() }
                proxy.scrollTo(state.activitySection, anchor: .top)
                if state.activitySection == .memory { vm.sortByMemory = true }
            }
            .onChange(of: state.activityNavigationID) { _, _ in
                let section = state.activitySection
                proxy.scrollTo(section, anchor: .top)
                if section == .memory { vm.sortByMemory = true }
                if section == .cpu { vm.sortByMemory = false }
            }
            .onDisappear { vm.stop(); inspectionTime = nil }
            .onChange(of: surfaceActive) { _, isActive in
                isActive ? vm.start() : vm.stop()
                if !isActive { inspectionTime = nil }
            }
        }
        .sheet(item: $selectedGroup) { selected in
            ProcessDetailView(group: vm.groups.first { $0.id == selected.id } ?? selected,
                              isCurrent: vm.groups.contains { $0.id == selected.id })
        }
    }

    @ViewBuilder private var gpuCard: some View {
        if monitor.gpuHistory.devices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("GPU Activity", systemImage: MetricKind.gpu.icon).font(.rounded(14, .semibold))
                Text("GPU activity isn't available from macOS right now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card(tier: .raised, cornerRadius: Theme.Radius.raised)
        }
        ForEach(monitor.gpuHistory.devices) { device in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("GPU Activity", systemImage: MetricKind.gpu.icon).font(.rounded(14, .semibold))
                    Spacer()
                    if let activity = device.activity {
                        AnimatedNumberText(Fmt.percent(activity), value: activity * 100)
                            .font(.rounded(22, .bold)).monospacedDigit()
                            .foregroundStyle(MetricPresentationPolicy.usageReadoutColor(activity))
                    } else {
                        Text(device.state.rawValue).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if device.samples.isEmpty && device.state != .available {
                    Text("No activity history")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 88)
                } else {
                    TimelineSparkGraph(samples: device.samples,
                                       window: SystemMonitor.liveHistoryWindow,
                                       now: chartNow,
                                       tint: device.activity.map(MetricPresentationPolicy.usageChartColor) ?? .secondary,
                                       gradient: MetricChartStyle.gradient(for: .gpu),
                                       domain: MetricChartStyle.normalizedDomain,
                                       sampleColor: MetricPresentationPolicy.usageChartColor,
                                       showsLatestEndpoint: device.state == .available,
                                       gapThreshold: SystemMonitor.chartSampleGapThreshold,
                                       maximumPointCount: 300,
                                       inspectionValueFormatter: { Fmt.percent($0) },
                                       inspectionAccessibilityLabel: "\(device.displayName) GPU activity history",
                                       inspectionTime: $inspectionTime)
                        .frame(height: 88)
                }
                Text(device.displayName)
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Activity reported by this graphics processor, not a measurement of how many GPU cores are fully occupied.")
            }
            .card(tier: .raised, cornerRadius: Theme.Radius.raised)
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
                               now: chartNow,
                               tint: chartTint,
                               gradient: MetricPresentationPolicy.usageGradient,
                               domain: MetricChartStyle.normalizedDomain,
                               sampleColor: MetricPresentationPolicy.usageChartColor,
                               gapThreshold: SystemMonitor.chartSampleGapThreshold,
                               maximumPointCount: 300,
                               inspectionValueFormatter: { Fmt.percent($0) },
                               inspectionAccessibilityLabel: "\(title) usage history",
                               inspectionTime: $inspectionTime)
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
            } else if !th.sensors.isEmpty {
                Text("CPU temperature is unavailable. Other sensor readings are shown below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !th.sensors.isEmpty {
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
        let groups = vm.visibleGroups
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("Apps & Processes")
                Spacer()
                Picker("Rank by", selection: $vm.sortByMemory) {
                    Text("CPU").tag(false)
                    Text("Memory").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 180)
            }
            TextField("Search sampled apps, processes, or PID", text: $vm.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search sampled processes")
            Text("Top sampled processes, grouped by app. Totals include only sampled helpers; CPU can exceed 100% across cores.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Button { selectedGroup = group } label: {
                        CareLedgerRow(
                            tint: Module.activity.tint,
                            title: group.name,
                            detail: "\(group.processes.count) sampled \(group.processes.count == 1 ? "process" : "processes")"
                        ) {
                            ProcessIconPlate(pid: group.representativePID ?? 0, tint: Module.activity.tint)
                        } accessory: {
                            HStack(spacing: 8) {
                                Text(String(format: "%.1f%%", vm.sortByMemory ? group.memory : group.cpu))
                                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Inspect sampled processes for \(group.name)")
                    if group.id != groups.last?.id { Divider() }
                }
                if groups.isEmpty {
                    Text(!vm.hasSampled ? "Sampling…" : vm.query.isEmpty
                         ? "No process samples available." : "No sampled processes match your search.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                }
            }
            .card(tier: .base)
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.groups.count > 8 {
                Button(vm.showsAll ? "Show top eight" : "Show all \(vm.groups.count) sampled apps & processes") {
                    vm.showsAll.toggle()
                }
                .buttonStyle(.quiet(Module.activity.tint))
            }
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
