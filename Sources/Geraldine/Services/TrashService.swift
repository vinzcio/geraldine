import AppKit

enum TrashService {
    struct Failure: Identifiable, Hashable {
        let url: URL
        let message: String

        var id: URL { url }
    }

    struct Result {
        var removed: Int = 0
        var trashed: Int = 0
        var permanentlyDeleted: Int = 0
        var freed: UInt64 = 0
        var failures: [Failure] = []

        var failed: [URL] { failures.map(\.url) }
    }

    /// Moves items to the Trash (reversible). Items that already live in the
    /// Trash are removed permanently — that's what "empty trash" means.
    @discardableResult
    static func clean(_ items: [ScanItem]) -> Result {
        var result = Result()
        let fm = FileManager.default
        for item in items {
            do {
                if isInTrash(item.url) {
                    try fm.removeItem(at: item.url)
                    result.permanentlyDeleted += 1
                } else {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    result.trashed += 1
                }
                result.removed += 1
                result.freed += item.size
            } catch {
                result.failures.append(Failure(url: item.url,
                                               message: (error as NSError).localizedDescription))
            }
        }
        return result
    }

    static func isInTrash(_ url: URL) -> Bool {
        url.path.contains("/.Trash/") || url.path.hasSuffix("/.Trash")
    }
}
