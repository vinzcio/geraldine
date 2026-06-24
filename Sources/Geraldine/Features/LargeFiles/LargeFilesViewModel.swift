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

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    func scan() {
        phase = .scanning
        let root = self.root
        let minBytes = UInt64(minSizeMB * 1_000_000)
        Task {
            let g = await Self.scan(root: root, minBytes: minBytes)
            self.groups = g
            self.selection = []                 // never pre-select user files
            self.phase = .results
        }
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

    func reset() { groups = []; selection = []; result = nil; phase = .idle }

    private static func scan(root: URL, minBytes: UInt64) async -> [ScanGroup] {
        await Task.detached(priority: .userInitiated) { () -> [ScanGroup] in
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-365 * 24 * 3600)
            let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                          .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { _, _ in true }) else { return [] }

            var large: [ScanItem] = []
            var old: [ScanItem] = []
            while let url = en.nextObject() as? URL {
                let v = try? url.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { continue }
                let size = DiskScan.fileSize(url)
                let modified = v?.contentModificationDate ?? Date()
                let detail = url.deletingLastPathComponent().path
                if size >= minBytes {
                    large.append(ScanItem(url: url, detail: detail, size: size))
                } else if modified < cutoff && size > 5_000_000 {
                    old.append(ScanItem(url: url,
                                        detail: "Last changed \(Self.relative(modified)) · \(detail)",
                                        size: size))
                }
            }
            large.sort { $0.size > $1.size }; large = Array(large.prefix(400))
            old.sort { $0.size > $1.size };   old = Array(old.prefix(200))

            var groups: [ScanGroup] = []
            if !large.isEmpty {
                groups.append(ScanGroup(title: "Large files", icon: "doc.fill",
                                        tint: Module.largeFiles.tint, items: large, safeByDefault: false))
            }
            if !old.isEmpty {
                groups.append(ScanGroup(title: "Old & forgotten (1 year+)", icon: "clock.fill",
                                        tint: Theme.warn, items: old, safeByDefault: false))
            }
            return groups
        }.value
    }

    private nonisolated static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
