import XCTest
@testable import Geraldine

final class AIUsageAntigravityCLITests: XCTestCase {
    private static let payload = """
    {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
      {"name":"Gemini Models","buckets":[
        {"id":"gemini-weekly","remaining_fraction":1,"reset_time":"2026-09-23T05:12:15Z"},
        {"id":"gemini-5h","remaining_fraction":0.75}]},
      {"name":"Claude and GPT models","buckets":[
        {"id":"3p-weekly","remaining_fraction":0.5},
        {"id":"3p-5h","remaining_fraction":0.01}]}
    ]}}}
    """

    func testAllFourBucketsKeepTheirGroupsAndPercentMeaning() throws {
        let now = Date(timeIntervalSince1970: 123)
        let snapshot = try AntigravityCLIUsage.parse(Data(Self.payload.utf8), now: now).get()
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(snapshot.displayWindows.map(\.remainingPercent), [100, 75, 50, 1])
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.sourceLabel, "Antigravity CLI")
    }

    func testRejectsModelResponsesMissingBucketsAndInvalidFractions() {
        for payload in [
            Self.payload.replacingOccurrences(of: #""num_turns":0"#, with: #""num_turns":1"#),
            Self.payload.replacingOccurrences(of: #""name":"usage""#, with: #""name":"other""#),
            Self.payload.replacingOccurrences(of: #""id":"3p-5h""#, with: #""id":"unknown""#),
            Self.payload.replacingOccurrences(of: #""remaining_fraction":0.01"#, with: #""remaining_fraction":2"#),
            "invalid JSON"
        ] {
            guard case .failure = AntigravityCLIUsage.parse(Data(payload.utf8), now: Date()) else {
                XCTFail("Must not manufacture quotas from invalid CLI output"); continue
            }
        }
    }

    func testFetcherUsesOnlyCLIUsageCommandAndNeverHTTPOrTokenFiles() async throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent(".local/bin/agy")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        [ "$#" = 4 ] && [ "$1" = "--print" ] && [ "$2" = "/usage" ] && [ "$3" = "--output-format" ] && [ "$4" = "json" ] || exit 9
        cat <<'QUOTA'
        \(Self.payload)
        QUOTA
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let snapshot = await AIUsageFetcher.fetch(.antigravity, transport: NoHTTP(), homeDirectory: home)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.count, 4)
    }

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Antigravity must only use its CLI")
            throw URLError(.unsupportedURL)
        }
    }
}
