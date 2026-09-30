import XCTest
@testable import Geraldine

final class AIUsageAccountsTests: XCTestCase {
    func testDiscoversSiblingLoginsWithoutOpeningCredentials() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"oauthAccount":{"emailAddress":"team@example.com","organizationType":"claude_team","organizationName":"Example Co"}}"#,
                  to: ".claude.json", in: home)
        try write(#"{"oauthAccount":{"emailAddress":"max@example.com","organizationType":"claude_max"}}"#,
                  to: ".claude-fasaj/.claude.json", in: home)
        try write(#"{"settings":true}"#, to: ".claude-empty/.claude.json", in: home)
        // Unreadable auth files still count: discovery checks presence and never opens them.
        try write("{}", to: ".codex/auth.json", in: home, permissions: 0o000)
        try write("{}", to: ".codex-work/auth.json", in: home, permissions: 0o000)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex-stale"),
                                                withIntermediateDirectories: true)

        let accounts = AIUsageAccountDiscovery.accounts(userHome: home)

        XCTAssertEqual(accounts.map(\.id), ["antigravity", "claude", "claude.fasaj", "codex", "codex.work", "grok", "cursor"])
        XCTAssertEqual(name(of: "claude", in: accounts), "Example Co")
        XCTAssertEqual(name(of: "claude.fasaj", in: accounts), "Fasaj")
        XCTAssertEqual(name(of: "codex", in: accounts), "Personal")
        XCTAssertEqual(name(of: "codex.work", in: accounts), "Work")
    }

    func testPersonalDefaultYieldsItsNameToASiblingCalledPersonal() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_max","organizationName":"me@example.com's Organization"}}"#,
                  to: ".claude.json", in: home)
        try write("{}", to: ".codex/auth.json", in: home)
        try write("{}", to: ".codex-personal/auth.json", in: home)

        let accounts = AIUsageAccountDiscovery.accounts(userHome: home)

        XCTAssertEqual(name(of: "claude", in: accounts), "Personal")
        XCTAssertEqual(name(of: "codex", in: accounts), "Default")
        XCTAssertEqual(name(of: "codex.personal", in: accounts), "Personal")
    }

    @MainActor
    func testTilesUseAccountNamesOnlyWhenAProviderHasSeveralLogins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"oauthAccount":{"emailAddress":"team@example.com","organizationType":"claude_team","organizationName":"Example Co"}}"#,
                  to: ".claude.json", in: home)
        try write(#"{"oauthAccount":{"emailAddress":"max@example.com"}}"#, to: ".claude-fasaj/.claude.json", in: home)
        let suiteName = "AIUsageAccountNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let monitor = AIUsageMonitor(defaults: defaults, userHome: home) { identity, _ in
            .disconnected(identity.provider)
        }

        XCTAssertEqual(monitor.tileName(for: AIUsageIdentity(.claude)), "Example Co")
        XCTAssertEqual(monitor.tileName(for: AIUsageIdentity(.claude, accountKey: "fasaj")), "Fasaj")
        XCTAssertEqual(monitor.displayName(for: AIUsageIdentity(.claude, accountKey: "fasaj")), "Claude · Fasaj")
        XCTAssertEqual(monitor.tileName(for: AIUsageIdentity(.codex)), "Codex")
        XCTAssertEqual(monitor.displayName(for: AIUsageIdentity(.codex)), "Codex")
    }

    private func name(of id: String, in accounts: [AIUsageAccount]) -> String? {
        accounts.first { $0.id == id }?.name
    }

    private func makeHome() throws -> URL {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("usage-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to path: String, in home: URL, permissions: Int = 0o600) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    }
}
