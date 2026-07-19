import SwiftUI
import AppKit

struct StorageCapacity: Equatable {
    var total: Double
    var free: Double

    init(total: Double, free: Double) {
        self.total = max(0, total)
        self.free = min(max(0, free), self.total)
    }

    var used: Double { max(0, total - free) }
    var usedFraction: Double { total > 0 ? used / total : 0 }
}

struct StorageCategory: Identifiable {
    var label: String
    var detail: String
    var value: Double
    var color: Color
    var chartColor: Color
    var confidence: Confidence
    var route: Route

    var id: String { label }

    enum Confidence: Equatable {
        case measured, derived

        var label: String {
            switch self {
            case .measured: return "Measured"
            case .derived: return "Estimated"
            }
        }

        var color: Color {
            switch self {
            case .measured: return Theme.good
            case .derived: return Theme.warn
            }
        }
    }

    enum Route {
        case reveal(URL)
        case module(Module)
        case none
    }
}

@MainActor
final class StorageViewModel: ObservableObject {
    enum Status: Hashable {
        case idle
        case ready
        case cancelled
        case failed(String)
    }

    enum MeasurementStage: String, Hashable {
        case applications = "Measuring Applications"
        case personalFiles = "Measuring Personal Folders"
        case library = "Measuring The User Library"
        case finalizing = "Calculating System And Other"
    }

    @Published private(set) var capacity: StorageCapacity?
    @Published private(set) var loading = false
    @Published private(set) var categories: [StorageCategory] = []
    @Published private(set) var scannedAt: Date?
    @Published private(set) var status: Status = .idle
    @Published private(set) var measurementStage: MeasurementStage = .applications

    private var scanID = UUID()
    private var progressTask: Task<Void, Never>?
    private var workerTask: Task<Result, Never>?
    private var scanTask: Task<Void, Never>?

    var freshnessText: String {
        guard let scannedAt else { return loading ? "Measurement In Progress" : "Not Measured Yet" }
        return "Measured At \(DateFormatter.localizedString(from: scannedAt, dateStyle: .none, timeStyle: .short))"
    }

    var measuredText: String {
        let measured = categories.filter { $0.confidence == .measured }.reduce(0) { $0 + $1.value }
        guard measured > 0 else { return "Waiting For Folder Measurements" }
        return "\(Fmt.size(measured)) Directly Measured"
    }

    func load() {
        cancel()

        guard let capacity = Self.readCapacity() else {
            self.capacity = nil
            status = .failed("macOS did not return a usable APFS capacity for the startup volume.")
            return
        }

        let id = UUID()
        scanID = id
        self.capacity = capacity
        loading = true
        status = .idle
        measurementStage = .applications

        let (progress, continuation) = AsyncStream<ScanProgress>.makeStream()
        progressTask = Task { [weak self] in
            for await update in progress {
                guard let self, self.scanID == id else { return }
                self.measurementStage = update.stage
                self.categories = update.categories
            }
        }

        let worker = Task.detached(priority: .userInitiated) {
            let result = await Self.compute(capacity: capacity) { update in
                continuation.yield(update)
            }
            continuation.finish()
            return result
        }
        workerTask = worker

        scanTask = Task { [weak self] in
            let result = await worker.value
            guard let self, self.scanID == id, !Task.isCancelled else { return }
            self.workerTask = nil
            self.progressTask = nil
            self.scanTask = nil
            self.loading = false
            guard !result.cancelled else { return }
            self.categories = result.categories
            self.scannedAt = Date()
            self.status = .ready
        }
    }

    func cancel() {
        let wasLoading = loading
        scanID = UUID()
        workerTask?.cancel()
        progressTask?.cancel()
        scanTask?.cancel()
        workerTask = nil
        progressTask = nil
        scanTask = nil
        loading = false
        if wasLoading { status = .cancelled }
    }

    nonisolated private static func readCapacity() -> StorageCapacity? {
        let root = URL(fileURLWithPath: "/")
        let values = try? root.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        guard let totalCapacity = values?.volumeTotalCapacity, totalCapacity > 0 else { return nil }
        let importantFree = values?.volumeAvailableCapacityForImportantUsage
        let fallbackFree = values?.volumeAvailableCapacity.map(Int64.init)
        return StorageCapacity(total: Double(totalCapacity), free: Double(max(0, importantFree ?? fallbackFree ?? 0)))
    }

    private struct ScanProgress {
        var stage: MeasurementStage
        var categories: [StorageCategory]
    }

    private struct Result {
        var categories: [StorageCategory] = []
        var cancelled = false
    }

    nonisolated private static func compute(
        capacity: StorageCapacity,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationsURL = URL(fileURLWithPath: "/Applications")
        let systemApplicationsURL = URL(fileURLWithPath: "/System/Applications")
        let documentsURL = home.appendingPathComponent("Documents")
        let desktopURL = home.appendingPathComponent("Desktop")
        let downloadsURL = home.appendingPathComponent("Downloads")
        let libraryURL = home.appendingPathComponent("Library")
        var categories: [StorageCategory] = []

        await progress(ScanProgress(stage: .applications, categories: categories))
        let applications = Double(DiskScan.size(of: applicationsURL, includingPackageContents: true)
            + DiskScan.size(of: systemApplicationsURL, includingPackageContents: true))
        guard !Task.isCancelled else { return Result(categories: categories, cancelled: true) }
        appendIfPresent(
            StorageCategory(label: "Applications",
                            detail: "Apps installed for you and by macOS.",
                            value: applications,
                            color: Theme.accent,
                            chartColor: Theme.Chart.purple,
                            confidence: .measured,
                            route: .reveal(applicationsURL)),
            to: &categories
        )

        await progress(ScanProgress(stage: .personalFiles, categories: categories))
        let personalFolders: [(String, String, URL, Color, Color)] = [
            ("Documents", "Files in your Documents folder.", documentsURL, Theme.accent2, Theme.Chart.blue),
            ("Desktop", "Files and folders on your Desktop.", desktopURL, Theme.aqua, Theme.Chart.mint),
            ("Downloads", "Files waiting in Downloads.", downloadsURL, Theme.orange, Theme.Chart.orange)
        ]
        for (label, detail, url, color, chartColor) in personalFolders {
            let value = Double(DiskScan.size(of: url, includingPackageContents: true))
            guard !Task.isCancelled else { return Result(categories: categories, cancelled: true) }
            appendIfPresent(
                StorageCategory(label: label, detail: detail, value: value,
                                color: color, chartColor: chartColor,
                                confidence: .measured, route: .reveal(url)),
                to: &categories
            )
            await progress(ScanProgress(stage: .personalFiles, categories: categories))
        }

        await progress(ScanProgress(stage: .library, categories: categories))
        let library = Double(DiskScan.size(of: libraryURL, includingPackageContents: true))
        guard !Task.isCancelled else { return Result(categories: categories, cancelled: true) }
        appendIfPresent(
            StorageCategory(label: "User Library",
                            detail: "App support, containers, caches, and logs Geraldine can read.",
                            value: library,
                            color: Theme.green,
                            chartColor: Theme.Chart.green,
                            confidence: .measured,
                            route: .reveal(libraryURL)),
            to: &categories
        )

        await progress(ScanProgress(stage: .finalizing, categories: categories))
        let measured = categories.reduce(0) { $0 + $1.value }
        let systemOther = max(0, capacity.used - measured)
        appendIfPresent(
            StorageCategory(label: "System And Other",
                            detail: "macOS, snapshots, protected data, other users, and unmeasured locations.",
                            value: systemOther,
                            color: Theme.slate,
                            chartColor: Theme.Chart.plum,
                            confidence: .derived,
                            route: .none),
            to: &categories
        )
        return Result(categories: categories)
    }

    nonisolated private static func appendIfPresent(_ category: StorageCategory,
                                                     to categories: inout [StorageCategory]) {
        if category.value > 0 { categories.append(category) }
    }
}

struct StorageView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = StorageViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .storage) {
                Button { vm.load() } label: {
                    Label(vm.loading ? "Measuring" : "Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(vm.loading)
            }

            if let capacity = vm.capacity {
                ScrollView {
                    VStack(spacing: Theme.Spacing.md) {
                        StorageCapacityHero(capacity: capacity)
                            .geraldineEntrance()

                        StorageActionGrid {
                            state.open(.cleanup)
                        }
                        .geraldineEntrance(delay: 0.06, distance: 6)

                        StorageBreakdownCard(
                            categories: vm.categories,
                            freshness: vm.freshnessText,
                            measured: vm.measuredText,
                            stage: vm.measurementStage,
                            isLoading: vm.loading,
                            isComplete: vm.status == .ready,
                            cancel: vm.cancel,
                            open: open
                        )
                        .geraldineEntrance(delay: 0.12, distance: 6)
                    }
                    .frame(maxWidth: Theme.Layout.readingMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(Theme.Spacing.xl)
                }
            } else if case .failed(let message) = vm.status {
                StorageErrorState(message: message, retry: vm.load)
            } else {
                ScanningState(tint: Module.storage.tint, icon: Module.storage.systemImage,
                              label: "Reading Your Startup Disk")
            }
        }
        .onAppear { if vm.capacity == nil { vm.load() } }
        .onDisappear { vm.cancel() }
    }

    private func open(_ route: StorageCategory.Route) {
        switch route {
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .module(let module):
            state.open(module)
        case .none:
            break
        }
    }
}

private struct StorageCapacityHero: View {
    let capacity: StorageCapacity

    private var tint: Color { Theme.Chart.status(for: capacity.usedFraction) }
    private var segments: [DonutSegment] {
        [
            DonutSegment(label: "Used", value: capacity.used, color: tint),
            DonutSegment(label: "Available", value: capacity.free, color: Theme.Chart.silver)
        ]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                capacityRing
                summary
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                capacityRing.frame(maxWidth: .infinity)
                summary
            }
        }
        .card(padding: Theme.Spacing.xl, tier: .tinted(Module.storage.tint))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Startup disk")
        .accessibilityValue("\(Fmt.size(capacity.free)) available of \(Fmt.size(capacity.total)), \(Fmt.percent(capacity.usedFraction)) used")
    }

    private var capacityRing: some View {
        DonutChart(segments: segments,
                   centerTitle: Fmt.size(capacity.free),
                   centerSubtitle: "Available",
                   lineWidth: 26,
                   centerTitleColor: Theme.Chart.silver)
            .frame(width: 184, height: 184)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Startup Disk", systemImage: "internaldrive.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            AnimatedNumberText(Fmt.percent(capacity.usedFraction),
                               value: capacity.usedFraction * 100)
                .font(.rounded(28, .bold).monospacedDigit())
                .contentTransition(.numericText())
                .foregroundStyle(MetricPresentationPolicy.usageReadoutColor(capacity.usedFraction))
            Text("of the startup disk is in use")
                .font(.callout)
                .foregroundStyle(.secondary)

            StatBar(fraction: capacity.usedFraction, tint: tint, height: 8)

            HStack(spacing: Theme.Spacing.lg) {
                capacityMetric(title: "Available", value: Fmt.size(capacity.free),
                               animationValue: capacity.free, color: Theme.Chart.silver)
                capacityMetric(title: "Used", value: Fmt.size(capacity.used),
                               animationValue: capacity.used, color: tint)
                capacityMetric(title: "Total", value: Fmt.size(capacity.total),
                               animationValue: capacity.total, color: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capacityMetric(title: String, value: String, animationValue: Double,
                                color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            AnimatedNumberText(value, value: animationValue)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}

private struct StorageActionGrid: View {
    var openCleanup: () -> Void

    var body: some View {
        StorageRouteButton(icon: "sparkles",
                           title: "Free Up Space",
                           detail: "Review safe cleanup candidates.",
                           tint: Module.cleanup.tint,
                           action: openCleanup)
    }
}

private struct StorageBreakdownCard: View {
    var categories: [StorageCategory]
    var freshness: String
    var measured: String
    var stage: StorageViewModel.MeasurementStage
    var isLoading: Bool
    var isComplete: Bool
    var cancel: () -> Void
    var open: (StorageCategory.Route) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header

            if categories.isEmpty, isLoading {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.rawValue).font(.callout.weight(.semibold))
                        Text("Capacity is ready while Geraldine measures readable folders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        if index > 0 { Divider().padding(.leading, 21) }
                        StorageCategoryRow(category: category, open: open)
                            .padding(.vertical, Theme.Spacing.sm)
                    }
                }
            }
        }
        .card(padding: Theme.Spacing.lg, tier: .raised)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Folder Breakdown").font(.rounded(17, .semibold))
                Text(isLoading ? stage.rawValue : "\(freshness) · \(measured)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Button("Stop", action: cancel)
                        .buttonStyle(.quiet(Theme.warn))
                        .minimumHitArea()
                }
            } else if isComplete {
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.good)
            } else {
                Label("Stopped", systemImage: "pause.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warn)
            }
        }
    }
}

private struct StorageCategoryRow: View {
    var category: StorageCategory
    var open: (StorageCategory.Route) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            Circle()
                .fill(category.chartColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(category.label).font(.callout.weight(.semibold))
                    StorageConfidenceBadge(confidence: category.confidence)
                }
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Theme.Spacing.sm)

            VStack(alignment: .trailing, spacing: 4) {
                AnimatedNumberText(Fmt.size(category.value), value: category.value)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(category.chartColor)
                if let action = actionLabel {
                    Button { open(category.route) } label: {
                        Label(action.title, systemImage: action.icon)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.quiet(category.color))
                    .minimumHitArea()
                }
            }
        }
    }

    private var actionLabel: (title: String, icon: String)? {
        switch category.route {
        case .reveal:
            return ("Reveal", "arrow.up.forward.app")
        case .module(let module):
            return ("Open", module.systemImage)
        case .none:
            return nil
        }
    }
}

private struct StorageConfidenceBadge: View {
    var confidence: StorageCategory.Confidence

    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(confidence.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(confidence.color.opacity(0.12), in: Capsule())
    }
}

private struct StorageRouteButton: View {
    var icon: String
    var title: String
    var detail: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                ModuleGlyph(systemImage: icon, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.rounded(14, .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.actionableCard(padding: Theme.Spacing.sm, tier: .tinted(tint)))
    }
}

private struct StorageErrorState: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            WorkflowMark(state: .failure, tint: Module.storage.tint,
                         idleIcon: "externaldrive.badge.xmark", size: 86)
            Text("Storage Could Not Be Read").font(.rounded(20, .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            PrimaryButton(title: "Try Again", icon: "arrow.clockwise", action: retry)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
