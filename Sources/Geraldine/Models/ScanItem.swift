import SwiftUI

struct ScanItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String
    var detail: String
    var size: UInt64

    init(url: URL, name: String? = nil, detail: String = "", size: UInt64) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.detail = detail
        self.size = size
    }
}

struct ScanGroup: Identifiable {
    let id = UUID()
    var title: String
    var icon: String
    var tint: Color
    var items: [ScanItem]
    /// Whether cleaning these is "safe by default" (pre-checked for the user).
    var safeByDefault: Bool = true

    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
}

extension Array where Element == ScanGroup {
    func items(in selection: Set<UUID>) -> [ScanItem] {
        flatMap { $0.items }.filter { selection.contains($0.id) }
    }
    func selectedSize(_ selection: Set<UUID>) -> UInt64 {
        items(in: selection).reduce(0) { $0 + $1.size }
    }
    var allItemIDs: Set<UUID> { Set(flatMap { $0.items }.map { $0.id }) }
    var defaultSelection: Set<UUID> {
        Set(filter { $0.safeByDefault }.flatMap { $0.items }.map { $0.id })
    }
}
