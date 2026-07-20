import XCTest
@testable import Geraldine

final class TrashServiceTests: XCTestCase {
    func testClassifiesOnlyStrictCanonicalDescendants() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)

        XCTAssertEqual(classify(root.appendingPathComponent("file"), root: root), .descendant)
        XCTAssertEqual(classify(root.appendingPathComponent("folder/file"), root: root), .descendant)
        XCTAssertEqual(classify(root, root: root), .root)
        XCTAssertEqual(classify(URL(fileURLWithPath: "/Users/test/.Trash-old/file"), root: root), .outside)
        XCTAssertEqual(classify(URL(fileURLWithPath: "/work/project/.Trash/file"), root: root), .outside)
    }

    func testLexicalDescendantResolvingOutsideTrashIsOutside() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent(".Trash", isDirectory: true)
            let outside = temporary.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data().write(to: outside.appendingPathComponent("file"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("escape"),
                withDestinationURL: outside
            )

            let candidate = root.appendingPathComponent("escape/file")
            XCTAssertEqual(classify(candidate, root: root), .outside)
        }
    }

    func testLexicalOutsiderResolvingInsideTrashIsOutside() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent(".Trash", isDirectory: true)
            let child = root.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data().write(to: child.appendingPathComponent("file"))
            let alias = temporary.appendingPathComponent("trash-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

            XCTAssertEqual(classify(alias.appendingPathComponent("folder/file"), root: root), .outside)
        }
    }

    func testTrashRootIsRefusedWithoutCallingFileOperations() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let fileOperator = RecordingTrashFileOperator()

        let result = TrashService.clean(
            [ScanItem(url: root, size: 100)],
            fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [root])
        )

        XCTAssertTrue(fileOperator.removed.isEmpty)
        XCTAssertTrue(fileOperator.trashed.isEmpty)
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.trashed, 0)
        XCTAssertEqual(result.permanentlyDeleted, 0)
        XCTAssertEqual(result.freed, 0)
        XCTAssertEqual(result.failures, [
            TrashService.Failure(url: root, message: "The Trash root cannot itself be cleaned.")
        ])
    }

    func testProductionResolverUsesSystemTrashWhenLookupSucceeds() {
        let systemTrash = URL(fileURLWithPath: "/system/trash")
        let fileSystem = FakeTrashRootFileSystem(result: .success(systemTrash))

        XCTAssertEqual(ProductionTrashRootResolver(fileSystem: fileSystem).trashRoots(), [systemTrash])
        XCTAssertEqual(fileSystem.directoryChecks, [])
    }

    func testProductionResolverUsesExistingHomeTrashAfterLookupFailure() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let expected = home.appendingPathComponent(".Trash", isDirectory: true)
        let fileSystem = FakeTrashRootFileSystem(
            result: .failure(TestError.expected),
            homeDirectory: home,
            existingDirectories: [expected]
        )

        XCTAssertEqual(ProductionTrashRootResolver(fileSystem: fileSystem).trashRoots(), [expected])
        XCTAssertEqual(fileSystem.directoryChecks, [expected])
    }

    func testProductionResolverReturnsNoRootsWhenFallbackIsUnavailable() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let expected = home.appendingPathComponent(".Trash", isDirectory: true)
        let fileSystem = FakeTrashRootFileSystem(
            result: .failure(TestError.expected),
            homeDirectory: home
        )

        XCTAssertEqual(ProductionTrashRootResolver(fileSystem: fileSystem).trashRoots(), [])
        XCTAssertEqual(fileSystem.directoryChecks, [expected])
    }

    func testNoResolvedRootsFailsClosedToReversibleTrash() {
        let item = ScanItem(url: URL(fileURLWithPath: "/Users/test/.Trash/file"), size: 12)
        let fileOperator = RecordingTrashFileOperator()

        let result = TrashService.clean(
            [item],
            fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [])
        )

        XCTAssertEqual(fileOperator.trashed, [item.url])
        XCTAssertTrue(fileOperator.removed.isEmpty)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.permanentlyDeleted, 0)
    }

    func testOutsideItemUsesOnlyReversibleTrashOperation() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let item = ScanItem(url: URL(fileURLWithPath: "/work/file"), size: 20)
        let fileOperator = RecordingTrashFileOperator()

        let result = TrashService.clean(
            [item], fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [root])
        )

        XCTAssertEqual(fileOperator.trashed, [item.url])
        XCTAssertTrue(fileOperator.removed.isEmpty)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.permanentlyDeleted, 0)
    }

    func testMoveToTrashUsesOnlyReversibleOperation() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let outside = ScanItem(url: URL(fileURLWithPath: "/work/file"), size: 20)
        let inside = ScanItem(url: root.appendingPathComponent("existing"), size: 30)
        let fileOperator = RecordingTrashFileOperator()

        let result = TrashService.moveToTrash(
            [outside, inside],
            fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [root])
        )

        XCTAssertEqual(fileOperator.trashed, [outside.url])
        XCTAssertTrue(fileOperator.removed.isEmpty)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.permanentlyDeleted, 0)
        XCTAssertEqual(result.freed, 0)
        XCTAssertEqual(result.failures, [
            TrashService.Failure(url: inside.url, message: "The item is already in the Trash.")
        ])
    }

    func testTrashDescendantUsesOnlyPermanentRemoval() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let item = ScanItem(url: root.appendingPathComponent("file"), size: 30)
        let fileOperator = RecordingTrashFileOperator()

        let result = TrashService.clean(
            [item], fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [root])
        )

        XCTAssertEqual(fileOperator.removed, [item.url])
        XCTAssertTrue(fileOperator.trashed.isEmpty)
        XCTAssertEqual(result.trashed, 0)
        XCTAssertEqual(result.permanentlyDeleted, 1)
    }

    func testMixedSuccessAndFailurePreservesAccountingAndContinues() {
        let root = URL(fileURLWithPath: "/Users/test/.Trash", isDirectory: true)
        let failedOutside = ScanItem(url: URL(fileURLWithPath: "/work/fail-first"), size: 10)
        let removed = ScanItem(url: root.appendingPathComponent("removed"), size: 20)
        let failedInside = ScanItem(url: root.appendingPathComponent("fail-inside"), size: 30)
        let trashed = ScanItem(url: URL(fileURLWithPath: "/work/trashed"), size: 40)
        let fileOperator = RecordingTrashFileOperator(failing: [failedOutside.url, failedInside.url])

        let result = TrashService.clean(
            [failedOutside, removed, failedInside, trashed],
            fileOperator: fileOperator,
            rootResolver: FixedTrashRootResolver(roots: [root])
        )

        XCTAssertEqual(fileOperator.trashed, [failedOutside.url, trashed.url])
        XCTAssertEqual(fileOperator.removed, [removed.url, failedInside.url])
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.trashed, 1)
        XCTAssertEqual(result.permanentlyDeleted, 1)
        XCTAssertEqual(result.freed, 60)
        XCTAssertEqual(result.failures.map(\.url), [failedOutside.url, failedInside.url])
        XCTAssertEqual(result.failures.map(\.message), ["Injected failure", "Injected failure"])
    }

    private func classify(_ candidate: URL, root: URL) -> TrashService.Classification {
        TrashService.classify(candidate, trashRoots: [root])
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeraldineTrashService-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

private struct FixedTrashRootResolver: TrashRootResolving {
    let roots: [URL]
    func trashRoots() -> [URL] { roots }
}

private final class RecordingTrashFileOperator: TrashFileOperating {
    private let failing: Set<URL>
    private(set) var removed: [URL] = []
    private(set) var trashed: [URL] = []

    init(failing: Set<URL> = []) {
        self.failing = failing
    }

    func removeItem(at url: URL) throws {
        removed.append(url)
        if failing.contains(url) { throw TestError.injected }
    }

    func trashItem(at url: URL) throws {
        trashed.append(url)
        if failing.contains(url) { throw TestError.injected }
    }
}

private final class FakeTrashRootFileSystem: TrashRootFileSystem {
    let result: Result<URL, Error>
    let homeDirectory: URL
    let existingDirectories: Set<URL>
    private(set) var directoryChecks: [URL] = []

    init(
        result: Result<URL, Error>,
        homeDirectory: URL = URL(fileURLWithPath: "/Users/test", isDirectory: true),
        existingDirectories: Set<URL> = []
    ) {
        self.result = result
        self.homeDirectory = homeDirectory
        self.existingDirectories = existingDirectories
    }

    func userTrashDirectory() throws -> URL { try result.get() }

    func directoryExists(at url: URL) -> Bool {
        directoryChecks.append(url)
        return existingDirectories.contains(url)
    }
}

private enum TestError: LocalizedError {
    case expected
    case injected

    var errorDescription: String? {
        switch self {
        case .expected: "Expected failure"
        case .injected: "Injected failure"
        }
    }
}
