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

    func testEnvironmentPutsHomeLocalBinAheadOfGuiPath() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let localBin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        let path = AgentCLI.environment(homeDirectory: home)["PATH"] ?? ""
        XCTAssertTrue(path.hasPrefix(localBin.path + ":"), path)
        XCTAssertTrue(path.contains("/usr/bin"), path)
    }

    func testFetcherFindsNodeOnGuiPathViaHomeLocalBin() async throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("codex-node-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = """
        #!/bin/sh
        read _init
        echo '{"id":1,"result":{}}'
        read _initialized
        read _usage
        cat <<'USAGE'
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":81,"windowDurationMins":10080,"resetsAt":1789812650},"planType":"pro"}}}
        USAGE
        """
        try Data(node.utf8).write(to: bin.appendingPathComponent("node"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("node").path)
        let executable = bin.appendingPathComponent("codex")
        try Data("#!/usr/bin/env node\nprocess.exit(2)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let snapshot = await AIUsageFetcher.fetch(
            .codex,
            transport: NoHTTP(),
            now: Date(timeIntervalSince1970: 11),
            homeDirectory: home
        )
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 19)
    }

    func testSiblingFetchSetsCODEXHOMEAndReadsTheEmailFromTheCLI() async throws {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("codex-homes-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ -z "${CODEX_HOME+x}" ]; then used=81; email=personal@example.com
        else case "$CODEX_HOME" in *.codex-work) used=42; email=work@example.com ;; *) exit 9 ;; esac
        fi
        read _init
        echo '{"id":1,"result":{}}'
        read _initialized
        read _usage
        read _account
        cat <<USAGE
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":$used,"windowDurationMins":10080,"resetsAt":1789812650},"planType":"pro"}}}
        {"id":3,"result":{"account":{"type":"chatgpt","email":"$email","planType":"pro"}}}
        USAGE
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let personal = await AIUsageFetcher.fetch(
            AIUsageIdentity(.codex),
            transport: NoHTTP(),
            now: Date(timeIntervalSince1970: 11),
            homeDirectory: home
        )
        let work = await AIUsageFetcher.fetch(
            AIUsageIdentity(.codex, accountKey: "work"),
            transport: NoHTTP(),
            now: Date(timeIntervalSince1970: 11),
            homeDirectory: home
        )
        XCTAssertEqual(personal.windows.first?.usedPercent, 81)
        XCTAssertEqual(personal.accountEmail, "personal@example.com")
        XCTAssertEqual(work.windows.first?.usedPercent, 42)
        XCTAssertEqual(work.accountEmail, "work@example.com")
    }

    @MainActor
    func testShownCodexTileAddsTheSiblingBesideIt() throws {
        let suiteName = "AIUsageCodexLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.setShown(.aiUsage(.codex), true)
        layout.ensureAIUsageIdentities([
            AIUsageIdentity(.codex),
            AIUsageIdentity(.codex, accountKey: "work")
        ])
        let index = try XCTUnwrap(layout.items.firstIndex { $0.kind == .aiUsage(.codex) })
        XCTAssertEqual(layout.items[index + 1].kind, .aiUsage(AIUsageIdentity(.codex, accountKey: "work")))
        XCTAssertTrue(layout.items[index + 1].isShown)
        XCTAssertEqual(WidgetKind(id: "ai.codex.work"), .aiUsage(AIUsageIdentity(.codex, accountKey: "work")))
    }

    @MainActor
    func testHiddenDefaultTileKeepsTheSiblingHidden() throws {
        let suiteName = "AIUsageCodexLayoutHidden.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.ensureAIUsageIdentities([AIUsageIdentity(.codex, accountKey: "work")])
        let work = layout.items.first { $0.kind == .aiUsage(AIUsageIdentity(.codex, accountKey: "work")) }
        XCTAssertEqual(work?.isShown, false)
    }

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Codex must only use its CLI")
            throw URLError(.unsupportedURL)
        }
    }
}
