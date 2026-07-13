import Foundation

struct ScanIssue: Identifiable, Hashable {
    let path: String
    let message: String

    var id: String { "\(path)|\(message)" }

    init(url: URL, error: Error) {
        path = url.path
        message = (error as NSError).localizedDescription
    }

    init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

struct ScanDiagnostics: Hashable {
    var scannedItems = 0
    var skipped: [ScanIssue] = []
    /// Total skips, including those beyond the capped `skipped` sample list.
    var skippedTotal = 0
    var failure: String?
    var cancelled = false
    var finishedAt: Date?

    static let empty = ScanDiagnostics()

    /// Diagnostics for a scan the user stopped before it produced results.
    static func cancelledScan() -> ScanDiagnostics {
        var diagnostics = ScanDiagnostics()
        diagnostics.finish(cancelled: true)
        return diagnostics
    }

    var hasVisibleIssues: Bool {
        cancelled || failure != nil || !skipped.isEmpty
    }

    mutating func noteScanned() {
        scannedItems += 1
    }

    mutating func noteSkipped(_ url: URL, _ error: Error) {
        skippedTotal += 1
        guard skipped.count < 25 else { return }
        skipped.append(ScanIssue(url: url, error: error))
    }

    mutating func noteSkipped(_ path: String, message: String) {
        skippedTotal += 1
        guard skipped.count < 25 else { return }
        skipped.append(ScanIssue(path: path, message: message))
    }

    mutating func finish(cancelled: Bool = false) {
        self.cancelled = cancelled
        finishedAt = Date()
    }
}

enum DiskScan {
    /// Allocated size of a single file (falls back through size keys).
    static func fileSize(_ url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ])
        return UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
    }

    /// Recursively sums sizes under a URL. Best-effort; skips unreadable items.
    /// Package contents (.app bundles etc.) are skipped unless
    /// `includingPackageContents` is set — cleanup-style scans treat a package as
    /// one opaque item, storage-style measurements want its true footprint.
    static func size(of url: URL, includingPackageContents: Bool = false) -> UInt64 {
        var diagnostics = ScanDiagnostics()
        return size(of: url, includingPackageContents: includingPackageContents, diagnostics: &diagnostics)
    }

    static func size(of url: URL, includingPackageContents: Bool = false,
                     diagnostics: inout ScanDiagnostics) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return fileSize(url) }

        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        var skippedIssues: [ScanIssue] = []
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                  options: includingPackageContents ? [] : [.skipsPackageDescendants],
                                  errorHandler: { skippedURL, error in
                                      skippedIssues.append(ScanIssue(url: skippedURL, error: error))
                                      return true
                                  }) {
            for case let child as URL in en {
                if Task.isCancelled { break }
                diagnostics.noteScanned()
                let isReg = (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isReg { total += fileSize(child) }
            }
            for issue in skippedIssues {
                diagnostics.noteSkipped(issue.path, message: issue.message)
            }
        } else {
            diagnostics.noteSkipped(url.path, message: "Could not read this folder.")
        }
        return total
    }

    /// Top-level children of a directory paired with their recursive sizes.
    static func children(of dir: URL) -> [(url: URL, size: UInt64)] {
        var diagnostics = ScanDiagnostics()
        return children(of: dir, diagnostics: &diagnostics)
    }

    static func children(of dir: URL, diagnostics: inout ScanDiagnostics) -> [(url: URL, size: UInt64)] {
        let fm = FileManager.default
        do {
            let entries = try fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [])
            return entries.map {
                diagnostics.noteScanned()
                return (url: $0, size: size(of: $0, diagnostics: &diagnostics))
            }
        } catch {
            diagnostics.noteSkipped(dir, error)
            return []
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func lastAccessDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }
}
