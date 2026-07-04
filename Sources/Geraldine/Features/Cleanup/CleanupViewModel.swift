import SwiftUI

@MainActor
final class CleanupViewModel: ObservableObject {
    enum Phase { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var lastResult: TrashService.Result?
    @Published var diagnostics: ScanDiagnostics = .empty

    private var scanTask: Task<ScanReport, Never>?
    private var scanID = UUID()

    var foundTotal: UInt64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [ScanItem] { groups.items(in: selection) }
    var selectedIncludesTrash: Bool { selectedItems.contains { TrashService.isInTrash($0.url) } }
    var scanProgressText: String { "Checking Trash, caches, logs, and old installers." }
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
        phase = .scanning
        let worker = Task.detached(priority: .userInitiated) { Self.buildGroups() }
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
        groups = []; selection = []; lastResult = nil; diagnostics = .empty; phase = .idle
    }

    // MARK: - Scanning (background)

    private nonisolated static func buildGroups() -> ScanReport {
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

        if let g = group("Trash Bin", "trash.fill", Theme.bad,
                         home.appendingPathComponent(".Trash"), safe: false) { groups.append(g) }
        if let g = group("User Caches", "shippingbox.fill", Theme.accent2,
                         home.appendingPathComponent("Library/Caches"), safe: true) { groups.append(g) }
        if let g = group("Logs", "doc.text.fill", Color(red: 0.95, green: 0.55, blue: 0.35),
                         home.appendingPathComponent("Library/Logs"), safe: true) { groups.append(g) }
        if let g = group("Old Installers", "arrow.down.app.fill", Theme.warn,
                         home.appendingPathComponent("Downloads"), safe: false,
                         filter: { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }) { groups.append(g) }

        diagnostics.finish(cancelled: Task.isCancelled)
        return ScanReport(groups: groups, diagnostics: diagnostics)
    }
}
