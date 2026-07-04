import SwiftUI
import AppKit

@MainActor
final class LargeFilesViewModel: ObservableObject {
    enum Phase { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var root: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published var minSizeMB: Double = 100
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var result: TrashService.Result?
    @Published var scannedCount = 0
    @Published var diagnostics: ScanDiagnostics = .empty

    private var scanTask: Task<ScanReport, Never>?
    private var scanID = UUID()

    var scanProgressText: String {
        "Scanning can take a while in large folders. Geraldine skips packages and hidden files."
    }
    var emptyMessage: String {
        diagnostics.hasVisibleIssues
            ? "No files matched in the readable locations under \(root.path)."
            : "No files over \(Int(minSizeMB)) MB or older large files were found under \(root.path)."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func scan() {
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        phase = .scanning
        diagnostics = .empty
        result = nil
        scannedCount = 0
        let root = self.root
        let minBytes = UInt64(minSizeMB * 1_000_000)
        let worker = Task.detached(priority: .userInitiated) { Self.scan(root: root, minBytes: minBytes) }
        scanTask = worker
        Task {
            let report = await worker.value
            guard self.scanID == id else { return }
            self.scanTask = nil
            self.groups = report.groups
            self.selection = []                 // never pre-select user files
            self.scannedCount = report.diagnostics.scannedItems
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
        scannedCount = 0
        diagnostics = .cancelledScan()
        phase = .results
    }

    func clean() {
        let items = groups.items(in: selection)
        guard !items.isEmpty else { return }
        phase = .cleaning
        Task {
            self.result = await Task.detached { TrashService.clean(items) }.value
            self.phase = .done
        }
    }

    func reset() {
        scanID = UUID()
        scanTask?.cancel()
        scanTask = nil
        groups = []; selection = []; result = nil; diagnostics = .empty; scannedCount = 0; phase = .idle
    }

    private nonisolated static func scan(root: URL, minBytes: UInt64) -> ScanReport {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-365 * 24 * 3600)
        // One formatter for the whole scan — building one per old file is needless work.
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .full
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                      .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        var diagnostics = ScanDiagnostics()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                     errorHandler: { skippedURL, error in
                                         diagnostics.noteSkipped(skippedURL, error)
                                         return true
                                     }) else {
            diagnostics.failure = "Geraldine could not open \(root.path)."
            diagnostics.finish(cancelled: Task.isCancelled)
            return ScanReport(groups: [], diagnostics: diagnostics)
        }

        var large: [ScanItem] = []
        var old: [ScanItem] = []
        while let url = en.nextObject() as? URL {
            if Task.isCancelled { break }
            diagnostics.noteScanned()
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let size = DiskScan.fileSize(url)
            let modified = v?.contentModificationDate ?? Date()
            let detail = url.deletingLastPathComponent().path
            if size >= minBytes {
                large.append(ScanItem(url: url, detail: detail, size: size))
            } else if modified < cutoff && size > 5_000_000 {
                let changed = relativeFormatter.localizedString(for: modified, relativeTo: Date())
                old.append(ScanItem(url: url,
                                    detail: "Last changed \(changed) · \(detail)",
                                    size: size))
            }
        }
        large.sort { $0.size > $1.size }; large = Array(large.prefix(400))
        old.sort { $0.size > $1.size };   old = Array(old.prefix(200))

        var groups: [ScanGroup] = []
        if !large.isEmpty {
            groups.append(ScanGroup(title: "Large Files", icon: "doc.fill",
                                    tint: Module.largeFiles.tint, items: large, safeByDefault: false))
        }
        if !old.isEmpty {
            groups.append(ScanGroup(title: "Old & Forgotten (1 Year+)", icon: "clock.fill",
                                    tint: Theme.warn, items: old, safeByDefault: false))
        }
        diagnostics.finish(cancelled: Task.isCancelled)
        return ScanReport(groups: groups, diagnostics: diagnostics)
    }

}
