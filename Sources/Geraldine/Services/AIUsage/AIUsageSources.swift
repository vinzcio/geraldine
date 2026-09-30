import Foundation
import SQLite3

protocol AIUsageTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAIUsageTransport: AIUsageTransporting {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

struct AIUsageToken: Equatable, Sendable {
    var value: String
    var accountID: String?
}

// Credential discovery must never access Keychain, including silent fallbacks.
// Query-level UI suppression did not prevent the installed macOS prompts.
// Missing file/database credentials are unavailable; never retry via Security APIs.
enum AIUsageCredentialStore {
    static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func token(for provider: AICodingProvider, homeDirectory: URL = home()) -> AIUsageToken? {
        switch provider {
        case .claude:      return claudeToken(homeDirectory: homeDirectory)
        case .codex:       return jsonToken(at: homeDirectory.appendingPathComponent(".codex/auth.json"),
                                            paths: [["tokens", "access_token"], ["access_token"]],
                                            accountPaths: [["tokens", "account_id"], ["account_id"]])
        case .grok:        return grokToken(homeDirectory: homeDirectory)
        case .cursor:      return cursorToken(homeDirectory: homeDirectory)
        case .antigravity: return nil // Authentication belongs exclusively to the agy CLI.
        }
    }

    // MARK: Claude

    private static func claudeToken(homeDirectory: URL) -> AIUsageToken? {
        let file = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        if let token = jsonToken(at: file,
                                 paths: [["claudeAiOauth", "accessToken"], ["accessToken"]]) {
            return token
        }
        return nil
    }

    // MARK: Grok

    private static func grokToken(homeDirectory: URL) -> AIUsageToken? {
        let url = homeDirectory.appendingPathComponent(".grok/auth.json")
        guard let json = readJSON(url) else { return nil }
        if let direct = jsonToken(in: json, paths: [["key"], ["access_token"], ["token"]]) {
            return direct
        }
        for value in json.values {
            guard let entry = value as? [String: Any] else { continue }
            if let token = AIUsageJSON.string(entry["key"])
                ?? AIUsageJSON.string(entry["access_token"])
                ?? AIUsageJSON.string(entry["token"]) {
                return AIUsageToken(value: token)
            }
        }
        return nil
    }

    // MARK: Cursor

    private static func cursorToken(homeDirectory: URL) -> AIUsageToken? {
        let authFiles = [
            homeDirectory.appendingPathComponent(".cursor/auth.json"),
            homeDirectory.appendingPathComponent(".config/cursor/auth.json")
        ]
        for file in authFiles {
            if let token = jsonToken(at: file, paths: [["accessToken"], ["access_token"], ["token"]]) {
                return token
            }
        }
        let db = homeDirectory.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        if let raw = sqliteValue(path: db, key: "cursorAuth/accessToken")
            ?? sqliteValue(path: db, key: "cursorAuth") {
            if let token = unwrapCursorAuth(raw) {
                return AIUsageToken(value: token)
            }
        }
        return nil
    }

    private static func unwrapCursorAuth(_ raw: String) -> String? {
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = AIUsageJSON.object(from: data) {
            return AIUsageJSON.string(json["accessToken"])
                ?? AIUsageJSON.string(json["access_token"])
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Shared readers

    private static func jsonToken(at url: URL, paths: [[String]], accountPaths: [[String]] = []) -> AIUsageToken? {
        guard let json = readJSON(url) else { return nil }
        return jsonToken(in: json, paths: paths, accountPaths: accountPaths)
    }

    private static func jsonToken(in json: [String: Any], paths: [[String]],
                                  accountPaths: [[String]] = []) -> AIUsageToken? {
        guard let value = firstString(in: json, paths: paths) else { return nil }
        return AIUsageToken(value: value, accountID: firstString(in: json, paths: accountPaths))
    }

    private static func firstString(in json: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var current: Any? = json
            for key in path {
                current = AIUsageJSON.dictionary(current)?[key]
            }
            if let value = AIUsageJSON.string(current) { return value }
        }
        return nil
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return AIUsageJSON.object(from: data)
    }

    private static func sqliteValue(path: URL, key: String) -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let cString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: cString)
    }
}

// Claude owns authentication and refreshes this snapshot itself. Reading it must
// preserve its account identity and original timestamp, never imply a fresh fetch.
enum ClaudeUsageCache {
    static let sourceLabel = "Claude Code (cached)"

    static func snapshot(homeDirectory: URL) -> AIUsageSnapshot? {
        let file = homeDirectory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = AIUsageJSON.object(from: data),
              let account = AIUsageJSON.dictionary(json["oauthAccount"]),
              let accountID = AIUsageJSON.string(account["accountUuid"]),
              !accountID.isEmpty,
              let cache = AIUsageJSON.dictionary(json["cachedUsageUtilization"]),
              AIUsageJSON.string(cache["accountUuid"]) == accountID,
              let milliseconds = AIUsageJSON.number(cache["fetchedAtMs"]),
              milliseconds.isFinite, milliseconds > 0,
              let utilization = AIUsageJSON.dictionary(cache["utilization"]),
              let usageData = try? JSONSerialization.data(withJSONObject: utilization),
              case .success(var snapshot) = AIUsageParser.claude(
                from: usageData, now: Date(timeIntervalSince1970: milliseconds / 1000)
              ) else { return nil }
        snapshot.sourceLabel = sourceLabel
        return snapshot
    }

    static func isStale(_ snapshot: AIUsageSnapshot, now: Date) -> Bool {
        guard let fetchedAt = snapshot.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= AIUsageMonitor.refreshInterval
    }
}

enum AIUsageFetcher {
    static func fetch(_ provider: AICodingProvider,
                      transport: any AIUsageTransporting,
                      now: Date = Date(),
                      homeDirectory: URL = AIUsageCredentialStore.home(),
                      antigravityCLI: any AntigravityUsageReading = AntigravityCLIUsage(),
                      claudeCLI: any ProviderUsageReading = ClaudeCLIUsage(),
                      codexCLI: any ProviderUsageReading = CodexCLIUsage(),
                      grokCLI: any ProviderUsageReading = GrokCLIUsage(),
                      cursorCLI: any ProviderUsageReading = CursorCLIUsage()) async -> AIUsageSnapshot {
        await fetch(
            AIUsageIdentity(provider),
            transport: transport,
            now: now,
            homeDirectory: homeDirectory,
            antigravityCLI: antigravityCLI,
            claudeCLI: claudeCLI,
            codexCLI: codexCLI,
            grokCLI: grokCLI,
            cursorCLI: cursorCLI
        )
    }

    static func fetch(_ identity: AIUsageIdentity,
                      transport: any AIUsageTransporting,
                      now: Date = Date(),
                      homeDirectory: URL = AIUsageCredentialStore.home(),
                      antigravityCLI: any AntigravityUsageReading = AntigravityCLIUsage(),
                      claudeCLI: any ProviderUsageReading = ClaudeCLIUsage(),
                      codexCLI: any ProviderUsageReading = CodexCLIUsage(),
                      grokCLI: any ProviderUsageReading = GrokCLIUsage(),
                      cursorCLI: any ProviderUsageReading = CursorCLIUsage()) async -> AIUsageSnapshot {
        // Usage is CLI-only. Transport remains in the signature so tests can
        // assert Geraldine never opens an HTTP usage request.
        _ = transport
        switch identity.provider {
        case .claude:      return await claudeCLI.snapshot(for: identity, homeDirectory: homeDirectory, now: now)
        case .codex:       return await codexCLI.snapshot(for: identity, homeDirectory: homeDirectory, now: now)
        case .grok:        return await grokCLI.snapshot(homeDirectory: homeDirectory, now: now)
        case .cursor:      return await cursorCLI.snapshot(homeDirectory: homeDirectory, now: now)
        case .antigravity: return await antigravityCLI.snapshot(homeDirectory: homeDirectory, now: now)
        }
    }

    static func fetchClaude(transport: any AIUsageTransporting, now: Date,
                            homeDirectory: URL = AIUsageCredentialStore.home(),
                            claudeCLI: any ProviderUsageReading = ClaudeCLIUsage()) async -> AIUsageSnapshot {
        _ = transport
        return await claudeCLI.snapshot(homeDirectory: homeDirectory, now: now)
    }
}

