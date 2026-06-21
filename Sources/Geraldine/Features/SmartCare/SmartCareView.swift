import SwiftUI

struct Finding: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var severity: Severity
    var module: Module?

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
}

@MainActor
final class SmartCareViewModel: ObservableObject {
    enum Phase { case idle, scanning, results }
    @Published var phase: Phase = .idle
    @Published var score = 100
    @Published var findings: [Finding] = []

    var healthLabel: String {
        switch score { case 85...: return "Great"; case 60..<85: return "Fair"; default: return "Needs attention" }
    }
    var healthColor: Color {
        switch score { case 85...: return Theme.good; case 60..<85: return Theme.warn; default: return Theme.bad }
    }

    func scan() {
        phase = .scanning
        let diskFraction = AppState.shared.monitor.diskFraction
        let memFraction = AppState.shared.monitor.memoryFraction
        let diskFree = max(0, AppState.shared.monitor.diskTotal - AppState.shared.monitor.diskUsed)
        Task {
            let extras = await Self.gather()
            var results: [Finding] = []

            // Disk
            if diskFraction > 0.9 {
                results.append(Finding(title: "Low on disk space",
                    detail: "Only \(Fmt.size(diskFree)) free. Clean up to make room.",
                    severity: .bad, module: .cleanup))
            } else {
                results.append(Finding(title: "Plenty of disk space",
                    detail: "\(Fmt.size(diskFree)) free.", severity: .good))
            }

            // Junk
            if extras.junk > 2_000_000_000 {
                results.append(Finding(title: "\(Fmt.size(extras.junk)) of junk to clear",
                    detail: "Caches, logs and Trash you can safely remove.",
                    severity: .warn, module: .cleanup))
            } else {
                results.append(Finding(title: "Little junk to clean",
                    detail: "Only \(Fmt.size(extras.junk)) of caches and logs.", severity: .good))
            }

            // Memory
            if memFraction > 0.85 {
                results.append(Finding(title: "Memory is running high",
                    detail: "\(Fmt.percent(memFraction)) in use. Free up inactive memory.",
                    severity: .warn, module: .activity))
            } else {
                results.append(Finding(title: "Memory looks healthy",
                    detail: "\(Fmt.percent(memFraction)) in use.", severity: .good))
            }

            // Startup items
            if extras.startupItems > 8 {
                results.append(Finding(title: "\(extras.startupItems) startup items",
                    detail: "Lots of apps launch at login. Review them to speed up boot.",
                    severity: .warn, module: .loginItems))
            } else {
                results.append(Finding(title: "Startup is lean",
                    detail: "\(extras.startupItems) login items.", severity: .good))
            }

            let penalty = results.reduce(0) { $0 + $1.severity.penalty }
            self.findings = results.sorted { $0.severity.penalty > $1.severity.penalty }
            self.score = max(5, 100 - penalty)
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

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .smartCare) {
                if vm.phase == .results {
                    Button { vm.scan() } label: { Label("Scan again", systemImage: "arrow.clockwise") }
                }
            }

            switch vm.phase {
            case .idle:
                VStack(spacing: 18) {
                    Spacer()
                    ZStack {
                        Circle().fill(Theme.accent.opacity(0.12)).frame(width: 120, height: 120)
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 52, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    Text("Smart Care").font(.rounded(24, .bold))
                    Text("One tap checks your disk, memory, junk, and startup items — then tells you exactly what to tidy.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    PrimaryButton(title: "Run Smart Care", icon: "sparkles", action: vm.scan)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .scanning:
                ScanningState(tint: Theme.accent, label: "Checking your Mac…")

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

                        VStack(spacing: 10) {
                            ForEach(vm.findings) { finding in
                                FindingRow(finding: finding) {
                                    if let m = finding.module { state.selection = m }
                                }
                            }
                        }
                    }
                    .padding(26)
                }
            }
        }
        .onAppear { if vm.phase == .idle { vm.scan() } }
    }
}

private struct FindingRow: View {
    var finding: Finding
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: finding.severity.icon).font(.title3).foregroundStyle(finding.severity.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.title).font(.rounded(14, .semibold))
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let module = finding.module {
                Button(action: action) {
                    Text(module == .cleanup ? "Clean" : "Open").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(finding.severity.color)
            }
        }
        .card(padding: 14)
    }
}
