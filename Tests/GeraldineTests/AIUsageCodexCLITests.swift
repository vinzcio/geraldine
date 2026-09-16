import XCTest
@testable import Geraldine

final class AIUsageCodexCLITests: XCTestCase {
    private static let payload = """
    {"id":1,"result":{"userAgent":"fixture"}}
    {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1789812650},"secondary":null,"planType":"pro"},"rateLimitsByLimitId":{}}}
    """

    func testParsesWeeklyWindowFromAppServerRateLimits() throws {
        let now = Date(timeIntervalSince1970: 40)
        let snapshot = try CodexCLIUsage.parse(Data(Self.payload.utf8), now: now).get()
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.sourceLabel, CodexCLIUsage.sourceLabel)
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.windows.first?.id, "primary")
        XCTAssertEqual(snapshot.windows.first?.title, "Weekly")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 81)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 19)
        XCTAssertEqual(snapshot.windows.first?.durationSeconds, 604_800)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testRejectsMissingRateLimitsAndNonJSON() {
        for payload in [
            #"{"id":1,"result":{}}"#,
            #"{"id":2,"result":{}}"#,
            "not json"
        ] {
            guard case .failure = CodexCLIUsage.parse(Data(payload.utf8), now: Date()) else {
                XCTFail("Must not manufacture Codex quotas"); continue
            }
        }
    }

    func testFetcherUsesAppServerStdioAndNeverHTTP() async throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("codex-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = "app-server" ] && [ "$2" = "--stdio" ] || exit 9
        read _init
        echo '{"id":1,"result":{}}'
        read _initialized
        read _usage
        cat <<'USAGE'
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1789812650},"planType":"pro"}}}
        USAGE
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let snapshot = await AIUsageFetcher.fetch(
            .codex,
            transport: NoHTTP(),
            now: Date(timeIntervalSince1970: 11),
            homeDirectory: home
        )
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 19)
        XCTAssertEqual(snapshot.sourceLabel, CodexCLIUsage.sourceLabel)
    }

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Codex must only use its CLI")
            throw URLError(.unsupportedURL)
        }
    }
}
