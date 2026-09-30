import Foundation

/// The signed-in account Claude Code records in `.claude.json` beside its
/// settings. Profile fields only: Claude keeps its tokens elsewhere.
struct ClaudeProfile: Equatable, Sendable {
    var email: String
    var plan: String?
    /// Set for Team and Enterprise logins.
    var teamOrganization: String?

    static func read(in directory: URL) -> ClaudeProfile? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".claude.json")),
              let json = AIUsageJSON.object(from: data),
              let account = AIUsageJSON.dictionary(json["oauthAccount"]),
              let email = AIUsageJSON.string(account["emailAddress"]) else { return nil }
        let type = AIUsageJSON.string(account["organizationType"]) ?? ""
        let isTeam = type.hasSuffix("_team") || type.hasSuffix("_enterprise")
        return ClaudeProfile(
            email: email,
            plan: planLabel(rateLimitTier: AIUsageJSON.string(account["organizationRateLimitTier"])),
            teamOrganization: isTeam ? AIUsageJSON.string(account["organizationName"]) : nil
        )
    }

    /// Max tiers Claude stores beside the signed-in email. Other tiers stay unlabeled.
    static func planLabel(rateLimitTier: String?) -> String? {
        switch rateLimitTier {
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_max_5x": return "Max 5x"
        default: return nil
        }
    }
}

/// Claude Code owns authentication. Usage comes only from
/// `claude --print /usage --output-format json`. A local cache is used only
/// when that command just refreshed it.
struct ClaudeCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Claude Code CLI"

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshot(for: AIUsageIdentity(.claude), homeDirectory: homeDirectory, now: now)
    }

    func snapshot(for identity: AIUsageIdentity, homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(identity: identity, homeDirectory: homeDirectory, now: now) }
    }

    private func read(identity: AIUsageIdentity, homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        // A sibling login runs with CLAUDE_CONFIG_DIR at its folder. The default
        // login keeps it unset: setting it, even to ~/.claude, hides that login.
        let configDirectory = identity.accountKey.isEmpty
            ? nil
            : homeDirectory.appendingPathComponent(".claude-\(identity.accountKey)")
        let profileDirectory = configDirectory ?? homeDirectory
        let previousFetchedAt = ClaudeUsageCache.snapshot(homeDirectory: profileDirectory)?.fetchedAt
        guard let executable = AgentCLI.executable(named: "claude", homeDirectory: homeDirectory) else {
            return .failed(.claude, message: "Claude Code CLI was not found.")
        }
        var environment = AgentCLI.environment(homeDirectory: homeDirectory)
        environment["CLAUDE_CONFIG_DIR"] = configDirectory?.path
        let result = AgentCLI.run(
            executable: executable,
            arguments: ["--print", "/usage", "--output-format", "json"],
            homeDirectory: homeDirectory,
            environment: environment
        )
        guard result.status == 0 else {
            return .failed(.claude, message: AICodingProvider.claude.usageUnavailableHint)
        }
        switch Self.parse(result.data, now: now, homeDirectory: profileDirectory,
                          previousFetchedAt: previousFetchedAt) {
        case .success(var snapshot):
            let profile = ClaudeProfile.read(in: profileDirectory)
            snapshot.accountEmail = profile?.email
            snapshot.plan = profile?.plan ?? snapshot.plan
            return snapshot
        case .failure(let error):
            return .failed(.claude, message: error.message)
        }
    }

    static func parse(_ data: Data, now: Date, homeDirectory: URL? = nil,
                      previousFetchedAt: Date? = nil) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data),
              AIUsageJSON.number(json["num_turns"]) == 0,
              !isErrorFlag(json["is_error"]),
              AIUsageJSON.string(json["local_command"]) == "usage",
              let result = AIUsageJSON.string(json["result"]) else {
            return .failure(.init(message: "Claude Code CLI did not return structured usage. Run /usage in Claude Code and retry."))
        }

        if let homeDirectory,
           let cached = ClaudeUsageCache.snapshot(homeDirectory: homeDirectory),
           let fetchedAt = cached.fetchedAt,
           fetchedAt > (previousFetchedAt ?? .distantPast) {
            var live = cached
            live.sourceLabel = sourceLabel
            live.fetchedAt = now
            return .success(live)
        }

        return parseResultText(result, now: now)
    }

    private static func isErrorFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = AIUsageJSON.string(value)?.lowercased() { return string == "true" || string == "1" }
        return false
    }

    static func parseResultText(_ text: String, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        let patterns: [(id: String, title: String, pattern: String)] = [
            ("five_hour", "5-hour", #"Current session:\s*([0-9]+(?:\.[0-9]+)?)%\s*used"#),
            ("seven_day", "All models", #"Current week \(all models\):\s*([0-9]+(?:\.[0-9]+)?)%\s*used"#),
            ("seven_day_fable", "Fable", #"Current week \(Fable\):\s*([0-9]+(?:\.[0-9]+)?)%\s*used"#)
        ]
        var windows: [AIUsageWindow] = []
        for item in patterns {
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text),
                  let used = Double(text[range]), used.isFinite, (0...100).contains(used) else { continue }
            windows.append(AIUsageWindow(id: item.id, title: item.title, usedPercent: used))
        }
        guard !windows.isEmpty else {
            return .failure(.init(message: "Claude Code CLI did not return any usage windows."))
        }
        return .success(AIUsageSnapshot(
            provider: .claude,
            status: .ready,
            plan: nil,
            windows: windows,
            fetchedAt: now,
            sourceLabel: sourceLabel
        ))
    }
}
