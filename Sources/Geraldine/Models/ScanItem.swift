import SwiftUI

struct ScanItem: Identifiable, Hashable {
    let url: URL
    var name: String
    var detail: String
    var size: UInt64
    /// Optional app bundle used to give browser/app rows their real identity.
    /// The file URL remains the cleanup target; this URL is presentation-only.
    var identityURL: URL?

    /// Scan rows are rebuilt after every pass. URL identity keeps selection,
    /// contextual symbols, and row transitions attached to the same file.
    var id: String { url.standardizedFileURL.path }

    init(url: URL, name: String? = nil, detail: String = "", size: UInt64,
         identityURL: URL? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.detail = detail
        self.size = size
        self.identityURL = identityURL
    }
}

struct ScanGroup: Identifiable {
    var title: String
    var icon: String
    var tint: Color
    var items: [ScanItem]
    /// Whether cleaning these is "safe by default" (pre-checked for the user).
    var safeByDefault: Bool = true

    var id: String { title }
    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
}

/// What a background scan hands back to its view model: the grouped results
/// plus the diagnostics gathered along the way.
struct ScanReport {
    var groups: [ScanGroup]
    var diagnostics: ScanDiagnostics
}

extension Array where Element == ScanGroup {
    func items(in selection: Set<String>) -> [ScanItem] {
        flatMap { $0.items }.filter { selection.contains($0.id) }
    }
    func selectedSize(_ selection: Set<String>) -> UInt64 {
        items(in: selection).reduce(0) { $0 + $1.size }
    }
    var allItemIDs: Set<String> { Set(flatMap { $0.items }.map { $0.id }) }
    var defaultSelection: Set<String> {
        Set(filter { $0.safeByDefault }.flatMap { $0.items }.map { $0.id })
    }
}
