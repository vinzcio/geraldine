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
    enum Phase: Hashable { case idle, scanning, results }
    @Published var phase: Phase = .idle
    @Published var score = 100
    @Published var findings: [Finding] = []
    @Published var scanDate: Date?
    private var scanID = UUID()

    var healthLabel: String {
        switch score { case 85...: return "Great"; case 60..<85: return "Fair"; default: return "Needs Attention" }
    }
    var actionableFindings: [Finding] {
        findings.filter(\.isActionable)
    }
    var freshnessText: String {
        guard let scanDate else { return "Not Scanned Yet" }
        return "Scanned At \(DateFormatter.localizedString(from: scanDate, dateStyle: .none, timeStyle: .short))"
    }

    func scan() {
        let id = UUID()
        scanID = id
        phase = .scanning
        scanDate = nil
        let diskFraction = AppState.shared.monitor.diskFraction
        let memFraction = AppState.shared.monitor.memoryFraction
        let diskTotal = AppState.shared.monitor.diskTotal
        let diskFree = max(0, diskTotal - AppState.shared.monitor.diskUsed)
        Task {
            let extras = await Self.gather()
            guard self.scanID == id else { return }
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
            } else if diskFraction > MetricAttentionPolicy.storageUsage {
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

            if memFraction > MetricAttentionPolicy.memoryUsage {
                results.append(Finding(
                    title: "Memory Is Running High",
                    detail: "\(Fmt.percent(memFraction)) is in use. Check heavy apps before freeing inactive memory.",
                    scope: "Live memory use from Geraldine's system monitor.",
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
                    scope: "Live memory use from Geraldine's system monitor.",
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @StateObject private var vm = SmartCareViewModel()
    @State private var queuedFindingIDs = Set<UUID>()
    @State private var displayedScore = 0
    @State private var showResultContext = false
    @State private var revealedFindingCount = 0
    @State private var resultRevealCompleted = false
    @State private var revealTask: Task<Void, Never>?

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

            WorkflowPhaseHost(phase: vm.phase == .idle) {
                switch vm.phase {
                case .idle:
                    VStack(spacing: 18) {
                        Spacer()
                        WorkflowMark(state: .idle, tint: Theme.accent,
                                     idleIcon: "checkmark.seal.fill", size: 120)
                        Text("Smart Care").font(.rounded(24, .bold))
                        Text("One tap checks live disk space, memory use, user caches, logs, Trash, and user launch agents. It suggests review routes; it does not clean anything without you opening the target module.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 500)
                        PrimaryButton(title: "Run Smart Care", icon: "sparkles", action: rescan)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .scanning, .results:
                    activeCareBody
                }
            }
        }
        .onAppear { if vm.phase == .idle { rescan() } }
        .onChange(of: vm.phase) { _, phase in
            if phase == .results {
                beginResultReveal()
            } else if phase == .scanning {
                resultRevealCompleted = false
            }
        }
        .onChange(of: reduceMotion) { _, _ in
            if vm.phase == .results, !resultRevealCompleted { finalizeResultReveal() }
        }
        .onChange(of: surfaceActive) { _, _ in
            if vm.phase == .results, !resultRevealCompleted { finalizeResultReveal() }
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
    }

    private var activeCareBody: some View {
        let scanning = vm.phase == .scanning
        return VStack(spacing: Theme.Spacing.md) {
            Color.clear
                .frame(height: scanning ? Theme.Spacing.xl : 0)
                .accessibilityHidden(true)

            SmartCareScoreHero(phase: scanning ? .scanning : .results,
                               displayedScore: scanning ? 0 : displayedScore,
                               score: vm.score,
                               tint: scanning
                                   ? Theme.Chart.purple
                                   : Theme.Chart.health(for: vm.score))
                .padding(.top, scanning ? 0 : Theme.Spacing.xs)

            if scanning {
                Text("Checking Your Mac")
                    .font(.rounded(17, .semibold))
                Text("Reading live vitals and the standard care locations. No cleanup action runs during this check.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                Spacer(minLength: Theme.Spacing.xl)
            } else {
                resultsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(GeraldineMotion.animation(.standard,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: scanning)
    }

    private var resultsContent: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if showResultContext {
                    Text("Mac Health: \(vm.healthLabel)")
                        .font(.rounded(20, .semibold))
                        .foregroundStyle(Theme.Chart.health(for: vm.score))
                        .transition(.opacity)

                    SmartCareScanSummary(freshness: vm.freshnessText,
                                         actionableCount: vm.actionableFindings.count)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    if !queuedFindings.isEmpty {
                        QueuedActionsCard(findings: queuedFindings,
                                          openFirst: openFirstQueuedAction,
                                          clear: clearQueue)
                            .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .clipped()
                .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
                           value: queuedFindingIDs.count)

                VStack(spacing: Theme.Spacing.xs) {
                    ForEach(Array(vm.findings.enumerated()), id: \.element.id) { index, finding in
                        FindingRow(finding: finding,
                                   isQueued: queuedFindingIDs.contains(finding.id),
                                   toggleQueue: { toggleQueue(for: finding) },
                                   action: { open(finding) })
                            .opacity(rowIsRevealed(index) ? 1 : 0)
                            .offset(y: reduceMotion || rowIsRevealed(index) ? 0 : 8)
                            .accessibilityHidden(!rowIsRevealed(index))
                            .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
                                       value: revealedFindingCount)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func rescan() {
        revealTask?.cancel()
        revealTask = nil
        queuedFindingIDs.removeAll()
        displayedScore = 0
        showResultContext = false
        revealedFindingCount = 0
        resultRevealCompleted = false
        vm.scan()
    }

    private func toggleQueue(for finding: Finding) {
        guard finding.isActionable else { return }
        withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
            if queuedFindingIDs.contains(finding.id) {
                queuedFindingIDs.remove(finding.id)
            } else {
                queuedFindingIDs.insert(finding.id)
            }
        }
    }

    private func clearQueue() {
        withAnimation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion)) {
            queuedFindingIDs.removeAll()
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

    private func rowIsRevealed(_ index: Int) -> Bool {
        let staggeredCount = min(vm.findings.count, 4)
        return index >= staggeredCount || index < revealedFindingCount
    }

    private func beginResultReveal() {
        revealTask?.cancel()
        revealTask = nil
        resultRevealCompleted = false
        displayedScore = reduceMotion ? vm.score : 0
        showResultContext = reduceMotion
        revealedFindingCount = reduceMotion ? vm.findings.count : 0
        guard !reduceMotion, surfaceActive else {
            finalizeResultReveal()
            return
        }

        let targetScore = vm.score
        let staggeredCount = min(vm.findings.count, 4)
        revealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            withAnimation(GeraldineMotion.animation(.emphasis, reduceMotion: false)) {
                displayedScore = targetScore
            }

            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled else { return }
            withAnimation(GeraldineMotion.animation(.standard, reduceMotion: false)) {
                showResultContext = true
            }

            if staggeredCount > 0 {
                for count in 1...staggeredCount {
                    try? await Task.sleep(for: .milliseconds(65))
                    guard !Task.isCancelled else { return }
                    revealedFindingCount = count
                }
            }
            resultRevealCompleted = true
            revealTask = nil
        }
    }

    private func finalizeResultReveal() {
        revealTask?.cancel()
        revealTask = nil
        withTransaction(Transaction(animation: nil)) {
            displayedScore = vm.score
            showResultContext = true
            revealedFindingCount = vm.findings.count
            resultRevealCompleted = true
        }
    }
}

private struct SmartCareScoreHero: View {
    enum Phase: Hashable { case scanning, results }

    let phase: Phase
    let displayedScore: Int
    let score: Int
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var scanRotation = -90.0
    @State private var sealBreathing = false

    private var isScanning: Bool { phase == .scanning }
    private var ringProgress: Double {
        if isScanning || displayedScore == 0 { return 0.28 }
        return max(0.001, min(1, Double(displayedScore) / 100))
    }

    private var ringStyle: AnyShapeStyle {
        if isScanning {
            return AnyShapeStyle(
                AngularGradient(colors: [tint.opacity(0), tint], center: .center)
            )
        }
        return AnyShapeStyle(tint.gradient)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 14)

            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(ringStyle,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(isScanning ? scanRotation : -90))
                .shadow(color: tint.opacity(isScanning ? 0.24 : 0.18), radius: 8)
                .animation(
                    isScanning && surfaceActive && !reduceMotion
                        ? GeraldineMotion.spinner(reduceMotion: false)
                        : GeraldineMotion.animation(.standard,
                                                    reduceMotion: reduceMotion || !surfaceActive),
                    value: scanRotation
                )
                .animation(GeraldineMotion.animation(.emphasis,
                                                      reduceMotion: reduceMotion || !surfaceActive),
                           value: ringProgress)

            if isScanning {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 47, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent.gradient)
                    .scaleEffect(reduceMotion || !surfaceActive ? 1 : (sealBreathing ? 1.04 : 0.96))
                    .animation(sealBreathing ? GeraldineMotion.breathing(reduceMotion: false) : nil,
                               value: sealBreathing)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                VStack(spacing: 0) {
                    AnimatedNumberText("\(displayedScore)", value: Double(displayedScore))
                        .font(.rounded(40, .bold))
                        .foregroundStyle(tint)
                    Text("/ 100").font(.caption).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 180, height: 180)
        .animation(GeraldineMotion.animation(.standard,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: phase)
        .onAppear { updateActivity() }
        .onDisappear {
            scanRotation = -90
            sealBreathing = false
        }
        .onChange(of: phase) { _, _ in updateActivity() }
        .onChange(of: reduceMotion) { _, _ in updateActivity() }
        .onChange(of: surfaceActive) { _, _ in updateActivity() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase == .scanning ? "Smart Care scan in progress" : "Mac health score")
        .accessibilityValue(phase == .results ? "\(score) out of 100" : "Checking")
    }

    private func updateActivity() {
        let shouldAnimate = isScanning && surfaceActive && !reduceMotion
        scanRotation = shouldAnimate ? 270 : -90
        sealBreathing = shouldAnimate
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
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.clipboard")
                    AnimatedNumberText("\(actionableCount)", value: Double(actionableCount))
                    Text("Next Step\(actionableCount == 1 ? "" : "s")")
                }
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
                Button("Clear", action: clear)
                    .font(.caption)
                    .buttonStyle(.quiet(Theme.accent))
            }

            ForEach(findings) { finding in
                CareLedgerRow(icon: finding.actionIcon,
                              tint: finding.severity.color,
                              title: finding.actionTitle ?? "Open",
                              detail: finding.title,
                              status: .selected)
            }

            Button(action: openFirst) {
                Label("Open First Queued Step", systemImage: "arrow.forward.circle.fill")
            }
            .buttonStyle(BrandProminentButtonStyle())
        }
        .card(padding: 14, tier: .tinted(Theme.accent))
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
                            HStack(spacing: 6) {
                                ContextualSymbol(inactive: "plus.circle",
                                                 active: "checkmark.circle.fill",
                                                 isActive: isQueued,
                                                 tint: finding.severity.color,
                                                 size: 14)
                                Text(isQueued ? "Queued" : "Queue")
                            }
                        }
                        .buttonStyle(.soft(finding.severity.color))

                        Button(action: action) {
                            Label(finding.actionTitle ?? "Open", systemImage: finding.actionIcon)
                        }
                        .buttonStyle(BrandProminentButtonStyle())
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            Spacer(minLength: 8)
        }
        .interactiveCard(padding: 14, tier: .tinted(finding.severity.color))
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
