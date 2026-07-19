import AppKit

protocol TrashFileOperating {
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws
}

struct FileManagerTrashFileOperator: TrashFileOperating {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }
}

protocol TrashRootResolving {
    func trashRoots() -> [URL]
}

protocol TrashRootFileSystem {
    func userTrashDirectory() throws -> URL
    var homeDirectory: URL { get }
    func directoryExists(at url: URL) -> Bool
}

struct FileManagerTrashRootFileSystem: TrashRootFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func userTrashDirectory() throws -> URL {
        try fileManager.url(for: .trashDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: false)
    }

    var homeDirectory: URL { fileManager.homeDirectoryForCurrentUser }

    func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

struct ProductionTrashRootResolver: TrashRootResolving {
    private let fileSystem: any TrashRootFileSystem

    init(fileSystem: any TrashRootFileSystem = FileManagerTrashRootFileSystem()) {
        self.fileSystem = fileSystem
    }

    func trashRoots() -> [URL] {
        do {
            return [try fileSystem.userTrashDirectory()]
        } catch {
            let fallback = fileSystem.homeDirectory
                .appendingPathComponent(".Trash", isDirectory: true)
            return fileSystem.directoryExists(at: fallback) ? [fallback] : []
        }
    }
}

enum TrashService {
    enum Classification: Equatable {
        case root
        case descendant
        case outside
    }

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
    static func clean(
        _ items: [ScanItem],
        fileOperator: any TrashFileOperating = FileManagerTrashFileOperator(),
        rootResolver: any TrashRootResolving = ProductionTrashRootResolver()
    ) -> Result {
        var result = Result()
        let roots = rootResolver.trashRoots()
        for item in items {
            do {
                switch classify(item.url, trashRoots: roots) {
                case .root:
                    result.failures.append(Failure(
                        url: item.url,
                        message: "The Trash root cannot itself be cleaned."
                    ))
                    continue
                case .descendant:
                    try fileOperator.removeItem(at: item.url)
                    result.permanentlyDeleted += 1
                case .outside:
                    try fileOperator.trashItem(at: item.url)
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
        classify(url, trashRoots: ProductionTrashRootResolver().trashRoots()) == .descendant
    }

    static func classify(_ url: URL, trashRoots: [URL]) -> Classification {
        let lexicalCandidate = url.standardizedFileURL.pathComponents
        let resolvedCandidate = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        for root in trashRoots {
            let lexicalRoot = root.standardizedFileURL.pathComponents
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents

            if lexicalCandidate == lexicalRoot, resolvedCandidate == resolvedRoot {
                return .root
            }
            if isStrictDescendant(lexicalCandidate, of: lexicalRoot),
               isStrictDescendant(resolvedCandidate, of: resolvedRoot) {
                return .descendant
            }
        }
        return .outside
    }

    private static func isStrictDescendant(_ candidate: [String], of root: [String]) -> Bool {
        candidate.count > root.count && candidate.prefix(root.count).elementsEqual(root)
    }
}
