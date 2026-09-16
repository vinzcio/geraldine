import Foundation

/// Grok owns authentication. Account allowance comes from the TUI `/usage`
/// modal, which the CLI documents as the only billing surface. Headless
/// `--single /usage` is a model turn and is rejected.
struct GrokCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Grok CLI"

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(homeDirectory: homeDirectory, now: now) }
    }

    private func read(homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        guard let executable = AgentCLI.executable(
            named: "grok",
            homeDirectory: homeDirectory,
            extraHomePaths: [".grok/bin/grok"]
        ) else {
            return .failed(.grok, message: "Grok CLI was not found.")
        }
        let text = AgentPTY.capture(
            executable: executable,
            arguments: ["--no-alt-screen", "--cwd", homeDirectory.path],
            homeDirectory: homeDirectory,
            environment: [
                "TERM": "xterm-256color",
                "COLORFGBG": "15;0",
                "GROK_APPEARANCE": "dark",
                "GROK_AGENT_DASHBOARD": "0"
            ],
            replyColorQuery: true,
            steps: [
                .init(afterContaining: "Grok Build", afterSeconds: 0.2, write: Data("/usage".utf8)),
                .init(afterContaining: nil, afterSeconds: 0.6, write: Data("\r".utf8))
            ],
            stopContaining: ["Weekly limit left", "Weekly limit"],
            timeout: 18
        )
        switch Self.parse(Data(text.utf8), now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error):
            return .failed(.grok, message: error.message)
        }
    }

    static func parse(_ data: Data, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        if let snapshot = parseTerminal(String(data: data, encoding: .utf8) ?? "", now: now) {
            return .success(snapshot)
        }
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
        }
        if AIUsageJSON.string(json["type"]) == "error" {
            return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
        }
        if let billing = try? JSONSerialization.data(withJSONObject: json) {
            switch AIUsageParser.grok(from: billing, now: now) {
            case .success(var snapshot):
                snapshot.sourceLabel = sourceLabel
                return .success(snapshot)
            case .failure:
                break
            }
        }
        return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
    }

    static func parseTerminal(_ text: String, now: Date) -> AIUsageSnapshot? {
        let stripped = AgentPTY.stripANSI(text)
        guard !stripped.localizedCaseInsensitiveContains("API error"),
              !stripped.localizedCaseInsensitiveContains("Payment Required") else {
            return nil
        }
        let remainingPattern = #"Weekly limit left:\s*([0-9]+(?:\.[0-9]+)?)%"#
        let usedPattern = #"Weekly limit\s*\([^)]*\)[^\d]{0,80}([0-9]+(?:\.[0-9]+)?)%"#
        var used: Double?
        if let remaining = firstDouble(remainingPattern, in: stripped) {
            used = AIUsageMath.clampPercent(100 - remaining)
        } else {
            used = firstDouble(usedPattern, in: stripped)
        }
        guard let used, used.isFinite, (0...100).contains(used) else { return nil }
        var plan: String?
        if let regex = try? NSRegularExpression(pattern: #"Weekly limit\s*\(([^)]+)\)"#),
           let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let range = Range(match.range(at: 1), in: stripped) {
            plan = String(stripped[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AIUsageSnapshot(
            provider: .grok,
            status: .ready,
            plan: plan,
            windows: [
                AIUsageWindow(id: "pool", title: "Weekly", usedPercent: AIUsageMath.percent(from: used))
            ],
            fetchedAt: now,
            sourceLabel: sourceLabel
        )
    }

    private static func firstDouble(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text),
              let value = Double(text[range]) else { return nil }
        return value
    }
}
