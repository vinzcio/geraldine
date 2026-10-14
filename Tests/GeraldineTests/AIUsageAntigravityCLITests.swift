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

    /// agy 1.3.5 once the Claude/GPT weekly limit is spent: the 5-hour bucket
    /// is disabled but still reports remaining_fraction 1.
    func testDisabledFiveHourLimitDrawsNoRow() throws {
        let payload = """
        {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[
            {"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-21T10:51:42Z"},
            {"id":"gemini-5h","window":"5h","remaining_fraction":1,"reset_time":"2026-10-14T15:51:42Z"}]},
          {"name":"Claude and GPT models","buckets":[
            {"id":"3p-weekly","window":"weekly","remaining_fraction":0,"reset_time":"2026-10-16T12:12:03Z"},
            {"id":"3p-5h","window":"5h","disabled":true,"remaining_fraction":1,
             "description":"You have hit your weekly limit, the 5-hour limit does not currently apply."}]}
        ]}}}
        """
        let snapshot = try AntigravityCLIUsage.parse(Data(payload.utf8), now: Date(timeIntervalSince1970: 1_791_950_000)).get()
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly"])
        XCTAssertEqual(snapshot.displayWindows.map(\.remainingPercent), [100, 100, 0])
        XCTAssertEqual(snapshot.headline?.id, "3p-weekly")
    }

    func testFailedCheckNamesWhatWentWrong() throws {
        func message(_ error: String) throws -> String? {
            let data = try JSONSerialization.data(withJSONObject: ["status": "ERROR", "num_turns": 0, "error": error])
            return AntigravityCLIUsage.failureMessage(data)
        }
        // The errors agy printed this week.
        XCTAssertEqual(try message("/usage failed: retrieving quota summary: failed to retrieve user quota summary: failed to get load code assist response: UNAVAILABLE (code 503): The service is currently unavailable."),
                       "Antigravity's server is unavailable (HTTP 503).")
        XCTAssertEqual(try message("Eligibility check failed: UNAVAILABLE (code 503): The service is currently unavailable."),
                       "Antigravity's server is unavailable (HTTP 503).")
        XCTAssertEqual(try message("/usage failed: retrieving quota summary: failed to retrieve user quota summary: UNKNOWN (code 500): Unknown Error."),
                       "Antigravity's server returned an error (HTTP 500).")
        XCTAssertEqual(try message(#"Eligibility check failed: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": dial tcp: lookup daily-cloudcode-pa.googleapis.com: no such host"#),
                       "Antigravity CLI could not reach its server.")
        XCTAssertEqual(try message("silent auth failed"), "Antigravity CLI: silent auth failed")
        XCTAssertNil(AntigravityCLIUsage.failureMessage(Data("not JSON".utf8)))
        XCTAssertNil(AntigravityCLIUsage.failureMessage(Data(Self.payload.utf8)))
    }

    func testFetcherUsesOnlyCLIUsageCommandAndNeverHTTPOrTokenFiles() async throws {
        let home = try fakeHome(agy: """
        #!/bin/sh
        [ "$#" = 4 ] && [ "$1" = "--print" ] && [ "$2" = "/usage" ] && [ "$3" = "--output-format" ] && [ "$4" = "json" ] || exit 9
        cat <<'QUOTA'
        \(Self.payload)
        QUOTA
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = await AIUsageFetcher.fetch(.antigravity, transport: NoHTTP(), homeDirectory: home)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.count, 4)
    }

    func testServerErrorReplacesTheRunUsageHint() async throws {
        let home = try fakeHome(agy: """
        #!/bin/sh
        echo '{"status":"ERROR","error":"/usage failed: retrieving quota summary: UNAVAILABLE (code 503): The service is currently unavailable.","num_turns":0}'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let snapshot = await AntigravityCLIUsage().snapshot(homeDirectory: home, now: Date())
        XCTAssertEqual(snapshot.status, .error("Antigravity's server is unavailable (HTTP 503)."))
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    // The fake CLIs write PIDs to their working directory, the fake home:
    // they inherit the real HOME.

    func testStuckCLIIsStoppedAtTheDeadline() async throws {
        let home = try fakeHome(agy: """
        #!/bin/sh
        echo $$ > agy.pid
        exec sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let started = Date()
        let snapshot = await AntigravityCLIUsage(timeout: 1).snapshot(homeDirectory: home, now: Date())
        XCTAssertEqual(snapshot.status, .error("Antigravity CLI did not answer within 1 seconds."))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let pid = try XCTUnwrap(Int32(String(contentsOf: home.appendingPathComponent("agy.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "The stuck CLI must not outlive its check")
    }

    /// agy can leave a helper running that inherited its stdout. The answer
    /// is complete when agy exits, not when the helper does.
    func testHelperHoldingStdoutDoesNotDelayTheAnswer() async throws {
        let home = try fakeHome(agy: """
        #!/bin/sh
        sleep 30 &
        echo $! > helper.pid
        cat <<'QUOTA'
        \(Self.payload)
        QUOTA
        """)
        defer { try? FileManager.default.removeItem(at: home) }
        let started = Date()
        let snapshot = await AntigravityCLIUsage(timeout: 20).snapshot(homeDirectory: home, now: Date())
        let elapsed = Date().timeIntervalSince(started)
        if let text = try? String(contentsOf: home.appendingPathComponent("helper.pid"), encoding: .utf8),
           let helper = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(helper, SIGTERM)
        }
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertLessThan(elapsed, 10)
    }

    /// An isolated home whose only agy is the given script.
    private func fakeHome(agy script: String) throws -> URL {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("agy-\(UUID().uuidString)")
        let executable = home.appendingPathComponent(".local/bin/agy")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return home
    }

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Antigravity must only use its CLI")
            throw URLError(.unsupportedURL)
        }
    }
}
