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

    func testEveryMissingCLIIsUnavailableWithoutNetworkOrSignIn() async {
        for provider in AICodingProvider.allCases {
            let snapshot = await AIUsageFetcher.fetch(
                provider,
                transport: Stub(mustNotCall: true),
                homeDirectory: home,
                antigravityCLI: UnavailableCLI(),
                claudeCLI: UnavailableProvider(.claude),
                codexCLI: UnavailableProvider(.codex),
                grokCLI: UnavailableProvider(.grok),
                cursorCLI: UnavailableProvider(.cursor)
            )
            guard case .error(let message) = snapshot.status else {
                XCTFail("\(provider) incorrectly inferred sign-in state"); continue
            }
            XCTAssertTrue(message.contains("Usage unavailable") || message.contains("CLI"))
        }
    }

    func testFileTokensAndHTTPAreNeverUsedWhenACLIIsMissing() async throws {
        let fixtures = [
            ".claude/.credentials.json": #"{"accessToken":"fixture"}"#,
            ".codex/auth.json": #"{"access_token":"fixture"}"#,
            ".grok/auth.json": #"{"key":"fixture"}"#,
            ".cursor/auth.json": #"{"accessToken":"fixture"}"#
        ]
        for (path, json) in fixtures {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url)
        }
        for provider in [AICodingProvider.claude, .codex, .grok, .cursor] {
            let snapshot = await AIUsageFetcher.fetch(
                provider,
                transport: Stub(mustNotCall: true),
                homeDirectory: home
            )
            guard case .error = snapshot.status else {
                XCTFail("\(provider) used a file token instead of a CLI"); continue
            }
        }
    }

    private struct UnavailableCLI: AntigravityUsageReading {
        func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
            .failed(.antigravity, message: AICodingProvider.antigravity.usageUnavailableHint)
        }
    }

    private struct UnavailableProvider: ProviderUsageReading {
        var provider: AICodingProvider
        init(_ provider: AICodingProvider) { self.provider = provider }
        func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
            .failed(provider, message: provider.usageUnavailableHint)
        }
    }

    private struct Stub: AIUsageTransporting {
        var mustNotCall = false

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTAssertFalse(mustNotCall, "Usage must not initiate authentication or network traffic")
            throw URLError(.unsupportedURL)
        }
    }
}
