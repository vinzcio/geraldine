import XCTest
@testable import Geraldine

final class AIUsagePassiveSourceTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        home = root.appendingPathComponent("passive-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    private func credentials() throws {
        let fixtures = [
            ".claude/.credentials.json": #"{"accessToken":"fixture"}"#,
            ".codex/auth.json": #"{"access_token":"fixture"}"#,
            ".grok/auth.json": #"{"key":"fixture"}"#,
            ".cursor/auth.json": #"{"accessToken":"fixture"}"#,
            ".gemini/oauth_creds.json": #"{"access_token":"fixture"}"#
        ]
        for (path, json) in fixtures {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
        }
    }

    func testEveryMissingLocalSourceIsUnavailableWithoutNetworkOrSignIn() async {
        for provider in AICodingProvider.allCases {
            let snapshot = await AIUsageFetcher.fetch(provider, transport: Stub(mustNotCall: true),
                                                       homeDirectory: home, languageServer: { nil })
            guard case .error(let message) = snapshot.status else {
                XCTFail("\(provider) incorrectly inferred sign-in state"); continue
            }
            XCTAssertTrue(message.contains("Usage unavailable"))
        }
    }

    func testRejectedUsageAccessDoesNotClaimAnyProviderIsSignedOut() async throws {
        try credentials()
        for code in [401, 403] {
            for provider in AICodingProvider.allCases {
                let snapshot = await AIUsageFetcher.fetch(provider, transport: Stub(code: code),
                                                           homeDirectory: home, languageServer: { nil })
                guard case .error(let message) = snapshot.status else {
                    XCTFail("\(provider) incorrectly inferred sign-in state"); continue
                }
                XCTAssertTrue(message.contains("usage access was rejected"))
            }
        }
    }

    func testExistingCredentialsAreReusedWithoutConnectionHandshake() async throws {
        try credentials()
        for provider in [AICodingProvider.codex, .grok, .cursor] {
            let snapshot = await AIUsageFetcher.fetch(provider, transport: Stub(),
                                                       homeDirectory: home, languageServer: { nil })
            XCTAssertEqual(snapshot.status, .ready, "\(provider)")
        }
    }

    func testAntigravityReadsRunningLocalServerWithoutCredential() async {
        let snapshot = await AIUsageFetcher.fetch(.antigravity, transport: Stub(local: true),
                                                   homeDirectory: home,
                                                   languageServer: { .init(port: 12345, csrf: "local-fixture") })
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.remainingPercent, 40)
    }

    private struct Stub: AIUsageTransporting {
        var code = 200
        var mustNotCall = false
        var local = false

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTAssertFalse(mustNotCall, "Missing source must not initiate authentication or network traffic")
            let url = try XCTUnwrap(request.url)
            var body = "{}"
            if local {
                XCTAssertEqual(url.host, "127.0.0.1")
                XCTAssertTrue(url.path.hasSuffix("/GetUserStatus"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "local-fixture")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                body = #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":0.4}}}}"#
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
                switch url.host {
                case "chatgpt.com":
                    XCTAssertEqual(url.path, "/backend-api/wham/usage")
                    body = #"{"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}}"#
                case "cli-chat-proxy.grok.com":
                    XCTAssertTrue(["/v1/billing", "/v1/user"].contains(url.path))
                    body = #"{"creditUsagePercent":10}"#
                case "api2.cursor.sh":
                    XCTAssertTrue(url.path.hasSuffix("/GetCurrentPeriodUsage"))
                    body = #"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":30,"totalPercentUsed":28}}"#
                default:
                    XCTAssertNotEqual(code, 200, "Unexpected provider endpoint")
                }
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
}
