import Foundation

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
                      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
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
                      homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
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
        case .opencode, .pi, .muse:
            return .failed(identity.provider, message: identity.provider.usageUnavailableHint)
        }
    }

    static func fetchClaude(transport: any AIUsageTransporting, now: Date,
                            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                            claudeCLI: any ProviderUsageReading = ClaudeCLIUsage()) async -> AIUsageSnapshot {
        _ = transport
        return await claudeCLI.snapshot(homeDirectory: homeDirectory, now: now)
    }
}

