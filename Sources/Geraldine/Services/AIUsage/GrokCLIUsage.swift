import Foundation

/// Grok owns authentication. Usage comes from `grok agent stdio`, the CLI's
/// Agent Client Protocol mode: after `initialize`, the `x.ai/billing`
/// extension returns the allowance the TUI `/usage` modal draws. Unlike the
/// TUI, this starts no session, no MCP servers and no session hooks, and the
/// agent exits when its stdin closes.
struct GrokCLIUsage: ProviderUsageReading {
    static let sourceLabel = "Grok CLI"
    static let arguments = ["agent", "--no-leader", "stdio"]
    static let requests: [(id: Int, line: String)] = [
        (1, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false}}}"#),
        (2, #"{"jsonrpc":"2.0","id":2,"method":"_x.ai/billing","params":{}}"#)
    ]

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
        guard let reply = AgentCLI.exchange(
            executable: executable,
            arguments: Self.arguments,
            homeDirectory: homeDirectory,
            workingDirectory: AgentCLI.usageWorkspace(homeDirectory: homeDirectory),
            requests: Self.requests,
            timeout: 20
        ) else {
            return .failed(.grok, message: "Grok CLI did not answer its usage request.")
        }
        switch Self.parse(reply, now: now) {
        case .success(let snapshot): return snapshot
        case .failure(let error): return .failed(.grok, message: error.message)
        }
    }

    /// The JSON-RPC reply to `_x.ai/billing`.
    static func parse(_ data: Data, now: Date) -> Result<AIUsageSnapshot, AIUsageParseError> {
        guard let json = AIUsageJSON.object(from: data) else {
            return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
        }
        if let error = AIUsageJSON.dictionary(json["error"]) {
            let message = AIUsageJSON.string(error["message"]) ?? ""
            if AIUsageJSON.number(error["code"]) == -32601 {
                return .failure(.init(message: "This Grok CLI has no usage request. Update Grok, then refresh."))
            }
            if ["auth", "login", "sign in", "unauthorized"].contains(where: { message.localizedCaseInsensitiveContains($0) }) {
                return .failure(.init(message: "Grok CLI is signed out. Sign in to the Grok CLI, then refresh."))
            }
            return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
        }
        guard let result = AIUsageJSON.dictionary(json["result"]),
              let billing = try? JSONSerialization.data(withJSONObject: result) else {
            return .failure(.init(message: AICodingProvider.grok.usageUnavailableHint))
        }
        switch AIUsageParser.grok(from: billing, now: now) {
        case .success(var snapshot):
            snapshot.sourceLabel = sourceLabel
            return .success(snapshot)
        case .failure(let error):
            return .failure(error)
        }
    }
}
