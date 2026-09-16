import XCTest
@testable import Geraldine

final class AIUsageClaudeCacheTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        home = root.appendingPathComponent("claude-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    private func write(account: String = "current", cachedAccount: String = "current",
                       timestamp: Double = 1_789_533_964_295, used: Double = 21) throws {
        let object: [String: Any] = [
            "oauthAccount": ["accountUuid": account],
            "cachedUsageUtilization": [
                "accountUuid": cachedAccount, "fetchedAtMs": timestamp,
                "utilization": [
                    "five_hour": ["utilization": used],
                    "seven_day": ["utilization": 6],
                    "limits": [["percent": 6, "scope": ["model": ["display_name": "Fable"]]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent(".claude.json"))
    }

    func testReadsUsageWithoutCredentialsOrNetworkAndPreservesTimestamp() async throws {
        try write()
        let snapshot = await AIUsageFetcher.fetchClaude(transport: NoNetwork(), now: Date(), homeDirectory: home)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 21)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "seven_day" })?.usedPercent, 6)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Fable" })?.usedPercent, 6)
        XCTAssertEqual(snapshot.fetchedAt?.timeIntervalSince1970, 1_789_533_964.295)
        XCTAssertEqual(snapshot.sourceLabel, ClaudeUsageCache.sourceLabel)
        XCTAssertNotNil(snapshot.cachedSourceDescription)
    }

    func testRejectsOtherAccountsAndSignedOutCache() throws {
        try write(cachedAccount: "previous")
        XCTAssertNil(ClaudeUsageCache.snapshot(homeDirectory: home))
        try write(account: "", cachedAccount: "")
        XCTAssertNil(ClaudeUsageCache.snapshot(homeDirectory: home))
        try Data(#"{"cachedUsageUtilization":{}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertNil(ClaudeUsageCache.snapshot(homeDirectory: home))
    }

    func testRejectsInvalidTimestampAndMalformedCache() throws {
        try write(timestamp: 0)
        XCTAssertNil(ClaudeUsageCache.snapshot(homeDirectory: home))
        try Data("invalid".utf8).write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertNil(ClaudeUsageCache.snapshot(homeDirectory: home))
    }

    func testRefreshRereadsCacheWithoutMakingOldDataLookFresh() throws {
        try write(timestamp: 1_000, used: 15)
        XCTAssertEqual(ClaudeUsageCache.snapshot(homeDirectory: home)?.fetchedAt, Date(timeIntervalSince1970: 1))
        try write(used: 23)
        XCTAssertEqual(ClaudeUsageCache.snapshot(homeDirectory: home)?.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 23)
    }

    func testMissingCacheDoesNotClaimUserIsSignedOut() async {
        let snapshot = await AIUsageFetcher.fetchClaude(transport: NoNetwork(), now: Date(), homeDirectory: home)
        guard case .error(let message) = snapshot.status else {
            return XCTFail("Unavailable usage must not be presented as signed out")
        }
        XCTAssertTrue(message.contains("/usage"))
    }

    private struct NoNetwork: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Cached usage must not access the network")
            throw URLError(.notConnectedToInternet)
        }
    }
}
