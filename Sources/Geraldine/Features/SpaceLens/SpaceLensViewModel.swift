import SwiftUI

struct DiskNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let size: UInt64
    let isDirectory: Bool
    let isAggregate: Bool   // the synthetic "Other" cell

    init(url: URL, name: String, size: UInt64, isDirectory: Bool, isAggregate: Bool = false) {
        self.url = url; self.name = name; self.size = size
        self.isDirectory = isDirectory; self.isAggregate = isAggregate
    }
}

@MainActor
final class SpaceLensViewModel: ObservableObject {
    @Published var path: [URL]
    @Published var children: [DiskNode] = []
    @Published var loading = false

    private let maxCells = 45

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        path = [root]
        load()
    }

    var current: URL { path.last ?? FileManager.default.homeDirectoryForCurrentUser }
    var currentSize: UInt64 { children.reduce(0) { $0 + $1.size } }

    func enter(_ node: DiskNode) {
        guard node.isDirectory, !node.isAggregate else { return }
        path.append(node.url)
        load()
    }

    func goTo(_ index: Int) {
        guard index < path.count - 1 else { return }
        path = Array(path.prefix(index + 1))
        load()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url { path = [url]; load() }
    }

    func load() {
        loading = true
        let dir = current
        let cap = maxCells
        Task {
            let nodes = await Self.scan(dir: dir, cap: cap)
            self.children = nodes
            self.loading = false
        }
    }

    private static func scan(dir: URL, cap: Int) async -> [DiskNode] {
        await Task.detached(priority: .userInitiated) { () -> [DiskNode] in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { return [] }

            var nodes: [DiskNode] = entries.map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return DiskNode(url: url, name: url.lastPathComponent,
                                size: DiskScan.size(of: url), isDirectory: isDir)
            }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }

            if nodes.count > cap {
                let head = Array(nodes.prefix(cap))
                let tailSize = nodes[cap...].reduce(0) { $0 + $1.size }
                nodes = head
                if tailSize > 0 {
                    nodes.append(DiskNode(url: dir, name: "Other",
                                          size: tailSize, isDirectory: false, isAggregate: true))
                }
            }
            return nodes
        }.value
    }
}
