import SwiftUI

struct Finding: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var scope: String
    var confidence: Confidence
    var severity: Severity
    var module: Module?
    var actionTitle: String?
    var actionIcon: String

    var isActionable: Bool { module != nil && severity != .good }

    enum Severity {
        case good, warn, bad
        var icon: String {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .bad:  return "exclamationmark.octagon.fill"
            }
        }
        var color: Color {
            switch self {
            case .good: return Theme.good
            case .warn: return Theme.warn
            case .bad:  return Theme.bad
            }
        }
        var penalty: Int {
            switch self { case .good: return 0; case .warn: return 8; case .bad: return 18 }
        }
    }

    enum Confidence {
        case high, medium, limited

        var label: String {
            switch self {
            case .high: return "High Confidence"
            case .medium: return "Medium Confidence"
            case .limited: return "Limited Confidence"
            }
        }

        var color: Color {
            switch self {
            case .high: return Theme.good
            case .medium: return Theme.warn
            case .limited: return Color.secondary
            }
        }
    }
}

@MainActor
final class SmartCareViewModel: ObservableObject {
    enum Phase { case idle, scanning, results }
    @Published var phase: Phase = .idle
    @Published var score = 100
    @Published var findings: [Finding] = []
    @Published var scanDate: Date?

    var healthLabel: String {
        switch score { case 85...: return "Great"; case 60..<85: return "Fair"; default: return "Needs Attention" }
    }
    var healthColor: Color {
        switch score { case 85...: return Theme.good; case 60..<85: return Theme.warn; default: return Theme.bad }
    }
    var actionableFindings: [Finding] {
        findings.filter(\.isActionable)
    }
    var freshnessText: String {
        guard let scanDate else { return "Not Scanned Yet" }
        return "Scanned At \(DateFormatter.localizedString(from: scanDate, dateStyle: .none, timeStyle: .short))"
    }

    func scan() {
        phase = .scanning
        scanDate = nil
        let diskFraction = AppState.shared.monitor.diskFraction
        let memFraction = AppState.shared.monitor.memoryFraction
        let diskTotal = AppState.shared.monitor.diskTotal
        let diskFree = max(0, diskTotal - AppState.shared.monitor.diskUsed)
        Task {
            let extras = await Self.gather()
            var results: [Finding] = []

            if diskTotal <= 0 {
                results.append(Finding(
                    title: "Disk Capacity Was Not Available",
                    detail: "macOS did not return a usable volume total for this pass.",
                    scope: "Live APFS capacity from the startup volume.",
                    confidence: .limited,
                    severity: .warn,
                    module: .storage,
                    actionTitle: "Open Storage",
                    actionIcon: "chart.pie.fill"
                ))
            } else if diskFraction > 0.9 {
                results.append(Finding(
                    title: "Low On Disk Space",
                    detail: "Only \(Fmt.size(diskFree)) free. Review storage first, then clean selected items.",
                    scope: "Live free space on the startup volume.",
                    confidence: .high,
                    severity: .bad,
                    module: .storage,
                    actionTitle: "Review Storage",
                    actionIcon: "chart.pie.fill"
                ))
            } else {
                results.append(Finding(
                    title: "Plenty Of Disk Space",
                    detail: "\(Fmt.size(diskFree)) free on the startup volume.",
                    scope: "Live free space on the startup volume.",
                    confidence: .high,
                    severity: .good,
                    module: nil,
                    actionTitle: nil,
                    actionIcon: "chart.pie.fill"
                ))
            }

            if extras.junk > 2_000_000_000 {
                results.append(Finding(
                    title: "\(Fmt.size(extras.junk)) Of Reviewable Junk",
                    detail: "Caches, logs, and Trash can be reviewed before Geraldine moves or deletes anything.",
                    scope: "~/Library/Caches, ~/Library/Logs, and ~/.Trash.",
                    confidence: .medium,
                    severity: .warn,
                    module: .cleanup,
                    actionTitle: "Review Cleanup",
                    actionIcon: "sparkles"
                ))
            } else {
                results.append(Finding(
                    title: "Little Junk To Clean",
                    detail: "Only \(Fmt.size(extras.junk)) found in the standard cleanup locations.",
                    scope: "~/Library/Caches, ~/Library/Logs, and ~/.Trash.",
                    confidence: .medium,
                    severity: .good,
                    module: nil,
                    actionTitle: nil,
                    actionIcon: "sparkles"
                ))
            }

            if memFraction > 0.85 {
                results.append(Finding(
                    title: "Memory Is Running High",
                    detail: "\(Fmt.percent(memFraction)) is in use. Check heavy apps before freeing inactive memory.",
                    scope: "Live memory pressure from Geraldine's system monitor.",
                    confidence: .high,
                    severity: .warn,
                    module: .activity,
                    actionTitle: "Open Activity",
                    actionIcon: "waveform.path.ecg"
                ))
            } else {
                results.append(Finding(
                    title: "Memory Looks Healthy",
                    detail: "\(Fmt.percent(memFraction)) is in use.",
                    scope: "Live memory pressure from Geraldine's system monitor.",
                    confidence: .high,
                    severity: .good,
                    module: nil,
                    actionTitle: nil,
                    actionIcon: "waveform.path.ecg"
                ))
            }

            if extras.startupItems > 8 {
                results.append(Finding(
                    title: "\(extras.startupItems) User Launch Agents",
                    detail: "A larger login footprint can slow startup. Open Login Items for the reviewable controls.",
                    scope: "~/Library/LaunchAgents plist count; system launch daemons are not changed here.",
                    confidence: .medium,
                    severity: .warn,
                    module: .loginItems,
                    actionTitle: "Review Startup",
                    actionIcon: "power"
                ))
            } else {
                results.append(Finding(
                    title: "Startup Is Lean",
                    detail: "\(extras.startupItems) user launch agents found.",
                    scope: "~/Library/LaunchAgents plist count; system launch daemons are not changed here.",
                    confidence: .medium,
                    severity: .good,
                    module: nil,
                    actionTitle: nil,
                    actionIcon: "power"
                ))
            }

            let penalty = results.reduce(0) { $0 + $1.severity.penalty }
            self.findings = results.sorted { $0.severity.penalty > $1.severity.penalty }
            self.score = max(5, 100 - penalty)
            self.scanDate = Date()
            self.phase = .results
        }
    }

    private struct Extras { var junk: UInt64; var startupItems: Int }

    private static func gather() async -> Extras {
        await Task.detached(priority: .userInitiated) { () -> Extras in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let junk = DiskScan.size(of: home.appendingPathComponent("Library/Caches"))
                + DiskScan.size(of: home.appendingPathComponent("Library/Logs"))
                + DiskScan.size(of: home.appendingPathComponent(".Trash"))
            let agents = (try? FileManager.default.contentsOfDirectory(
                at: home.appendingPathComponent("Library/LaunchAgents"),
                includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "plist" }.count ?? 0
            return Extras(junk: junk, startupItems: agents)
        }.value
    }
}

struct SmartCareView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = SmartCareViewModel()
    @State private var queuedFindingIDs = Set<UUID>()

    private var queuedFindings: [Finding] {
        vm.findings.filter { queuedFindingIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .smartCare) {
                if vm.phase == .results {
                    Button { rescan() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                }
            }

            switch vm.phase {
            case .idle:
                VStack(spacing: 18) {
                    Spacer()
                    IconBadge(icon: "checkmark.seal.fill", tint: Theme.accent, size: 120)
                    Text("Smart Care").font(.rounded(24, .bold))
                    Text("One tap checks live disk space, memory pressure, user caches, logs, Trash, and user launch agents. It suggests review routes; it does not clean anything without you opening the target module.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 500)
                    PrimaryButton(title: "Run Smart Care", icon: "sparkles", action: rescan)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .scanning:
                ScanningState(tint: Theme.accent, icon: "checkmark.seal.fill", label: "Checking your Mac…")

            case .results:
                ScrollView {
                    VStack(spacing: 22) {
                        GaugeRing(value: Double(vm.score) / 100, lineWidth: 14, tint: vm.healthColor) {
                            VStack(spacing: 0) {
                                Text("\(vm.score)").font(.rounded(40, .bold))
                                Text("/ 100").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 180, height: 180)
                        .padding(.top, 8)

                        Text("Mac Health: \(vm.healthLabel)")
                            .font(.rounded(20, .semibold)).foregroundStyle(vm.healthColor)

                        SmartCareScanSummary(freshness: vm.freshnessText,
                                             actionableCount: vm.actionableFindings.count)

                        if !queuedFindings.isEmpty {
                            QueuedActionsCard(findings: queuedFindings,
                                              openFirst: openFirstQueuedAction,
                                              clear: { queuedFindingIDs.removeAll() })
                        }

                        VStack(spacing: 10) {
                            ForEach(vm.findings) { finding in
                                FindingRow(finding: finding,
                                           isQueued: queuedFindingIDs.contains(finding.id),
                                           toggleQueue: { toggleQueue(for: finding) },
                                           action: { open(finding) })
                            }
                        }
                    }
                    .padding(26)
                }
            }
        }
        .onAppear { if vm.phase == .idle { rescan() } }
    }

    private func rescan() {
        queuedFindingIDs.removeAll()
        vm.scan()
    }

    private func toggleQueue(for finding: Finding) {
        guard finding.isActionable else { return }
        if queuedFindingIDs.contains(finding.id) {
            queuedFindingIDs.remove(finding.id)
        } else {
            queuedFindingIDs.insert(finding.id)
        }
    }

    private func open(_ finding: Finding) {
        guard let module = finding.module else { return }
        state.selection = module
    }

    private func openFirstQueuedAction() {
        guard let first = queuedFindings.first else { return }
        open(first)
    }
}

private struct SmartCareScanSummary: View {
    var freshness: String
    var actionableCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(freshness, systemImage: "clock")
                Spacer()
                Label("\(actionableCount) Next Step\(actionableCount == 1 ? "" : "s")", systemImage: "list.bullet.clipboard")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 6) {
                Label("Scope: startup volume capacity, live memory, user caches/logs/Trash, and user LaunchAgents.", systemImage: "scope")
                Label("Confidence: high for live vitals, medium for best-effort file scans. Protected locations are skipped unless macOS allows access.", systemImage: "checkmark.shield")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .card(padding: 14)
    }
}

private struct QueuedActionsCard: View {
    var findings: [Finding]
    var openFirst: () -> Void
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Queued Next Steps", systemImage: "checklist")
                    .font(.rounded(14, .semibold))
                Spacer()
                Button("Clear", action: clear).font(.caption)
            }

            ForEach(findings) { finding in
                HStack(spacing: 8) {
                    Image(systemName: finding.actionIcon).foregroundStyle(finding.severity.color)
                    Text(finding.actionTitle ?? "Open").font(.caption.weight(.medium))
                    Text(finding.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
            }

            Button(action: openFirst) {
                Label("Open First Queued Step", systemImage: "arrow.forward.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .card(padding: 14)
    }
}

private struct FindingRow: View {
    var finding: Finding
    var isQueued: Bool
    var toggleQueue: () -> Void
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: finding.severity.icon)
                .font(.title3)
                .foregroundStyle(finding.severity.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(finding.title).font(.rounded(14, .semibold))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ConfidenceBadge(confidence: finding.confidence)
                    Text(finding.scope)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                if finding.isActionable {
                    HStack(spacing: 8) {
                        Button(action: toggleQueue) {
                            Label(isQueued ? "Queued" : "Queue", systemImage: isQueued ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .buttonStyle(.bordered)

                        Button(action: action) {
                            Label(finding.actionTitle ?? "Open", systemImage: finding.actionIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(finding.severity.color)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            Spacer(minLength: 8)
        }
        .card(padding: 14)
    }
}

private struct ConfidenceBadge: View {
    var confidence: Finding.Confidence

    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(confidence.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(confidence.color.opacity(0.12), in: Capsule())
    }
}
