import Foundation

/// Codex owns authentication. Usage comes only from the Codex CLI app-server:
/// `account/rateLimits/read` for quotas and `account/read` for the signed-in
/// email. No file-token HTTP.
struct CodexCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Codex CLI"

    func snapshot(homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshot(for: AIUsageIdentity(.codex), homeDirectory: homeDirectory, now: now)
    }

    func snapshot(for identity: AIUsageIdentity, homeDirectory: URL, now: Date) async -> AIUsageSnapshot {
        await snapshotOffMain { read(identity: identity, homeDirectory: homeDirectory, now: now) }
    }

    private func read(identity: AIUsageIdentity, homeDirectory: URL, now: Date) -> AIUsageSnapshot {
        guard let executable = AgentCLI.executable(named: "codex", homeDirectory: homeDirectory) else {
            return .failed(.codex, message: "Codex CLI was not found.")
        }
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = homeDirectory
        // A sibling login is its own CODEX_HOME. The default login leaves it
        // unset so Codex resolves ~/.codex itself.
        var environment = AgentCLI.environment(homeDirectory: homeDirectory)
        environment["CODEX_HOME"] = identity.accountKey.isEmpty
            ? nil
            : homeDirectory.appendingPathComponent(".codex-\(identity.accountKey)").path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failed(.codex, message: "Could not run Codex CLI usage.")
        }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"geraldine","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"account/read","params":{}}"#
        ]
        for line in requests {
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
        }
        // Keep stdin open until both replies arrive. Closing it first makes
        // `codex app-server --stdio` exit after initialize.
        let data = Self.readResponse(from: output, untilProcess: process)
        input.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        switch Self.parse(data, now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.codex, message: error.message)
        }
    }

    private static func readResponse(from output: Pipe, untilProcess process: Process) -> Data {
        var collected = Data()
        let handle = output.fileHandleForReading
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = handle.availableData
            if !chunk.isEmpty {
                collected.append(chunk)
                let text = String(data: collected, encoding: .utf8) ?? ""
                if Self.hasReply(2, in: text) && Self.hasReply(3, in: text) {
                    break
                }
            } else if !process.isRunning {
                let rest = handle.readDataToEndOfFile()
                collected.append(rest)
                break
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return collected
    }

    private static func hasReply(_ id: Int, in text: String) -> Bool {
        text.contains(#""id":\#(id)"#) || text.contains(#""id": \#(id)"#)
    }

    static func parse(_ data: Data, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        let text = String(data: data, encoding: .utf8) ?? ""
        var resultJSON: [String: Any]?
        var accountJSON: [String: Any]?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = AIUsageJSON.object(from: Data(line.utf8)),
                  let result = AIUsageJSON.dictionary(object["result"]) else { continue }
            switch AIUsageJSON.number(object["id"]) {
            case 2?: resultJSON = result
            case 3?: accountJSON = AIUsageJSON.dictionary(result["account"])
            default: continue
            }
        }
        guard let resultJSON,
              let rate = AIUsageJSON.dictionary(resultJSON["rateLimits"]) else {
            return .failure(.init(message: "Codex CLI did not return structured usage. Run /usage in Codex and retry."))
        }
        var windows: [AIUsageWindow] = []
        if let primary = window(from: rate["primary"], id: "primary") {
            windows.append(primary)
        }
        if let secondary = window(from: rate["secondary"], id: "secondary") {
            windows.append(secondary)
        }
        guard !windows.isEmpty else {
            return .failure(.init(message: "Codex CLI did not return any usage windows."))
        }
        let plan = AIUsageJSON.string(rate["planType"])
        var snapshot = AIUsageSnapshot(
            provider: .codex,
            status: .ready,
            plan: plan,
            windows: windows,
            fetchedAt: now,
            sourceLabel: sourceLabel
        )
        snapshot.accountEmail = accountJSON.flatMap { AIUsageJSON.string($0["email"]) }
        return .success(snapshot)
    }

    private static func window(from raw: Any?, id: String) -> AIUsageWindow? {
        guard let object = AIUsageJSON.dictionary(raw),
              let used = AIUsageJSON.number(object["usedPercent"]) else { return nil }
        let minutes = AIUsageJSON.number(object["windowDurationMins"])
        let seconds = minutes.map { $0 * 60 }
        let title: String
        switch seconds {
        case 18_000: title = "5-hour"
        case 604_800: title = "Weekly"
        default: title = id == "primary" ? "Session" : "Weekly"
        }
        return AIUsageWindow(
            id: id,
            title: title,
            usedPercent: AIUsageMath.percent(from: used),
            resetsAt: AIUsageJSON.date(object["resetsAt"]),
            durationSeconds: seconds
        )
    }
}
