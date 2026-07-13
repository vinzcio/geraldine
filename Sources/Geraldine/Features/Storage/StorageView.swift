import SwiftUI
import AppKit

struct StorageCategory: Identifiable {
    var label: String
    var detail: String
    var value: Double
    var color: Color
    var chartColor: Color
    var confidence: Confidence
    var route: Route
    var isAvailable: Bool = false

    var id: String { label }

    enum Confidence: Equatable {
        case measured, derived, available

        var label: String {
            switch self {
            case .measured: return "Measured"
            case .derived: return "Derived"
            case .available: return "Available"
            }
        }

        var color: Color {
            switch self {
            case .measured: return Theme.good
            case .derived: return Theme.warn
            case .available: return Color.secondary
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
        case failed(String)
    }

    enum MeasurementStage: String, Hashable {
        case capacity = "Reading APFS Capacity"
        case applications = "Measuring Applications"
        case personalFiles = "Measuring Personal Folders"
        case library = "Measuring The User Library"
        case finalizing = "Separating Measured And Derived Space"
    }

    @Published var loading = false
    @Published var categories: [StorageCategory] = []
    @Published var freeText = "-"
    @Published var totalText = ""
    @Published var scannedAt: Date?
    @Published var status: Status = .idle
    @Published private(set) var measurementStage: MeasurementStage = .capacity

    private var loadID = UUID()

    var segments: [DonutSegment] {
        categories
            .filter { $0.value > 0 }
            .map { DonutSegment(label: $0.label, value: $0.value, color: $0.chartColor) }
    }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    var freshnessText: String {
        guard let scannedAt else { return "Not Measured Yet" }
        return "Measured At \(DateFormatter.localizedString(from: scannedAt, dateStyle: .none, timeStyle: .short))"
    }

    var measuredText: String {
        let measured = categories.filter { $0.confidence == .measured }.reduce(0) { $0 + $1.value }
        guard measured > 0 else { return "No Measured Folders Yet" }
        return "\(Fmt.size(measured)) Directly Measured"
    }

    func load() {
        let id = UUID()
        loadID = id
        loading = true
        status = .idle
        measurementStage = .capacity
        let (progress, continuation) = AsyncStream<MeasurementStage>.makeStream()
        Task { [weak self] in
            for await stage in progress {
                guard let self else { return }
                self.publish(stage, loadID: id)
            }
        }
        Task {
            let result = await Self.compute { stage in continuation.yield(stage) }
            continuation.finish()
            guard self.loadID == id else { return }
            if let error = result.error {
                self.status = .failed(error)
            } else {
                self.categories = result.categories
                self.freeText = result.freeText
                self.totalText = result.totalText
                self.scannedAt = Date()
                self.status = .ready
            }
            self.loading = false
        }
    }

    private func publish(_ stage: MeasurementStage, loadID: UUID) {
        guard self.loadID == loadID, loading else { return }
        measurementStage = stage
    }

    private struct Result {
        var categories: [StorageCategory] = []
        var freeText: String = "-"
        var totalText: String = ""
        var error: String?
    }

    private static func compute(
        progress: @escaping @Sendable (MeasurementStage) async -> Void
    ) async -> Result {
        await Task.detached(priority: .userInitiated) { () -> Result in
            await progress(.capacity)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let root = URL(fileURLWithPath: "/")
            let values = try? root.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            guard let totalCapacity = values?.volumeTotalCapacity, totalCapacity > 0 else {
                return Result(error: "macOS did not return a usable APFS capacity for the startup volume.")
            }

            let importantFree = values?.volumeAvailableCapacityForImportantUsage
            let fallbackFree = values?.volumeAvailableCapacity.map { Int64($0) }
            let freeBytes = max(0, importantFree ?? fallbackFree ?? 0)
            let total = Double(totalCapacity)
            let free = min(total, Double(freeBytes))
            let used = max(0, total - free)

            let applicationsURL = URL(fileURLWithPath: "/Applications")
            let systemApplicationsURL = URL(fileURLWithPath: "/System/Applications")
            let documentsURL = home.appendingPathComponent("Documents")
            let desktopURL = home.appendingPathComponent("Desktop")
            let downloadsURL = home.appendingPathComponent("Downloads")
            let libraryURL = home.appendingPathComponent("Library")

            await progress(.applications)
            let applications = Double(DiskScan.size(of: applicationsURL, includingPackageContents: true)
                + DiskScan.size(of: systemApplicationsURL, includingPackageContents: true))
            await progress(.personalFiles)
            let documents = Double(DiskScan.size(of: documentsURL, includingPackageContents: true))
            let desktop = Double(DiskScan.size(of: desktopURL, includingPackageContents: true))
            let downloads = Double(DiskScan.size(of: downloadsURL, includingPackageContents: true))
            await progress(.library)
            let library = Double(DiskScan.size(of: libraryURL, includingPackageContents: true))

            var categories: [StorageCategory] = [
                StorageCategory(label: "Applications",
                                detail: "Measured /Applications and /System/Applications; Reveal opens user Applications.",
                                value: applications,
                                color: Theme.accent,
                                chartColor: Theme.Chart.purple,
                                confidence: .measured,
                                route: .reveal(applicationsURL)),
                StorageCategory(label: "Documents",
                                detail: "Measured your Documents folder.",
                                value: documents,
                                color: Theme.accent2,
                                chartColor: Theme.Chart.blue,
                                confidence: .measured,
                                route: .reveal(documentsURL)),
                StorageCategory(label: "Desktop",
                                detail: "Measured files and folders on your Desktop.",
                                value: desktop,
                                color: Theme.aqua,
                                chartColor: Theme.Chart.mint,
                                confidence: .measured,
                                route: .reveal(desktopURL)),
                StorageCategory(label: "Downloads",
                                detail: "Measured your Downloads folder.",
                                value: downloads,
                                color: Theme.orange,
                                chartColor: Theme.Chart.orange,
                                confidence: .measured,
                                route: .reveal(downloadsURL)),
                StorageCategory(label: "User Library",
                                detail: "Measured app support, containers, caches, and logs Geraldine can read.",
                                value: library,
                                color: Theme.green,
                                chartColor: Theme.Chart.green,
                                confidence: .measured,
                                route: .reveal(libraryURL))
            ].filter { $0.value > 0 }

            await progress(.finalizing)
            let measured = categories.reduce(0) { $0 + $1.value }
            let systemOther = max(0, used - measured)
            if systemOther > 0 {
                categories.append(StorageCategory(
                    label: "APFS, System, and Other",
                    detail: "Derived from used space minus measured folders. Includes macOS, snapshots, other users, protected files, and unmeasured locations.",
                    value: systemOther,
                    color: Theme.slate,
                    chartColor: Theme.Chart.plum,
                    confidence: .derived,
                    route: .module(.spaceLens)
                ))
            }

            categories.append(StorageCategory(
                label: "Available",
                detail: "Free space macOS reports as available for important usage.",
                value: free,
                color: Theme.silver,
                chartColor: Theme.Chart.silver,
                confidence: .available,
                route: .none,
                isAvailable: true
            ))

            return Result(categories: categories,
                          freeText: Fmt.size(free),
                          totalText: "Free of \(Fmt.size(total))",
                          error: nil)
        }.value
    }
}

struct StorageView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var vm = StorageViewModel()

    private enum PresentationPhase: Hashable {
        case measuring
        case failed(String)
        case results
    }

    private var presentationPhase: PresentationPhase {
        if vm.loading, vm.categories.isEmpty { return .measuring }
        if let error = vm.errorMessage { return .failed(error) }
        return .results
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .storage) {
                Button { vm.load() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(vm.loading)
            }

            WorkflowPhaseHost(phase: presentationPhase) {
                switch presentationPhase {
                case .measuring:
                    ScanningState(tint: Module.storage.tint, icon: Module.storage.systemImage,
                                  label: "Measuring Your Disk",
                                  progressText: vm.measurementStage.rawValue)
                case .failed(let error):
                    StorageErrorState(message: error, retry: vm.load)
                case .results:
                    ScrollView {
                        VStack(spacing: 18) {
                            HStack(spacing: 32) {
                                DonutChart(segments: vm.segments, centerTitle: vm.freeText,
                                           centerSubtitle: vm.totalText, lineWidth: 30)
                                    .frame(width: 220, height: 220)
                                    .opacity(vm.loading ? 0.58 : 1)
                                    .geraldineEntrance()

                                VStack(alignment: .leading, spacing: 12) {
                                    StorageFreshnessCard(freshness: vm.freshnessText,
                                                         measured: vm.measuredText,
                                                         stage: vm.measurementStage,
                                                         isRefreshing: vm.loading)

                                    ForEach(Array(vm.categories.enumerated()), id: \.element.id) { index, category in
                                        StorageCategoryRow(category: category) { route in
                                            open(route)
                                        }
                                        .geraldineEntrance(delay: min(Double(index) * 0.055, 0.28), distance: 6)
                                    }
                                }
                                .frame(maxWidth: 360)
                            }
                            .card(padding: 24, tier: .tinted(Module.storage.tint))

                            HStack(spacing: 12) {
                                StorageRouteButton(icon: "sparkles",
                                                   title: "Free Up Space With Cleanup",
                                                   detail: "Review caches, logs, Trash, and old installers before removing anything.",
                                                   tint: Module.cleanup.tint) {
                                    state.open(.cleanup)
                                }

                                StorageRouteButton(icon: Module.spaceLens.systemImage,
                                                   title: "Drill Into Folders With Space Lens",
                                                   detail: "Use a folder map for the parts APFS reports as System or Other.",
                                                   tint: Module.spaceLens.tint) {
                                    state.open(.spaceLens)
                                }
                            }
                        }
                        .padding(26)
                    }
                }
            }
        }
        .onAppear { if vm.categories.isEmpty { vm.load() } }
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

private struct StorageFreshnessCard: View {
    var freshness: String
    var measured: String
    var stage: StorageViewModel.MeasurementStage
    var isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(isRefreshing ? stage.rawValue : freshness,
                  systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
            Label(measured, systemImage: "folder.badge.gearshape")
            Text("Measured folders are scanned directly. APFS/System/Other is the remaining used space and can include snapshots, protected folders, other users, and system data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

private struct StorageCategoryRow: View {
    var category: StorageCategory
    var open: (StorageCategory.Route) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(category.chartColor).frame(width: 11, height: 11).padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(category.label).font(.callout.weight(.semibold))
                    StorageConfidenceBadge(confidence: category.confidence)
                }
                Text(category.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                AnimatedNumberText(Fmt.size(category.value), value: category.value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let action = actionLabel {
                    Button { open(category.route) } label: {
                        Label(action.title, systemImage: action.icon)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.soft(category.color))
                }
            }
        }
    }

    private var actionLabel: (title: String, icon: String)? {
        switch category.route {
        case .reveal:
            return ("Reveal", "arrow.up.forward.app")
        case .module(let module):
            return (module == .spaceLens ? "Explore" : "Open", module.systemImage)
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.rounded(14, .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.actionableCard(padding: 14, tier: .tinted(tint)))
    }
}

private struct StorageErrorState: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            WorkflowMark(state: .failure, tint: Module.storage.tint,
                         idleIcon: "externaldrive.badge.xmark", size: 86)
            Text("Storage Could Not Be Measured").font(.rounded(20, .semibold))
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
