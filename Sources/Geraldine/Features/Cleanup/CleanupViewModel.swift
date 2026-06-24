import SwiftUI

@MainActor
final class CleanupViewModel: ObservableObject {
    enum Phase { case idle, scanning, results, cleaning, done }

    @Published var phase: Phase = .idle
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<UUID> = []
    @Published var lastResult: TrashService.Result?

    var foundTotal: UInt64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedItems: [ScanItem] { groups.items(in: selection) }
    var selectedIncludesTrash: Bool { selectedItems.contains { TrashService.isInTrash($0.url) } }

    func scan() {
        phase = .scanning
        Task {
            let found = await Self.buildGroups()
            self.groups = found
            self.selection = found.defaultSelection
            self.phase = found.isEmpty ? .done : .results
            if found.isEmpty { self.lastResult = TrashService.Result() }
        }
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
        groups = []; selection = []; lastResult = nil; phase = .idle
    }

    // MARK: - Scanning (background)

    private static func buildGroups() async -> [ScanGroup] {
        await Task.detached(priority: .userInitiated) { () -> [ScanGroup] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            var groups: [ScanGroup] = []

            func group(_ title: String, _ icon: String, _ tint: Color,
                       _ dir: URL, safe: Bool, filter: (URL) -> Bool = { _ in true }) -> ScanGroup? {
                let items = DiskScan.children(of: dir)
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

            return groups
        }.value
    }
}
