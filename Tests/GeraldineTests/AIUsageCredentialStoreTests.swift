import XCTest
@testable import Geraldine

final class AIUsageCredentialStoreTests: XCTestCase {
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
            for forbidden in [
                "import Security", "SecItemCopyMatching", "SecKeychain", "/usr/bin/security",
                "cursor_login", "agent login", "authenticateWithExistingLogin",
                "AIUsageCredentialStore", "CURSOR_AUTH_TOKEN", "claudeAiOauth", ".credentials.json",
                "cursorAuth/accessToken", "tokens\", \"access_token"
            ] {
                XCTAssertFalse(source.contains(forbidden), "AI usage must not start a login flow in \(file): \(forbidden)")
            }
            for endpoint in httpEndpoints {
                XCTAssertFalse(source.contains(endpoint), "AI usage must not call \(endpoint) in \(file)")
            }
        }
    }

}
