import Foundation
import Security
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

enum AIUsageCredentialStore {
    static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func token(for provider: AICodingProvider) -> AIUsageToken? {
        switch provider {
        case .claude:      return claudeToken()
        case .codex:       return jsonToken(at: home().appendingPathComponent(".codex/auth.json"),
                                            paths: [["tokens", "access_token"], ["access_token"]],
                                            accountPaths: [["tokens", "account_id"], ["account_id"]])
        case .grok:        return grokToken()
        case .cursor:      return cursorToken()
        case .antigravity: return antigravityToken()
        }
    }

    static func hasLocalSignIn(_ provider: AICodingProvider) -> Bool {
        token(for: provider) != nil || (provider == .antigravity && antigravityLanguageServer() != nil)
    }

    // MARK: Claude

    private static func claudeToken() -> AIUsageToken? {
        let file = home().appendingPathComponent(".claude/.credentials.json")
        if let token = jsonToken(at: file,
                                 paths: [["claudeAiOauth", "accessToken"], ["accessToken"]]) {
            return token
        }
        return keychainToken(service: "Claude Code-credentials",
                             nestedPaths: [["claudeAiOauth", "accessToken"], ["accessToken"]])
    }

    // MARK: Grok

    private static func grokToken() -> AIUsageToken? {
        let url = home().appendingPathComponent(".grok/auth.json")
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

    private static func cursorToken() -> AIUsageToken? {
        let authFiles = [
            home().appendingPathComponent(".cursor/auth.json"),
            home().appendingPathComponent(".config/cursor/auth.json")
        ]
        for file in authFiles {
            if let token = jsonToken(at: file, paths: [["accessToken"], ["access_token"], ["token"]]) {
                return token
            }
        }
        let db = home().appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        if let raw = sqliteValue(path: db, key: "cursorAuth/accessToken")
            ?? sqliteValue(path: db, key: "cursorAuth") {
            if let token = unwrapCursorAuth(raw) {
                return AIUsageToken(value: token)
            }
        }
        return keychainToken(service: "cursor-access-token")
            ?? keychainToken(service: "Cursor")
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

    // MARK: Antigravity

    private static func antigravityToken() -> AIUsageToken? {
        let paths: [[String]] = [
            ["token", "access_token"],
            ["token", "accessToken"],
            ["access_token"],
            ["accessToken"],
            ["token"]
        ]
        let files = [
            home().appendingPathComponent(".gemini/oauth_creds.json"),
            home().appendingPathComponent(".gemini/antigravity-cli/oauth_creds.json"),
            home().appendingPathComponent(".agy/oauth_creds.json")
        ]
        for file in files {
            if let token = jsonToken(at: file, paths: paths) {
                return token
            }
        }
        return keychainToken(service: "gemini", account: "antigravity", nestedPaths: paths)
            ?? keychainToken(service: "antigravity", nestedPaths: paths)
            ?? keychainToken(service: "agy", nestedPaths: paths)
    }

    struct LanguageServer: Equatable, Sendable {
        var port: Int
        var csrf: String?
    }

    static func antigravityLanguageServer() -> LanguageServer? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n") {
            let command = String(line)
            let lowered = command.lowercased()
            guard lowered.contains("language_server"), lowered.contains("antigravity") else { continue }
            let csrf = flagValue(in: command, name: "--csrf_token")
            if let portText = flagValue(in: command, name: "--extension_server_port"),
               let port = Int(portText) {
                return LanguageServer(port: port, csrf: csrf)
            }
        }
        return nil
    }

    private static func flagValue(in command: String, name: String) -> String? {
        let parts = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let index = parts.firstIndex(of: name), index + 1 < parts.count else { return nil }
        return parts[index + 1]
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

    private static func keychainToken(service: String, account: String? = nil,
                                      nestedPaths: [[String]] = []) -> AIUsageToken? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let payload = unwrapSecretPayload(data)
        if let json = AIUsageJSON.object(from: payload) {
            if let token = jsonToken(in: json, paths: nestedPaths.isEmpty
                                     ? [["accessToken"], ["access_token"], ["token", "access_token"]]
                                     : nestedPaths) {
                return token
            }
        }
        if let string = String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty, !string.hasPrefix("{") {
            return AIUsageToken(value: string)
        }
        return nil
    }

    /// `go-keyring-base64:` wrappers and raw JSON both show up in macOS keychain items.
    static func unwrapSecretPayload(_ data: Data) -> Data {
        guard let string = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return data }
        let prefix = "go-keyring-base64:"
        guard string.hasPrefix(prefix) else { return Data(string.utf8) }
        let encoded = String(string.dropFirst(prefix.count))
        return Data(base64Encoded: encoded) ?? Data(string.utf8)
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

enum AIUsageFetcher {
    static func fetch(_ provider: AICodingProvider,
                      transport: any AIUsageTransporting,
                      now: Date = Date()) async -> AIUsageSnapshot {
        switch provider {
        case .claude:      return await fetchClaude(transport: transport, now: now)
        case .codex:       return await fetchCodex(transport: transport, now: now)
        case .grok:        return await fetchGrok(transport: transport, now: now)
        case .cursor:      return await fetchCursor(transport: transport, now: now)
        case .antigravity: return await fetchAntigravity(transport: transport, now: now)
        }
    }

    private static func fetchClaude(transport: any AIUsageTransporting, now: Date) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .claude) else {
            return .needsSignIn(.claude)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("Geraldine", forHTTPHeaderField: "User-Agent")
        return await get(request, transport: transport, parse: { AIUsageParser.claude(from: $0, now: now) },
                         provider: .claude)
    }

    private static func fetchCodex(transport: any AIUsageTransporting, now: Date) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .codex) else {
            return .needsSignIn(.codex)
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

    private static func fetchGrok(transport: any AIUsageTransporting, now: Date) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .grok) else {
            return .needsSignIn(.grok)
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

    private static func fetchCursor(transport: any AIUsageTransporting, now: Date) async -> AIUsageSnapshot {
        guard let token = AIUsageCredentialStore.token(for: .cursor) else {
            return .needsSignIn(.cursor)
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

    private static func fetchAntigravity(transport: any AIUsageTransporting, now: Date) async -> AIUsageSnapshot {
        if let snapshot = await fetchAntigravityLocal(transport: transport, now: now),
           snapshot.status == .ready {
            return snapshot
        }
        guard let token = AIUsageCredentialStore.token(for: .antigravity) else {
            if AIUsageCredentialStore.antigravityLanguageServer() == nil {
                return .needsSignIn(.antigravity)
            }
            return .failed(.antigravity, message: "Antigravity is running but quota could not be read.")
        }
        var load = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        load.httpMethod = "POST"
        load.timeoutInterval = 12
        load.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        load.setValue("application/json", forHTTPHeaderField: "Content-Type")
        load.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        load.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ])
        let loaded = try? await transport.data(for: load)
        var project: String?
        if let loaded, loaded.1.statusCode < 400,
           let json = AIUsageJSON.object(from: loaded.0) {
            project = AIUsageJSON.string(json["cloudaicompanionProject"])
            if case .success(let parsed) = AIUsageParser.antigravity(from: loaded.0, now: now),
               parsed.status == .ready, parsed.headline != nil {
                return parsed
            }
        }
        var models = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!)
        models.httpMethod = "POST"
        models.timeoutInterval = 12
        models.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
        models.setValue("application/json", forHTTPHeaderField: "Content-Type")
        models.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [:]
        if let project { body["project"] = project }
        models.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await get(models, transport: transport,
                         parse: { AIUsageParser.antigravity(from: $0, now: now) },
                         provider: .antigravity)
    }

    private static func fetchAntigravityLocal(transport: any AIUsageTransporting,
                                              now: Date) async -> AIUsageSnapshot? {
        guard let server = AIUsageCredentialStore.antigravityLanguageServer() else { return nil }
        let url = URL(string: "http://127.0.0.1:\(server.port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let csrf = server.csrf {
            request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideName": "antigravity",
                "extensionName": "antigravity",
                "locale": "en"
            ]
        ])
        return await get(request, transport: transport,
                         parse: { AIUsageParser.antigravity(from: $0, now: now) },
                         provider: .antigravity)
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
                return .needsSignIn(provider)
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
            if http.status == 401 || http.status == 403 { return .needsSignIn(provider) }
            return .failed(provider, message: "\(provider.title) returned HTTP \(http.status).")
        }
        return .failed(provider, message: "Could not reach \(provider.title).")
    }
}

private struct AIUsageHTTPError: Error {
    var status: Int
}

