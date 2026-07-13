import SwiftUI
import AppKit

struct DiskNode: Identifiable, Hashable {
    /// A filesystem-derived identity keeps cells stable across rescans and lets
    /// SwiftUI preserve focus, color, and spatial continuity.
    let id: String
    let url: URL
    let name: String
    let size: UInt64
    let isDirectory: Bool
    let isAggregate: Bool
    let aggregateCount: Int

    init(url: URL, name: String, size: UInt64, isDirectory: Bool, isAggregate: Bool = false, aggregateCount: Int = 0) {
        let canonicalURL = url.standardizedFileURL
        self.id = isAggregate
            ? "\(canonicalURL.path)::geraldine-other-visible-items"
            : canonicalURL.path
        self.url = canonicalURL
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.isAggregate = isAggregate
        self.aggregateCount = aggregateCount
    }

    /// A deterministic palette position. `Hasher` is intentionally avoided
    /// because its seed changes between launches.
    var paletteIndex: Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % 8)
    }
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    enum ScanIssue: Equatable {
        case none
        case empty
        case permissionDenied
        case unreadable(String)
        case cancelled

        var title: String {
            switch self {
            case .none: return ""
            case .empty: return "No Visible Disk Usage Here"
            case .permissionDenied: return "Permission Needed"
            case .unreadable: return "Folder Could Not Be Read"
            case .cancelled: return "Scan Cancelled"
            }
        }

        var message: String {
            switch self {
            case .none:
                return ""
            case .empty:
                return "This folder is readable, but Geraldine did not find non-hidden files with allocated size."
            case .permissionDenied:
                return "macOS blocked Geraldine from reading this folder. Choose another folder or grant Full Disk Access."
            case .unreadable(let detail):
                return detail
            case .cancelled:
                return "The current scan stopped before updating the map."
            }
        }

        var icon: String {
            switch self {
            case .none: return "circle.hexagongrid"
            case .empty: return "tray"
            case .permissionDenied: return "lock.shield"
            case .unreadable: return "exclamationmark.triangle"
            case .cancelled: return "xmark.circle"
            }
        }
    }

    @Published var path: [URL]
    @Published var children: [DiskNode] = []
    @Published var loading = false
    @Published var issue: ScanIssue = .none
    @Published var scannedAt: Date?
    @Published var totalEntryCount = 0
    @Published var cappedItemCount = 0
    @Published var unreadableItemCount = 0
    @Published var progressCompleted = 0
    @Published var progressTotal = 0
    @Published var progressText = "Preparing Scan…"
    @Published private(set) var snapshotRevision = 0
    @Published private(set) var navigationDirection = 0
    @Published private(set) var snapshotDirectory: URL?

    private let maxCells = 45
    private var scanTask: Task<Void, Never>?

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        path = [root]
        load()
    }

    var current: URL { path.last ?? FileManager.default.homeDirectoryForCurrentUser }
    var currentSize: UInt64 { children.reduce(0) { $0 + $1.size } }
    var visibleNodeCount: Int { children.filter { !$0.isAggregate }.count }
    var canGoBack: Bool { path.count > 1 }
    var progressFraction: Double? {
        guard progressTotal > 0 else { return nil }
        return min(1, max(0, Double(progressCompleted) / Double(progressTotal)))
    }
    var freshnessText: String {
        guard let scannedAt else { return "Not Scanned Yet" }
        return "Scanned At \(DateFormatter.localizedString(from: scannedAt, dateStyle: .none, timeStyle: .short))"
    }
    var scopeText: String {
        if loading, let snapshotDirectory, snapshotDirectory != current, !children.isEmpty {
            return "Scanning \(Self.displayName(for: current)). The \(Self.displayName(for: snapshotDirectory)) map remains visible so you do not lose your place."
        }

        if issue == .cancelled, !children.isEmpty {
            return "Scan cancelled. Showing the last completed map for \(Self.displayName(for: current))."
        }

        var parts = [
            "Showing top-level visible entries in \(Self.displayName(for: current)).",
            "Folder sizes include readable package contents; hidden top-level entries are skipped."
        ]
        if cappedItemCount > 0 {
            parts.append("Other Visible Items combines \(cappedItemCount) smaller entr\(cappedItemCount == 1 ? "y" : "ies").")
        }
        if unreadableItemCount > 0 {
            parts.append("\(unreadableItemCount) nested item\(unreadableItemCount == 1 ? "" : "s") could not be read.")
        }
        return parts.joined(separator: " ")
    }

    func enter(_ node: DiskNode) {
        guard node.isDirectory, !node.isAggregate else { return }
        navigationDirection = 1
        path.append(node.url)
        load()
    }

    func goTo(_ index: Int) {
        guard index < path.count - 1 else { return }
        navigationDirection = -1
        path = Array(path.prefix(index + 1))
        load()
    }

    func goBack() {
        guard canGoBack else { return }
        goTo(path.count - 2)
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url {
            navigationDirection = 0
            path = [url.standardizedFileURL]
            load()
        }
    }

    func load() {
        scanTask?.cancel()
        if snapshotDirectory == current {
            navigationDirection = 0
        }
        loading = true
        issue = .none
        progressCompleted = 0
        progressTotal = 0
        progressText = "Preparing Scan…"

        let dir = current
        let cap = maxCells
        scanTask = Task { [weak self] in
            let result = await Self.scan(dir: dir, cap: cap) { [weak self] progress in
                guard let model = self else { return }
                await MainActor.run {
                    guard model.current == dir else { return }
                    model.progressCompleted = progress.completed
                    model.progressTotal = progress.total
                    model.progressText = progress.label
                }
            }

            guard let self, !Task.isCancelled, self.current == dir else { return }
            self.children = result.nodes
            self.snapshotDirectory = dir
            self.issue = result.issue
            self.scannedAt = result.issue == .cancelled ? self.scannedAt : Date()
            self.totalEntryCount = result.totalEntries
            self.cappedItemCount = result.cappedItems
            self.unreadableItemCount = result.unreadableItems
            self.progressCompleted = result.totalEntries
            self.progressTotal = result.totalEntries
            self.progressText = result.issue == .none ? "Scan Complete" : result.issue.title
            self.loading = false
            self.snapshotRevision &+= 1
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        loading = false
        issue = .cancelled
        progressText = "Scan Cancelled"
        if snapshotDirectory != current {
            children = []
            snapshotDirectory = current
            snapshotRevision &+= 1
        }
    }

    func revealCurrent() {
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    func openCurrent() {
        NSWorkspace.shared.open(current)
    }

    func reveal(_ node: DiskNode) {
        guard !node.isAggregate else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func open(_ node: DiskNode) {
        guard !node.isAggregate else { return }
        NSWorkspace.shared.open(node.url)
    }

    func activate(_ node: DiskNode) {
        if node.isAggregate {
            revealCurrent()
        } else if node.isDirectory {
            enter(node)
        } else {
            open(node)
        }
    }

    nonisolated private static func displayName(for url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private struct ScanProgress: Sendable {
        var completed: Int
        var total: Int
        var label: String
    }

    private struct ScanResult {
        var nodes: [DiskNode]
        var issue: ScanIssue
        var totalEntries: Int
        var cappedItems: Int
        var unreadableItems: Int
    }

    private struct SizeMeasurement {
        var size: UInt64
        var unreadableItems: Int
    }

    nonisolated private static func scan(
        dir: URL,
        cap: Int,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async -> ScanResult {
        let worker = Task.detached(priority: .userInitiated) { () -> ScanResult in
            let fm = FileManager.default
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles])
            } catch {
                let issue: ScanIssue = Self.isPermissionError(error) ? .permissionDenied : .unreadable(error.localizedDescription)
                return ScanResult(nodes: [], issue: issue, totalEntries: 0, cappedItems: 0, unreadableItems: 0)
            }

            guard !entries.isEmpty else {
                return ScanResult(nodes: [], issue: .empty, totalEntries: 0, cappedItems: 0, unreadableItems: 0)
            }

            await progress(ScanProgress(completed: 0, total: entries.count, label: "Scanning 0 of \(entries.count) Items…"))

            var nodes: [DiskNode] = []
            var unreadableItems = 0

            for (index, url) in entries.enumerated() {
                if Task.isCancelled {
                    return ScanResult(nodes: [], issue: .cancelled, totalEntries: entries.count, cappedItems: 0, unreadableItems: unreadableItems)
                }

                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let measured = Self.measuredSize(of: url)
                unreadableItems += measured.unreadableItems
                if measured.size > 0 {
                    nodes.append(DiskNode(url: url,
                                          name: url.lastPathComponent,
                                          size: measured.size,
                                          isDirectory: isDirectory))
                }

                await progress(ScanProgress(completed: index + 1,
                                            total: entries.count,
                                            label: "Scanning \(index + 1) of \(entries.count) Items…"))
            }

            nodes.sort {
                if $0.size != $1.size { return $0.size > $1.size }
                return $0.id.localizedStandardCompare($1.id) == .orderedAscending
            }

            let uncappedCount = nodes.count
            var cappedItems = 0
            if nodes.count > cap {
                let visibleLimit = max(1, cap - 1)
                let head = Array(nodes.prefix(visibleLimit))
                let tail = Array(nodes.dropFirst(visibleLimit))
                let tailSize = tail.reduce(0) { $0 + $1.size }
                nodes = head
                cappedItems = tail.count
                if tailSize > 0 {
                    nodes.append(DiskNode(url: dir,
                                          name: "Other Visible Items",
                                          size: tailSize,
                                          isDirectory: false,
                                          isAggregate: true,
                                          aggregateCount: tail.count))
                }
            }

            let issue: ScanIssue = uncappedCount == 0 ? .empty : .none
            return ScanResult(nodes: nodes,
                              issue: issue,
                              totalEntries: entries.count,
                              cappedItems: cappedItems,
                              unreadableItems: unreadableItems)
        }

        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated private static func measuredSize(of url: URL) -> SizeMeasurement {
        var diagnostics = ScanDiagnostics()
        let size = DiskScan.size(of: url, includingPackageContents: true, diagnostics: &diagnostics)
        return SizeMeasurement(size: size, unreadableItems: diagnostics.skippedTotal)
    }

    nonisolated private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == EPERM || nsError.code == EACCES) {
            return true
        }
        return false
    }
}
