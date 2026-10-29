import Foundation

/// Cursor owns authentication. Account meters come from the Agent CLI `/usage`
/// pager, using the local app/CLI session already on this Mac. Geraldine never
/// starts a browser or ACP login. Headless `--print /usage` is not that command
/// and is rejected when it is a model turn or an unauthenticated stub.
struct CursorCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Cursor CLI"
    var timeout: TimeInterval = 45

    /// `--disable-auto-update`: otherwise every check starts the CLI's background
    /// self-update (a full download) and the capture kills it half-extracted.
    /// The workspace is Geraldine's own empty folder, so `--trust` and any MCP
    /// decision apply there and never to the home folder.
    static func arguments(workspace: URL) -> [String] {
        ["--disable-auto-update", "--trust", "--workspace", workspace.path]
    }

    /// New servers in `~/.cursor/mcp.json` open an approval screen first. Its
    /// default choice approves them all, so it is only ever answered with `c`,
    /// and only while that option is on screen.
    static let promptReplies = [
        AgentPTY.PromptReply(containing: "Continue without approval", write: Data("c".utf8))
    ]

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(homeDirectory: homeDirectory, now: now) }
    }

    private func read(homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        guard let executable = AgentCLI.executable(named: "cursor-agent", homeDirectory: homeDirectory) else {
            return .failed(.cursor, message: "Cursor Agent CLI was not found.")
        }
        let workspace = AgentCLI.usageWorkspace(homeDirectory: homeDirectory)
        let environment = [
            "TERM": "xterm-256color",
            "COLORFGBG": "15;0"
        ]
        let text = AgentPTY.capture(
            executable: executable,
            arguments: Self.arguments(workspace: workspace),
            homeDirectory: homeDirectory,
            workingDirectory: workspace,
            environment: environment,
            replyColorQuery: true,
            steps: [
                .init(afterContaining: "Plan, search", afterSeconds: 0.3, write: Data("/usage".utf8)),
                .init(afterContaining: "Show plan and on-demand usage", afterSeconds: 0.2, write: Data("\r".utf8))
            ],
            promptReplies: Self.promptReplies,
            stopContaining: [
                "Included",
                "% used",
                "Not logged in",
                "Monthly plan and on-demand"
            ],
            abortContaining: [
                "Press any key to log in",
                "Signing in with the browser",
                "If your browser didn't open"
            ],
            timeout: timeout
        )
        switch Self.parse(Data(text.utf8), now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.cursor, message: Self.failureMessage(screen: text) ?? error.message)
        }
    }

    /// Name the screen the CLI stopped on instead of the generic hint.
    static func failureMessage(screen: String) -> String? {
        let text = AgentPTY.stripANSI(screen)
        if ["Not logged in", "Press any key to log in", "Signing in with the browser", "If your browser didn't open"]
            .contains(where: { AgentPTY.containsLoose(text, $0) }) {
            return "Cursor Agent is signed out. Sign in to the Cursor Agent CLI, then refresh."
        }
        if let approval = text.range(of: "MCP Server Approval Required", options: .backwards),
           !AgentPTY.containsLoose(String(text[approval.upperBound...]), "Plan, search") {
            return "Cursor Agent stopped on its MCP approval screen."
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Cursor Agent CLI did not start."
        }
        if !AgentPTY.containsLoose(text, "Show plan and on-demand usage") {
            return "Cursor Agent did not open /usage in time."
        }
        return nil
    }

    static func parse(_ data: Data, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        if let snapshot = parseTerminal(String(data: data, encoding: .utf8) ?? "", now: now) {
            return .success(snapshot)
        }
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(.init(message: AICodingProvider.cursor.usageUnavailableHint))
        }
        if AIUsageJSON.string(json["type"]) == "error"
            || AIUsageJSON.string(json["status"]) == "unauthenticated"
            || json["isAuthenticated"] as? Bool == false {
            return .failure(.init(message: AICodingProvider.cursor.usageUnavailableHint))
        }
        if AIUsageJSON.number(json["num_turns"]).map({ $0 != 0 }) == true {
            return .failure(.init(message: "Cursor CLI used a model turn instead of structured usage."))
        }
        switch AIUsageParser.cursor(from: data, now: now) {
        case .success(var snapshot):
            snapshot.sourceLabel = sourceLabel
            return .success(snapshot)
        case .failure:
            return .failure(.init(message: AICodingProvider.cursor.usageUnavailableHint))
        }
    }

    static func parseTerminal(_ text: String, now: Date) -> AIUsageSnapshot? {
        let stripped = AgentPTY.stripANSI(text)
        guard !stripped.localizedCaseInsensitiveContains("not logged in"),
              !stripped.localizedCaseInsensitiveContains("press any key to log in"),
              !stripped.localizedCaseInsensitiveContains("signing in with the browser") else {
            return nil
        }
        guard stripped.localizedCaseInsensitiveContains("show plan and on-demand usage")
                || stripped.localizedCaseInsensitiveContains("monthly plan and on-demand")
                || stripped.contains("Included") else { return nil }
        let named: [(id: String, title: String, pattern: String)] = [
            ("totalPercentUsed", "Included", #"Included[:\s]+([0-9]+(?:\.[0-9]+)?)%\s+used"#),
            ("autoPercentUsed", "Cursor models", #"Auto[:\s]+([0-9]+(?:\.[0-9]+)?)%\s+used"#),
            ("apiPercentUsed", "Other models", #"API[:\s]+([0-9]+(?:\.[0-9]+)?)%\s+used"#)
        ]
        // One billing-cycle reset in the pager header covers every meter: "Resets Oct 6".
        let reset = AIUsageResetParser.parsePhrase(in: stripped, now: now)
        var windows: [AIUsageWindow] = []
        for item in named {
            guard let used = firstDouble(item.pattern, in: stripped),
                  (0...100).contains(used) else { continue }
            windows.append(AIUsageWindow(id: item.id, title: item.title, usedPercent: used,
                                         resetsAt: reset?.date, resetIsDateOnly: reset?.dateOnly ?? false))
        }
        guard !windows.isEmpty else { return nil }
        var plan: String?
        if let regex = try? NSRegularExpression(pattern: #"Usage\s*[•·]\s*(\S+)"#),
           let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let range = Range(match.range(at: 1), in: stripped) {
            plan = String(stripped[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AIUsageSnapshot(
            provider: .cursor,
            status: .ready,
            plan: plan,
            windows: windows,
            fetchedAt: now,
            sourceLabel: sourceLabel
        )
    }

    private static func firstDouble(_ pattern: String, in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}
