import Foundation

/// Cursor owns authentication. Account meters come from the Agent CLI `/usage`
/// pager. Headless `--print /usage` is not that command and is rejected when it
/// is a model turn or an unauthenticated stub.
struct CursorCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Cursor CLI"

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(homeDirectory: homeDirectory, now: now) }
    }

    private func read(homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        guard let executable = AgentCLI.executable(named: "cursor-agent", homeDirectory: homeDirectory) else {
            return .failed(.cursor, message: "Cursor Agent CLI was not found.")
        }
        ensureAuthenticated(executable: executable, homeDirectory: homeDirectory)
        let text = AgentPTY.capture(
            executable: executable,
            arguments: ["--trust", "--workspace", homeDirectory.path],
            homeDirectory: homeDirectory,
            environment: [
                "TERM": "xterm-256color",
                "COLORFGBG": "15;0"
            ],
            replyColorQuery: true,
            steps: [
                .init(afterContaining: "Plan, search", afterSeconds: 0.3, write: Data("/usage".utf8)),
                .init(afterContaining: "Show plan and on-demand usage", afterSeconds: 0.2, write: Data("\r".utf8))
            ],
            stopContaining: ["Included", "% used"],
            timeout: 22
        )
        switch Self.parse(Data(text.utf8), now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.cursor, message: error.message)
        }
    }

    /// Reuse the desktop Cursor login. `agent login` would open a browser;
    /// ACP `cursor_login` binds the CLI to that existing session.
    private func ensureAuthenticated(executable: URL, homeDirectory: URL) {
        let status = AgentCLI.run(
            executable: executable,
            arguments: ["status", "--format", "json"],
            homeDirectory: homeDirectory
        )
        if let json = AIUsageJSON.object(from: status.data),
           json["isAuthenticated"] as? Bool == true {
            return
        }
        authenticateWithExistingLogin(executable: executable, homeDirectory: homeDirectory)
    }

    private func authenticateWithExistingLogin(executable: URL, homeDirectory: URL) {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = ["acp"]
        process.currentDirectoryURL = homeDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"geraldine","version":"0.1.0"},"clientCapabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"authenticate","params":{"methodId":"cursor_login"}}"#
        ]
        for line in requests {
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
        }
        let deadline = Date().addingTimeInterval(15)
        var collected = Data()
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if !chunk.isEmpty {
                collected.append(chunk)
                let text = String(data: collected, encoding: .utf8) ?? ""
                if text.contains(#""id":2"#) || text.contains(#""id": 2"#) { break }
            } else if !process.isRunning {
                collected.append(output.fileHandleForReading.readDataToEndOfFile())
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
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
        guard stripped.localizedCaseInsensitiveContains("show plan and on-demand usage")
                || stripped.localizedCaseInsensitiveContains("monthly plan and on-demand")
                || stripped.contains("Included") else { return nil }
        guard !stripped.localizedCaseInsensitiveContains("not logged in") else { return nil }
        let named: [(id: String, title: String, pattern: String)] = [
            ("totalPercentUsed", "Included", #"Included\s+([0-9]+(?:\.[0-9]+)?)%\s+used"#),
            ("autoPercentUsed", "Cursor models", #"Auto\s+([0-9]+(?:\.[0-9]+)?)%\s+used"#),
            ("apiPercentUsed", "Other models", #"API\s+([0-9]+(?:\.[0-9]+)?)%\s+used"#)
        ]
        var windows: [AIUsageWindow] = []
        for item in named {
            guard let used = firstDouble(item.pattern, in: stripped),
                  (0...100).contains(used) else { continue }
            windows.append(AIUsageWindow(id: item.id, title: item.title, usedPercent: used))
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
