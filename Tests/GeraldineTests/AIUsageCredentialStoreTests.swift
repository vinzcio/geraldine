import XCTest
import SQLite3
@testable import Geraldine

final class AIUsageCredentialStoreTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        home = root.appendingPathComponent("credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }

    func testMissingCredentialsStayUnavailableAcrossRepeatedDiscovery() {
        for _ in 0..<3 {
            for provider in AICodingProvider.allCases {
                XCTAssertNil(AIUsageCredentialStore.token(for: provider, homeDirectory: home))
            }
        }
    }

    func testExistingFileCredentialsRemainReadableForEveryProvider() throws {
        try write(".claude/.credentials.json", #"{"claudeAiOauth":{"accessToken":"claude-fixture"}}"#)
        try write(".codex/auth.json", #"{"tokens":{"access_token":"codex-fixture","account_id":"account-fixture"}}"#)
        try write(".grok/auth.json", #"{"key":"grok-fixture"}"#)
        try write(".cursor/auth.json", #"{"accessToken":"cursor-fixture"}"#)
        try write(".gemini/oauth_creds.json", #"{"token":{"access_token":"antigravity-fixture"}}"#)
        for provider in AICodingProvider.allCases where provider != .antigravity {
            XCTAssertEqual(AIUsageCredentialStore.token(for: provider, homeDirectory: home)?.value,
                           "\(provider.rawValue)-fixture")
        }
        XCTAssertNil(AIUsageCredentialStore.token(for: .antigravity, homeDirectory: home))
        XCTAssertEqual(AIUsageCredentialStore.token(for: .codex, homeDirectory: home)?.accountID,
                       "account-fixture")
    }

    func testMalformedCredentialsDoNotFallBackToKeychain() throws {
        for path in [".claude/.credentials.json", ".codex/auth.json", ".grok/auth.json",
                     ".cursor/auth.json", ".gemini/oauth_creds.json"] {
            try write(path, "invalid JSON")
        }
        for provider in AICodingProvider.allCases {
            XCTAssertNil(AIUsageCredentialStore.token(for: provider, homeDirectory: home))
        }
    }

    func testCursorDatabaseCredentialsRemainReadable() throws {
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'cursor-db-fixture');", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(AIUsageCredentialStore.token(for: .cursor, homeDirectory: home)?.value, "cursor-db-fixture")
    }

    func testCredentialSourceCannotReintroduceTheKeychainFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/Geraldine/Services/AIUsage/AIUsageSources.swift",
            "Sources/Geraldine/Services/AIUsage/AgentCLI.swift",
            "Sources/Geraldine/Services/AIUsage/ClaudeCLIUsage.swift",
            "Sources/Geraldine/Services/AIUsage/CodexCLIUsage.swift",
            "Sources/Geraldine/Services/AIUsage/GrokCLIUsage.swift",
            "Sources/Geraldine/Services/AIUsage/CursorCLIUsage.swift",
            "Sources/Geraldine/Services/AIUsage/AntigravityCLIUsage.swift"
        ]
        let httpEndpoints = [
            "api.anthropic.com", "chatgpt.com", "cli-chat-proxy.grok.com",
            "api2.cursor.sh", "cursor.com/api/usage"
        ]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file))
            for forbidden in ["import Security", "SecItemCopyMatching", "SecKeychain", "/usr/bin/security"] {
                XCTAssertFalse(source.contains(forbidden), "AI usage must not access Keychain in \(file): \(forbidden)")
            }
            for endpoint in httpEndpoints {
                XCTAssertFalse(source.contains(endpoint), "AI usage must not call \(endpoint) in \(file)")
            }
        }
    }

    private func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
