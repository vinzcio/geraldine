import XCTest
@testable import Geraldine
import Darwin

final class LoginItemsScanSafetyTests: XCTestCase {
    func testValidPlistsPreserveMetadataFallbacksAndProgramPrecedence() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Enabled", under: root)
        let preferredURL = directory.appendingPathComponent("preferred.plist")
        let fallbackURL = directory.appendingPathComponent("fallback.plist")
        try writePlist([
            "Label": "com.example.preferred",
            "Program": "/usr/local/bin/preferred",
            "ProgramArguments": ["/usr/local/bin/fallback", "--ignored"]
        ], to: preferredURL)
        try writePlist([
            "ProgramArguments": ["/usr/bin/from-arguments", "--flag"]
        ], to: fallbackURL)

        let result = LoginItemsViewModel.scan(sources: [
            LoginItemsScanSource(directory: directory, scope: .user, enabled: true)
        ])
        let itemsByFilename = Dictionary(
            uniqueKeysWithValues: result.items.map { ($0.plistURL.lastPathComponent, $0) }
        )

        XCTAssertEqual(result.diagnostics.scannedItems, 2)
        XCTAssertEqual(result.diagnostics.skippedTotal, 0)
        XCTAssertTrue(result.diagnostics.skipped.isEmpty)
        XCTAssertNotNil(result.diagnostics.finishedAt)
        XCTAssertEqual(itemsByFilename["preferred.plist"]?.label, "com.example.preferred")
        XCTAssertEqual(itemsByFilename["preferred.plist"]?.program, "/usr/local/bin/preferred")
        XCTAssertEqual(itemsByFilename["fallback.plist"]?.label, "fallback")
        XCTAssertEqual(itemsByFilename["fallback.plist"]?.program, "/usr/bin/from-arguments")
    }

    func testAllFourSourceMappingsArePreserved() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let enabledUser = try makeDirectory(named: "EnabledUser", under: root)
        let disabledUser = try makeDirectory(named: "DisabledUser", under: root)
        let global = try makeDirectory(named: "Global", under: root)
        let daemon = try makeDirectory(named: "Daemon", under: root)
        try writePlist(["Label": "enabled.user"], to: enabledUser.appendingPathComponent("enabled.plist"))
        try writePlist(["Label": "disabled.user"], to: disabledUser.appendingPathComponent("disabled.plist"))
        try writePlist(["Label": "global.item"], to: global.appendingPathComponent("global.plist"))
        try writePlist(["Label": "daemon.item"], to: daemon.appendingPathComponent("daemon.plist"))

        let result = LoginItemsViewModel.scan(sources: [
            LoginItemsScanSource(directory: enabledUser, scope: .user, enabled: true),
            LoginItemsScanSource(directory: disabledUser, scope: .user, enabled: false),
            LoginItemsScanSource(directory: global, scope: .global, enabled: true),
            LoginItemsScanSource(directory: daemon, scope: .daemon, enabled: true)
        ])
        let mappings = Dictionary(
            uniqueKeysWithValues: result.items.map { ($0.label, SourceMapping(scope: $0.scope, enabled: $0.enabled)) }
        )

        XCTAssertEqual(result.diagnostics.scannedItems, 4)
        XCTAssertEqual(result.diagnostics.skippedTotal, 0)
        XCTAssertEqual(mappings["enabled.user"], SourceMapping(scope: .user, enabled: true))
        XCTAssertEqual(mappings["disabled.user"], SourceMapping(scope: .user, enabled: false))
        XCTAssertEqual(mappings["global.item"], SourceMapping(scope: .global, enabled: true))
        XCTAssertEqual(mappings["daemon.item"], SourceMapping(scope: .daemon, enabled: true))
    }

    func testSymlinkCandidateIsRejectedAndDiagnosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let targetURL = root.appendingPathComponent("target.xml")
        let symlinkURL = directory.appendingPathComponent("linked.plist")
        try writePlist(["Label": "linked.item"], to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let result = scan(directory)

        assertSingleRejection(
            result,
            path: symlinkURL.path,
            message: "Could not open this plist safely."
        )
    }

    func testPlistDirectoryIsRejectedAndDiagnosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let candidateURL = try makeDirectory(named: "folder.plist", under: directory)

        let result = scan(directory)

        assertSingleRejection(
            result,
            path: candidateURL.path,
            message: "This plist is not a regular file."
        )
    }

    func testFIFOCandidateCompletesOffMainThreadAndIsDiagnosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let fifoURL = directory.appendingPathComponent("pipe.plist")
        guard Darwin.mkfifo(fifoURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let source = LoginItemsScanSource(directory: directory, scope: .user, enabled: true)
        let resultBox = ScanResultBox()
        let completed = expectation(description: "Nonblocking FIFO scan completed")

        DispatchQueue.global(qos: .userInitiated).async {
            resultBox.store(LoginItemsViewModel.scan(sources: [source]))
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        guard let result = resultBox.load() else {
            return XCTFail("FIFO scan did not produce a result")
        }
        assertSingleRejection(
            result,
            path: fifoURL.path,
            message: "This plist is not a regular file."
        )
    }

    func testMalformedPlistIsRejectedWhileNonPlistFileIsIgnored() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let malformedURL = directory.appendingPathComponent("malformed.plist")
        let ignoredURL = directory.appendingPathComponent("ignored.PLIST")
        try Data("not a property list".utf8).write(to: malformedURL)
        try Data("also not a property list".utf8).write(to: ignoredURL)

        let result = scan(directory)

        assertSingleRejection(
            result,
            path: malformedURL.path,
            message: "This file is not a valid property list."
        )
    }

    func testPropertyListThatIsNotDictionaryIsRejectedAndDiagnosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let candidateURL = directory.appendingPathComponent("array.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["not", "a", "dictionary"],
            format: .xml,
            options: 0
        )
        try data.write(to: candidateURL)

        let result = scan(directory)

        assertSingleRejection(
            result,
            path: candidateURL.path,
            message: "This property list is not a dictionary."
        )
    }

    func testNonPlistFileIsIgnoredWithoutDiagnostics() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("ignored.txt"))

        let result = scan(directory)

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.diagnostics.scannedItems, 0)
        XCTAssertEqual(result.diagnostics.skippedTotal, 0)
        XCTAssertTrue(result.diagnostics.skipped.isEmpty)
        XCTAssertNotNil(result.diagnostics.finishedAt)
    }

    func testSparseFileAtApprovedMaximumPlusOneIsRejectedAndDiagnosed() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = try makeDirectory(named: "Scan", under: root)
        let oversizedURL = directory.appendingPathComponent("oversized.plist")
        try createSparseFile(
            at: oversizedURL,
            byteCount: LoginItemsViewModel.maximumLoginItemPlistBytes + 1
        )

        let result = scan(directory)

        assertSingleRejection(
            result,
            path: oversizedURL.path,
            message: "This plist exceeds the approved size limit."
        )
    }

    private func scan(_ directory: URL) -> LoginItemsScanResult {
        LoginItemsViewModel.scan(sources: [
            LoginItemsScanSource(directory: directory, scope: .user, enabled: true)
        ])
    }

    private func assertSingleRejection(
        _ result: LoginItemsScanResult,
        path: String,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(result.items.isEmpty, file: file, line: line)
        XCTAssertEqual(result.diagnostics.scannedItems, 1, file: file, line: line)
        XCTAssertEqual(result.diagnostics.skippedTotal, 1, file: file, line: line)
        XCTAssertEqual(result.diagnostics.skipped.count, 1, file: file, line: line)
        guard let diagnosedPath = result.diagnostics.skipped.first?.path else {
            return XCTFail("Rejected candidate did not retain its path", file: file, line: line)
        }
        var diagnosedInfo = stat()
        var expectedInfo = stat()
        XCTAssertEqual(Darwin.lstat(diagnosedPath, &diagnosedInfo), 0, file: file, line: line)
        XCTAssertEqual(Darwin.lstat(path, &expectedInfo), 0, file: file, line: line)
        XCTAssertEqual(diagnosedInfo.st_dev, expectedInfo.st_dev, file: file, line: line)
        XCTAssertEqual(diagnosedInfo.st_ino, expectedInfo.st_ino, file: file, line: line)
        XCTAssertEqual(result.diagnostics.skipped.first?.message, message, file: file, line: line)
        XCTAssertNotNil(result.diagnostics.finishedAt, file: file, line: line)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GeraldineLoginItemsScanSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDirectory(named name: String, under root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }

    private func createSparseFile(at url: URL, byteCount: Int) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.ftruncate(descriptor, off_t(byteCount)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct SourceMapping: Equatable {
    let scope: LaunchItem.Scope
    let enabled: Bool
}

private final class ScanResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: LoginItemsScanResult?

    func store(_ result: LoginItemsScanResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> LoginItemsScanResult? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
