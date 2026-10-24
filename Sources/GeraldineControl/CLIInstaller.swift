import Foundation
import Darwin

enum CLIInstaller {
    static func install(source: URL, directory: URL) throws {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: source.path) else {
            throw failure("The source helper is not executable.")
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let destination = directory.appendingPathComponent("geraldine")
        var existing = stat()
        let exists = lstat(destination.path, &existing) == 0
        if !exists, errno != ENOENT { throw posixFailure() }
        if exists {
            guard existing.st_mode & S_IFMT == S_IFLNK, existing.st_uid == geteuid() else {
                throw failure("The destination already contains a file that this installer does not own.")
            }
            let rawTarget = try files.destinationOfSymbolicLink(atPath: destination.path)
            let target = URL(fileURLWithPath: rawTarget, relativeTo: directory).standardizedFileURL
            if target == source { return }
            guard isBundledHelper(target) else {
                throw failure("The destination is an unrelated symbolic link.")
            }
        }

        // Build the link beside its destination so replacement is atomic.
        // Never write executable bytes or alter the helper's permissions.
        let temporary = directory.appendingPathComponent(".geraldine-\(UUID().uuidString)")
        try files.createSymbolicLink(atPath: temporary.path, withDestinationPath: source.path)
        defer { try? files.removeItem(at: temporary) }
        if exists {
            var current = stat()
            guard lstat(destination.path, &current) == 0,
                  current.st_dev == existing.st_dev, current.st_ino == existing.st_ino,
                  current.st_mode & S_IFMT == S_IFLNK else {
                throw failure("The destination changed during installation; it was preserved.")
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw posixFailure() }
        } else {
            // RENAME_EXCL prevents a concurrently created regular file from
            // being overwritten after the initial existence check.
            guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixFailure() }
        }
    }

    private static func isBundledHelper(_ url: URL) -> Bool {
        url.lastPathComponent == "geraldine"
            && url.deletingLastPathComponent().lastPathComponent == "Helpers"
            && url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
            && url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app"
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "GeraldineCLI.install", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func posixFailure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
