import SwiftUI

@MainActor
final class CleanupViewModel: ObservableObject {
    enum Phase: Hashable { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<String> = []
    @Published var lastResult: TrashService.Result?
    @Published var diagnostics: ScanDiagnostics = .empty
    @Published private(set) var scanProgressText = "Preparing The Scan"

    private var scanTask: Task<ScanReport, Never>?
    private var scanID = UUID()

    var foundTotal: UInt64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [ScanItem] { groups.items(in: selection) }
    var selectedIncludesTrash: Bool { selectedItems.contains { TrashService.isInTrash($0.url) } }
    var emptyMessage: String {
        diagnostics.hasVisibleIssues
            ? "Geraldine did not find removable items in the readable locations."
            : "Trash, caches, logs, and old installers look clear right now."
    }

    func scan() {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        diagnostics = .empty
        lastResult = nil
        scanProgressText = "Preparing The Scan"
        phase = .scanning
        let (progress, continuation) = AsyncStream<String>.makeStream()
        Task { [weak self] in
            for await text in progress {
                guard let self else { return }
                self.publishScanProgress(text, scanID: id)
            }
        }
        let worker = Task.detached(priority: .userInitiated) {
            let report = await Self.buildGroups { text in continuation.yield(text) }
            continuation.finish()
            return report
        }
        scanTask = worker
        Task {
            let report = await worker.value
            guard self.scanID == id else { return }
            self.scanTask = nil
            self.groups = report.groups
            self.selection = report.groups.defaultSelection
            self.diagnostics = report.diagnostics
            self.phase = .results
        }
    }

    func cancelScan() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        groups = []
        selection = []
        diagnostics = .cancelledScan()
        scanProgressText = "Scan Cancelled"
        phase = .results
    }

    func clean() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .cleaning
        Task {
            let result = await Task.detached { TrashService.clean(items) }.value
            self.lastResult = result
            self.phase = .done
        }
    }

    func reset() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        groups = []; selection = []; lastResult = nil; diagnostics = .empty
        scanProgressText = "Preparing The Scan"
        phase = .idle
    }

    // MARK: - Scanning (background)

    private func publishScanProgress(_ text: String, scanID: UUID) {
        guard self.scanID == scanID, phase == .scanning else { return }
        scanProgressText = text
    }

    private nonisolated static func buildGroups(
        progress: @escaping @Sendable (String) async -> Void
    ) async -> ScanReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var groups: [ScanGroup] = []
        var diagnostics = ScanDiagnostics()

        func group(_ title: String, _ icon: String, _ tint: Color,
                   _ dir: URL, safe: Bool, filter: (URL) -> Bool = { _ in true }) -> ScanGroup? {
            if Task.isCancelled { return nil }
            let items = DiskScan.children(of: dir, diagnostics: &diagnostics)
                .filter { $0.size > 0 && filter($0.url) }
                .sorted { $0.size > $1.size }
                .map { ScanItem(url: $0.url, detail: $0.url.deletingLastPathComponent().lastPathComponent, size: $0.size) }
            guard !items.isEmpty else { return nil }
            return ScanGroup(title: title, icon: icon, tint: tint, items: items, safeByDefault: safe)
        }

        await progress("Checking The Trash")
        if let g = group("Trash Bin", "trash.fill", Theme.bad,
                         home.appendingPathComponent(".Trash"), safe: false) { groups.append(g) }
        await progress("Measuring User Caches")
        if let g = group("User Caches", "shippingbox.fill", Theme.accent2,
                         home.appendingPathComponent("Library/Caches"), safe: true) { groups.append(g) }
        await progress("Reading Diagnostic Logs")
        if let g = group("Logs", "doc.text.fill", Theme.orange,
                         home.appendingPathComponent("Library/Logs"), safe: true) { groups.append(g) }
        await progress("Looking For Old Installers")
        if let g = group("Old Installers", "arrow.down.app.fill", Theme.warn,
                         home.appendingPathComponent("Downloads"), safe: false,
                         filter: { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }) { groups.append(g) }

        await progress("Preparing Your Review")
        diagnostics.finish(cancelled: Task.isCancelled)
        return ScanReport(groups: groups, diagnostics: diagnostics)
    }
}
