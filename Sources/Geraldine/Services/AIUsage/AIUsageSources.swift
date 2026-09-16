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
                      antigravityCLI: any AntigravityUsageReading = AntigravityCLIUsage()) async -> AIUsageSnapshot {
        switch provider {
        case .claude:      return await fetchClaude(transport: transport, now: now, homeDirectory: homeDirectory)
        case .codex:       return await fetchCodex(transport: transport, now: now, homeDirectory: homeDirectory)
        case .grok:        return await fetchGrok(transport: transport, now: now, homeDirectory: homeDirectory)
        case .cursor:      return await fetchCursor(transport: transport, now: now, homeDirectory: homeDirectory)
        case .antigravity: return await antigravityCLI.snapshot(homeDirectory: homeDirectory, now: now)
        }
    }

    static func fetchClaude(transport: any AIUsageTransporting, now: Date,
                            homeDirectory: URL = AIUsageCredentialStore.home()) async -> AIUsageSnapshot {
        let cached = ClaudeUsageCache.snapshot(homeDirectory: homeDirectory)
        if let cached, !ClaudeUsageCache.isStale(cached, now: now) {
            return cached
        }
        guard let token = AIUsageCredentialStore.token(for: .claude, homeDirectory: homeDirectory) else {
            if let cached { return cached }
            return .failed(.claude, message: "Usage unavailable. Run /usage in Claude Code, then refresh.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("Geraldine", forHTTPHeaderField: "User-Agent")
        let live = await get(request, transport: transport, parse: { AIUsageParser.claude(from: $0, now: now) },
                             provider: .claude)
        if live.status == .ready { return live }
        return cached ?? live
    }

    private static func fetchCodex(transport: any AIUsageTransporting, now: Date, homeDirectory: URL) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .codex, homeDirectory: homeDirectory) else {
            return .failed(.codex, message: AICodingProvider.codex.usageUnavailableHint)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let account = token.accountID {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return await get(request, transport: transport, parse: { AIUsageParser.codex(from: $0, now: now) },
                         provider: .codex)
    }

    private static func fetchGrok(transport: any AIUsageTransporting, now: Date, homeDirectory: URL) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .grok, homeDirectory: homeDirectory) else {
            return .failed(.grok, message: AICodingProvider.grok.usageUnavailableHint)
        }
        do {
            let billing = try await authorizedGet(
                URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
                token: token.value,
                transport: transport
            )
            let user = try? await authorizedGet(
                URL(string: "https://cli-chat-proxy.grok.com/v1/user?include=subscription")!,
                token: token.value,
                transport: transport
            )
            switch AIUsageParser.grok(from: billing, user: user, now: now) {
            case .success(let snapshot): return snapshot
            case .failure(let error): return .failed(.grok, message: error.message)
            }
        } catch {
            return mapHTTPError(error, provider: .grok)
        }
    }

    private static func fetchCursor(transport: any AIUsageTransporting, now: Date, homeDirectory: URL) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .cursor, homeDirectory: homeDirectory) else {
            return .failed(.cursor, message: AICodingProvider.cursor.usageUnavailableHint)
        }
        var period = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
        period.httpMethod = "POST"
        period.timeoutInterval = 12
        period.httpBody = Data("{}".utf8)
        period.setValue("application/json", forHTTPHeaderField: "Content-Type")
        period.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        period.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        period.setValue("Geraldine", forHTTPHeaderField: "User-Agent")
        let periodResult = await get(period, transport: transport,
                                     parse: { AIUsageParser.cursor(from: $0, now: now) },
                                     provider: .cursor)
        if periodResult.status == .ready { return periodResult }

        var summary = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        summary.httpMethod = "GET"
        summary.timeoutInterval = 12
        summary.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        summary.setValue("Geraldine", forHTTPHeaderField: "User-Agent")
        return await get(summary, transport: transport,
                         parse: { AIUsageParser.cursor(from: $0, now: now) },
                         provider: .cursor)
    }

    private static func authorizedGet(_ url: URL, token: String,
                                      transport: any AIUsageTransporting) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Geraldine", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard (200..<400).contains(response.statusCode) else {
            throw AIUsageHTTPError(status: response.statusCode)
        }
        return data
    }

    private static func get(_ request: URLRequest,
                            transport: any AIUsageTransporting,
                            parse: (Data) -> Result<AIUsageSnapshot, AIUsageParseError>,
                            provider: AICodingProvider) async -> AIUsageSnapshot {
        do {
            let (data, response) = try await transport.data(for: request)
            if response.statusCode == 401 || response.statusCode == 403 {
                return .failed(provider, message: "\(provider.title) usage access was rejected. Refresh usage in the official app or CLI, then retry.")
            }
            guard (200..<400).contains(response.statusCode) else {
                return .failed(provider, message: "\(provider.title) returned HTTP \(response.statusCode).")
            }
            switch parse(data) {
            case .success(let snapshot): return snapshot
            case .failure(let error): return .failed(provider, message: error.message)
            }
        } catch {
            return mapHTTPError(error, provider: provider)
        }
    }

    private static func mapHTTPError(_ error: Error, provider: AICodingProvider) -> AIUsageSnapshot {
        if let http = error as? AIUsageHTTPError {
            if http.status == 401 || http.status == 403 { return .failed(provider, message: "\(provider.title) usage access was rejected. Refresh usage in the official app or CLI, then retry.") }
            return .failed(provider, message: "\(provider.title) returned HTTP \(http.status).")
        }
        return .failed(provider, message: "Could not reach \(provider.title).")
    }
}

private struct AIUsageHTTPError: Error {
    var status: Int
}

