import XCTest
import GeraldineControl
@testable import Geraldine

@MainActor
final class ControlScanCompletenessReviewTests: XCTestCase {
    func testAdapterKeepsEveryScannerItemAndDiagnostic() {
        let items = (0..<65).map {
            ScanItem(url: URL(fileURLWithPath: "/fixture/file-\($0)"), size: UInt64($0 + 1))
        }
        var diagnostics = ScanDiagnostics()
        for index in 0..<25 { diagnostics.noteSkipped("/fixture/skip-\(index)", message: "fixture") }
        let report = ControlScanReport.report(ScanReport(
            groups: [ScanGroup(title: "Fixture", icon: "doc", tint: .blue, items: items)],
            diagnostics: diagnostics
        ))
        XCTAssertEqual(report.json["groups"]?.arrayValue?.first?["items"]?.arrayValue?.count, 65)
        XCTAssertEqual(report.json["diagnostics"]?["skipped"]?.arrayValue?.count, 25)
        XCTAssertTrue(report.humanLines(title: "Fixture").contains { $0.contains("62 more items omitted") && $0.contains("--json includes all scanned items") })
    }

    func testRealLargeFileRequestScansOnlyTheFixtureAndLeavesFilesIntact() async throws {
        let root = try AppReviewFixtureRoot.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large-fixture.bin")
        let contents = Data(repeating: 0x41, count: 1_100_000)
        try contents.write(to: file)
        try Data("small".utf8).write(to: root.appendingPathComponent("small.txt"))
        let response = await ControlHost().handle(ControlRequest(
            command: "large-files", arguments: ["scan"], options: ["path": root.path, "minSizeMB": "1"]
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["minSizeMB"], .int(1))
        let rows = response.result?["groups"]?.arrayValue?.flatMap { $0["items"]?.arrayValue ?? [] }
        XCTAssertEqual(rows?.compactMap { $0["path"]?.stringValue }, [file.path])
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("small.txt")), "small")
    }

    func testNumericValidationUsesRepresentabilityRatherThanProductCeilings() {
        XCTAssertEqual(ControlRequestValidation.processSampleLimit(top: 201), 402)
        XCTAssertNil(ControlRequestValidation.processSampleLimit(top: Int.max))
        let largestMB = Int(UInt64.max / 1_000_000)
        XCTAssertEqual(ControlRequestValidation.largeFileMinimumBytes(megabytes: largestMB), UInt64(largestMB) * 1_000_000)
        XCTAssertNil(ControlRequestValidation.largeFileMinimumBytes(megabytes: largestMB + 1))
        XCTAssertNil(ControlRequestValidation.durationSeconds("inf"))
        XCTAssertNil(ControlRequestValidation.durationSeconds("1e300"))
        XCTAssertEqual(ControlRequestValidation.durationSeconds("5400.5"), 5400.5)
        XCTAssertEqual(ControlJSON.uint64(.infinity), 0)
        XCTAssertEqual(ControlJSON.uint64(.nan), 0)
        XCTAssertEqual(ControlJSON.uint64(Double(UInt64.max)), 0)
    }

    func testInvalidScanAndApplicationRequestsAreRejectedBeforeDispatch() {
        let requests = [
            ControlRequest(command: "widgets", arguments: ["show"]),
            ControlRequest(command: "widgets", arguments: ["move", "cpu"], options: ["position": "before"]),
            ControlRequest(command: "stats", arguments: ["gpu", "extra"]),
            ControlRequest(command: "usage", options: ["refresh": "yes"]),
            ControlRequest(command: "large-files", arguments: ["scan"], options: ["minSizeMB": String(Int.max)]),
            ControlRequest(command: "large-files", arguments: ["scan"], options: ["minSizeMB": "nan"]),
            ControlRequest(command: "large-files", arguments: ["scan"], options: ["minSizeMB": "-1"]),
            ControlRequest(command: "cleanup", arguments: ["scan"], options: ["delete": "true"]),
            ControlRequest(command: "open", arguments: ["not-a-page"]),
            ControlRequest(command: "status", arguments: ["extra"])
        ]
        for request in requests {
            XCTAssertNotNil(ControlRequestValidation.error(for: request), "\(request.command) \(request.arguments) \(request.options)")
        }
    }
}
