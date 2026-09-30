import XCTest
@testable import Geraldine

final class AIUsageClaudeCLITests: XCTestCase {
    private static let liveResult = """
    You are currently using your subscription to power your Claude Code usage

    Current session: 9% used · resets Sep 16 at 9pm (Asia/Manila)
    Current week (all models): 12% used · resets Sep 22 at 3pm (Asia/Manila)
    Current week (Fable): 8% used · resets Sep 22 at 3pm (Asia/Manila)
    """

    private static var payload: String {
        """
        {"is_error":false,"num_turns":0,"local_command":"usage","type":"result","subtype":"success","result":\(Self.jsonString(liveResult))}
        """
    }

    func testParsesSessionWeeklyAndFablePercentsFromCLIResult() throws {
        let now = Date(timeIntervalSince1970: 50)
        let snapshot = try ClaudeCLIUsage.parse(Data(Self.payload.utf8), now: now).get()
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.sourceLabel, ClaudeCLIUsage.sourceLabel)
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day", "seven_day_fable", "five_hour"])
        XCTAssertEqual(snapshot.displayWindows.map(\.remainingPercent), [88, 92, 91])
    }

    func testRejectsModelTurnsAndNonUsageCommands() {
        for payload in [
            Self.payload.replacingOccurrences(of: #""num_turns":0"#, with: #""num_turns":1"#),
            Self.payload.replacingOccurrences(of: #""local_command":"usage""#, with: #""local_command":"help""#),
            Self.payload.replacingOccurrences(of: #""is_error":false"#, with: #""is_error":true"#),
            #"{"is_error":false,"num_turns":0,"local_command":"usage","result":"hello"}"#,
            "invalid JSON"
        ] {
            guard case .failure = ClaudeCLIUsage.parse(Data(payload.utf8), now: Date()) else {
                XCTFail("Must not manufacture quotas from invalid Claude CLI output"); continue
            }
        }
    }

    func testAlwaysRunsCLIEvenWhenALocalCacheExists() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCache(to: home, timestamp: Date().timeIntervalSince1970 * 1000, fiveHour: 21, weekly: 6, fable: 6)
        try writeCLI(to: home, payload: Self.payload)
        let snapshot = await AIUsageFetcher.fetchClaude(
            transport: NoNetwork(),
            now: Date(timeIntervalSince1970: 9),
            homeDirectory: home
        )
        XCTAssertEqual(snapshot.sourceLabel, ClaudeCLIUsage.sourceLabel)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 9)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "seven_day" })?.usedPercent, 12)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Fable" })?.usedPercent, 8)
    }

    func testPrefersCacheClaudeCodeJustRefreshedOverResultText() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCache(to: home, timestamp: 1_000_000, fiveHour: 21, weekly: 6, fable: 6)
        try writeCLI(to: home, payload: Self.payload, refreshCache: (
            milliseconds: 2_000_000, fiveHour: 9, weekly: 12, fable: 8
        ))
        let snapshot = await AIUsageFetcher.fetchClaude(
            transport: NoNetwork(),
            now: Date(timeIntervalSince1970: 9),
            homeDirectory: home
        )
        XCTAssertEqual(snapshot.sourceLabel, ClaudeCLIUsage.sourceLabel)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 9)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "seven_day" })?.usedPercent, 12)
        XCTAssertEqual(snapshot.windows.first(where: { $0.title == "Fable" })?.usedPercent, 8)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "five_hour" })?.resetsAt,
                       Date(timeIntervalSince1970: 1_800))
    }

    func testCacheAloneIsNotAUsageSource() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCache(to: home, timestamp: Date().timeIntervalSince1970 * 1000, fiveHour: 21, weekly: 6, fable: 6)
        let snapshot = await AIUsageFetcher.fetchClaude(
            transport: NoNetwork(),
            now: Date(),
            homeDirectory: home
        )
        guard case .error(let message) = snapshot.status else {
            return XCTFail("Cache without CLI must be unavailable")
        }
        XCTAssertTrue(message.contains("CLI") || message.contains("/usage"))
    }

    func testFetcherUsesExactCLIArgumentsAndNeverHTTP() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCLI(to: home, payload: Self.payload)
        let snapshot = await AIUsageFetcher.fetch(
            .claude,
            transport: NoNetwork(),
            now: Date(timeIntervalSince1970: 9),
            homeDirectory: home
        )
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "five_hour" })?.remainingPercent, 91)
    }

    func testSiblingFetchSetsConfigDirAndKeepsTheDefaultSlotUnset() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"oauthAccount":{"emailAddress":"team@example.com","organizationRateLimitTier":"default_raven"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let client = home.appendingPathComponent(".claude-client")
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"max@example.com","organizationRateLimitTier":"default_claude_max_20x"}}"#.utf8)
            .write(to: client.appendingPathComponent(".claude.json"))
        let executable = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = home.appendingPathComponent("claude-env")
        let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        [ "$#" = 4 ] && [ "$1" = "--print" ] && [ "$2" = "/usage" ] && [ "$3" = "--output-format" ] && [ "$4" = "json" ] || exit 9
        if [ -n "${CLAUDE_CONFIG_DIR+x}" ]; then
          printf '%s' "$CLAUDE_CONFIG_DIR" > \(quotedMarker)
        else
          printf 'UNSET' > \(quotedMarker)
        fi
        cat <<'USAGE'
        \(Self.payload)
        USAGE
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let defaultLogin = await AIUsageFetcher.fetch(
            AIUsageIdentity(.claude),
            transport: NoNetwork(),
            now: Date(timeIntervalSince1970: 9),
            homeDirectory: home
        )
        let defaultEnv = try String(contentsOf: marker, encoding: .utf8)
        let clientSnapshot = await AIUsageFetcher.fetch(
            AIUsageIdentity(.claude, accountKey: "client"),
            transport: NoNetwork(),
            now: Date(timeIntervalSince1970: 9),
            homeDirectory: home
        )
        let clientEnv = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertEqual(defaultLogin.status, .ready)
        XCTAssertEqual(defaultEnv, "UNSET")
        XCTAssertNil(defaultLogin.plan)
        XCTAssertEqual(defaultLogin.accountEmail, "team@example.com")
        XCTAssertEqual(clientSnapshot.status, .ready)
        XCTAssertEqual(
            URL(fileURLWithPath: clientEnv).resolvingSymlinksInPath().path,
            client.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(clientSnapshot.plan, "Max 20x")
        XCTAssertEqual(clientSnapshot.accountEmail, "max@example.com")
        XCTAssertEqual(clientSnapshot.windows.first(where: { $0.id == "five_hour" })?.usedPercent, 9)
    }

    @MainActor
    func testShownClaudeTileAddsTheSiblingBesideIt() throws {
        let suiteName = "AIUsageClaudeLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let layout = WidgetLayoutStore(defaults: defaults)
        layout.setShown(.aiUsage(.claude), true)
        layout.setSize(.aiUsage(.claude), .medium)
        layout.ensureAIUsageIdentities([
            AIUsageIdentity(.claude),
            AIUsageIdentity(.claude, accountKey: "client")
        ])
        let index = try XCTUnwrap(layout.items.firstIndex { $0.kind == .aiUsage(.claude) })
        let client = layout.items[index + 1]
        XCTAssertEqual(client.kind, .aiUsage(AIUsageIdentity(.claude, accountKey: "client")))
        XCTAssertTrue(client.isShown)
        XCTAssertEqual(client.size, .medium)
        XCTAssertEqual(client.kind.id, "ai.claude.client")
        XCTAssertEqual(client.kind.title, "Claude · Client")
        XCTAssertEqual(WidgetLayoutStore(defaults: defaults).items.map(\.kind), layout.items.map(\.kind))
    }

    func testCLIFailureDoesNotFallBackToFileTokenOrStaleCache() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeCache(to: home, timestamp: 1_000_000, fiveHour: 15, weekly: 6, fable: 6)
        try writeToken(to: home)
        try writeCLI(to: home, payload: #"{"is_error":true,"num_turns":0,"local_command":"usage","result":"nope"}"#)
        let snapshot = await AIUsageFetcher.fetchClaude(
            transport: NoNetwork(),
            now: Date(),
            homeDirectory: home
        )
        guard case .error = snapshot.status else {
            return XCTFail("Failed CLI must not revive cache or HTTP")
        }
        XCTAssertTrue(snapshot.windows.isEmpty)
    }

    private func makeHome() throws -> URL {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("claude-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeCache(to home: URL, timestamp: Double, fiveHour: Double, weekly: Double, fable: Double) throws {
        let object: [String: Any] = [
            "oauthAccount": ["accountUuid": "current"],
            "cachedUsageUtilization": [
                "accountUuid": "current", "fetchedAtMs": timestamp,
                "utilization": [
                    "five_hour": ["utilization": fiveHour, "resets_at": 1_800],
                    "seven_day": ["utilization": weekly],
                    "limits": [[
                        "percent": fable,
                        "scope": ["model": ["display_name": "Fable"]]
                    ]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: home.appendingPathComponent(".claude.json"))
    }

    private func writeToken(to home: URL) throws {
        let credentials = home.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accessToken":"fixture"}"#.utf8).write(to: credentials)
    }

    private func writeCLI(to home: URL, payload: String,
                          refreshCache: (milliseconds: Double, fiveHour: Double, weekly: Double, fable: Double)? = nil) throws {
        let executable = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        var refresh = ""
        if let refreshCache {
            let cache = home.appendingPathComponent(".claude.json").path
            refresh = """
            python3 - <<'PY'
            import json
            path = \(Self.jsonString(cache))
            with open(path) as handle:
                data = json.load(handle)
            data["cachedUsageUtilization"]["fetchedAtMs"] = \(refreshCache.milliseconds)
            data["cachedUsageUtilization"]["utilization"]["five_hour"]["utilization"] = \(refreshCache.fiveHour)
            data["cachedUsageUtilization"]["utilization"]["seven_day"]["utilization"] = \(refreshCache.weekly)
            data["cachedUsageUtilization"]["utilization"]["limits"][0]["percent"] = \(refreshCache.fable)
            with open(path, "w") as handle:
                json.dump(data, handle)
            PY
            """
        }
        let script = """
        #!/bin/sh
        [ "$#" = 4 ] && [ "$1" = "--print" ] && [ "$2" = "/usage" ] && [ "$3" = "--output-format" ] && [ "$4" = "json" ] || exit 9
        \(refresh)
        cat <<'USAGE'
        \(payload)
        USAGE
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    private static func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private struct NoNetwork: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Claude usage must not access the network")
            throw URLError(.notConnectedToInternet)
        }
    }
}
