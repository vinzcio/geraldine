import Foundation

enum DiskScan {
    /// Allocated size of a single file (falls back through size keys).
    static func fileSize(_ url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ])
        return UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
    }

    /// Recursively sums sizes under a URL. Best-effort; skips unreadable items.
    static func size(of url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return fileSize(url) }

        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                  options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) {
            for case let child as URL in en {
                let isReg = (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isReg { total += fileSize(child) }
            }
        }
        return total
    }

    /// Top-level children of a directory paired with their recursive sizes.
    static func children(of dir: URL) -> [(url: URL, size: UInt64)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: []) else { return [] }
        return entries.map { (url: $0, size: size(of: $0)) }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func lastAccessDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }
}
