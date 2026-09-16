import Foundation

/// Claude Code owns authentication. Usage comes only from
/// `claude --print /usage --output-format json`. A local cache is used only
/// when that command just refreshed it.
struct ClaudeCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Claude Code CLI"

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(homeDirectory: homeDirectory, now: now) }
    }

    private func read(homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        let previousFetchedAt = ClaudeUsageCache.snapshot(homeDirectory: homeDirectory)?.fetchedAt
        guard let executable = AgentCLI.executable(named: "claude", homeDirectory: homeDirectory) else {
            return .failed(.claude, message: "Claude Code CLI was not found.")
        }
        let result = AgentCLI.run(
            executable: executable,
            arguments: ["--print", "/usage", "--output-format", "json"],
            homeDirectory: homeDirectory
        )
        guard result.status == 0 else {
            return .failed(.claude, message: AICodingProvider.claude.usageUnavailableHint)
        }
        switch Self.parse(result.data, now: now, homeDirectory: homeDirectory,
                          previousFetchedAt: previousFetchedAt) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.claude, message: error.message)
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
