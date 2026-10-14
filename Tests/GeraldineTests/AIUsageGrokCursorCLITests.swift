import XCTest
@testable import Geraldine

final class AIUsageGrokCursorCLITests: XCTestCase {
    /// Grok 1.0.52 `grok agent stdio` reply to `_x.ai/billing`.
    private static let grokBillingReply = #"{"jsonrpc":"2.0","id":2,"result":{"config":{"creditUsagePercent":16.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-10-13T05:49:09.497+00:00","end":"2026-10-20T05:49:09.497+00:00"},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true,"billingPeriodStart":"2026-10-13T05:49:09.497+00:00","billingPeriodEnd":"2026-10-20T05:49:09.497+00:00"},"subscription_tier":"SuperGrok"}}"#

    private static let cursorTerminal = """
    Usage • Ultra                                                                                           Resets Oct 6
    Monthly plan and on-demand usage

    Category        Current             Usage
    Included        53% used
      Auto          47% used
      API           100% used
    On-Demand       Disabled
    """

    /// Live Cursor Agent 2026.09.10 `/usage` pager (wide layout with meter bars).
    private static let cursorLivePager = """
    Usage • Ultra                                                                                           Resets Oct 6
    Monthly plan and on-demand usage

    Category        Current             Usage
    Included        71% used            █████████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░
      Auto          67% used            ██████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░
      API           100% used           ████████████████████████████████████████████████████████████████████████████████
    On-Demand       Disabled
    """

    /// Live Cursor Agent 2026.10.01 `/usage` pager, on-demand with no limit.
    private static let cursorPagerOnDemand = """
    Usage • Premium                                                                                        Resets Oct 20
    Monthly plan and on-demand usage
    Category        Current             Usage
    Included        17% used            ██████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      Auto          17% used            ██████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
      API           0% used             ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
    On-Demand       $0                  ————————————————————————————————————————————————————————————————————————————————
    No monthly limit
    View in dashboard: cursor.com/dashboard?tab=usage
    Esc to close
    """

    private static let cursorCompact = """
    Monthly plan and on-demand usage
    Included: 71% used
    Auto: 67% used
    API: 100% used
    On-Demand: Disabled
    """

    // MARK: - Grok

    func testGrokReadsTheBillingReply() throws {
        let snapshot = try GrokCLIUsage.parse(Data(Self.grokBillingReply.utf8), now: Date(timeIntervalSince1970: 3)).get()
        XCTAssertEqual(snapshot.sourceLabel, GrokCLIUsage.sourceLabel)
        XCTAssertEqual(snapshot.plan, "SuperGrok")
        XCTAssertEqual(snapshot.windows.first?.id, "pool")
        XCTAssertEqual(snapshot.windows.first?.title, "Weekly")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 16)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 84)
        XCTAssertEqual(snapshot.windows.first?.resetIsDateOnly, false)
        let expected = try XCTUnwrap(Self.utcDate(2026, 10, 20, 5, 49, 9))
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.resetsAt).timeIntervalSince(expected), 0.497, accuracy: 0.001)
    }

    func testGrokNamesWhatWentWrongInsteadOfInventingUsage() {
        func message(_ reply: String) -> String? {
            guard case .failure(let error) = GrokCLIUsage.parse(Data(reply.utf8), now: Date()) else { return nil }
            return error.message
        }
        XCTAssertEqual(message(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#),
                       "This Grok CLI has no usage request. Update Grok, then refresh.")
        XCTAssertEqual(message(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}"#),
                       "Grok CLI is signed out. Sign in to the Grok CLI, then refresh.")
        XCTAssertEqual(message(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"upstream timeout"}}"#),
                       AICodingProvider.grok.usageUnavailableHint)
        XCTAssertNotNil(message(#"{"jsonrpc":"2.0","id":2,"result":{"config":{"prepaidBalance":{"val":0}}}}"#))
        XCTAssertNotNil(message("Weekly limit (SuperGrok) 16%"))
    }

    func testGrokFetchSpeaksStdioWithoutATerminalSessionOrLeader() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("grok-log")
        try writeExecutable(at: home.appendingPathComponent(".local/bin/grok"), script: """
        #!/bin/sh
        printf 'args=%s\\n' "$*" >> '\(log.path)'
        if [ -t 0 ]; then echo 'stdin=tty' >> '\(log.path)'; else echo 'stdin=pipe' >> '\(log.path)'; fi
        printf 'cwd=%s\\n' "$PWD" >> '\(log.path)'
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) echo '{"jsonrpc":"2.0","method":"_x.ai/notice","params":{}}'
                                       echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}' ;;
            *'"method":"_x.ai/billing"'*) echo '\(Self.grokBillingReply)' ;;
          esac
        done
        echo 'eof' >> '\(log.path)'
        """)
        let snapshot = await AIUsageFetcher.fetch(.grok, transport: NoHTTP(), homeDirectory: home)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.plan, "SuperGrok")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 16)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "args=agent --no-leader stdio")
        XCTAssertTrue(lines.contains("stdin=pipe"))
        XCTAssertTrue(lines.contains { $0.hasSuffix("Library/Application Support/Geraldine/Usage Workspace") })
        // Closing stdin is what ends the agent; it must not be left running.
        XCTAssertEqual(lines.last, "eof")
    }

    func testExchangeSurvivesACLIThatExitsOrNeverAnswers() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let quits = home.appendingPathComponent("quits")
        try writeExecutable(at: quits, script: "#!/bin/sh\nexit 0\n")
        // Writing to a CLI that already exited must not raise SIGPIPE in Geraldine.
        for _ in 0..<3 {
            XCTAssertNil(AgentCLI.exchange(executable: quits, arguments: [], homeDirectory: home,
                                           workingDirectory: home, requests: [(1, "{}"), (2, "{}")], timeout: 2))
        }
        let silent = home.appendingPathComponent("silent")
        try writeExecutable(at: silent, script: "#!/bin/sh\nexec sleep 30\n")
        let started = Date()
        XCTAssertNil(AgentCLI.exchange(executable: silent, arguments: [], homeDirectory: home,
                                       workingDirectory: home, requests: [(1, "{}")], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    // MARK: - Cursor

    func testCursorParsesTUIMetersAndRejectsUnauthenticatedOrModelTurns() throws {
        let now = Date(timeIntervalSince1970: 4)
        let ready = try CursorCLIUsage.parse(Data(Self.cursorTerminal.utf8), now: now).get()
        XCTAssertEqual(ready.sourceLabel, CursorCLIUsage.sourceLabel)
        XCTAssertEqual(ready.plan, "Ultra")
        XCTAssertEqual(ready.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 47)
        XCTAssertEqual(ready.windows.first(where: { $0.id == "apiPercentUsed" })?.usedPercent, 100)
        XCTAssertEqual(ready.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 53)
        XCTAssertEqual(ready.displayWindows.map(\.id), ["autoPercentUsed", "apiPercentUsed"])
        XCTAssertEqual(ready.displayWindows.map(\.title), ["Cursor models", "Other models"])
        let live = try CursorCLIUsage.parse(Data(Self.cursorLivePager.utf8), now: now).get()
        XCTAssertEqual(live.plan, "Ultra")
        XCTAssertEqual(live.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 71)
        XCTAssertEqual(live.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 67)
        XCTAssertEqual(live.displayWindows.map(\.id), ["autoPercentUsed", "apiPercentUsed"])
        let compact = try CursorCLIUsage.parse(Data(Self.cursorCompact.utf8), now: now).get()
        XCTAssertEqual(compact.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 71)
        XCTAssertEqual(compact.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 67)
        let body = Data(#"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":30,"totalPercentUsed":28}}"#.utf8)
        let jsonReady = try CursorCLIUsage.parse(body, now: now).get()
        XCTAssertEqual(jsonReady.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 25)
        guard case .failure = CursorCLIUsage.parse(
            Data(#"{"status":"unauthenticated","isAuthenticated":false}"#.utf8),
            now: now
        ) else {
            return XCTFail("Unauthenticated Cursor CLI must be unavailable")
        }
        guard case .failure = CursorCLIUsage.parse(
            Data(#"{"num_turns":1,"planUsage":{"autoPercentUsed":25}}"#.utf8),
            now: now
        ) else {
            return XCTFail("A model turn is not structured Cursor usage")
        }
        XCTAssertNil(CursorCLIUsage.parseTerminal("Not logged in. Run /login first.", now: now))
        XCTAssertNil(CursorCLIUsage.parseTerminal("Press any key to log in...", now: now))
        XCTAssertNil(CursorCLIUsage.parseTerminal("Signing in with the browser...", now: now))
    }

    func testCursorParsesTheOnDemandPager() throws {
        let now = Date(timeIntervalSince1970: 1_791_763_200)
        let snapshot = try CursorCLIUsage.parse(Data(Self.cursorPagerOnDemand.utf8), now: now).get()
        XCTAssertEqual(snapshot.plan, "Premium")
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 17)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 17)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "apiPercentUsed" })?.usedPercent, 0)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil && $0.resetIsDateOnly })
    }

    func testCursorColoredUsagePreservesItsResetAndMeters() throws {
        let terminal = "\u{1b}[1mUsage • Ultra\u{1b}[22m  \u{1b}[2mResets Oct 16\u{1b}[0m\n"
            + Self.cursorCompact
        let snapshot = try CursorCLIUsage.parse(Data(terminal.utf8), now: Date(timeIntervalSince1970: 1_791_763_200)).get()
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 71)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil && $0.resetIsDateOnly })
    }

    func testCursorRunsInGeraldinesWorkspaceWithoutSelfUpdating() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspace = AgentCLI.usageWorkspace(homeDirectory: home)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(workspace.path, home.appendingPathComponent("Library/Application Support/Geraldine/Usage Workspace").path)
        XCTAssertEqual(CursorCLIUsage.arguments(workspace: workspace),
                       ["--disable-auto-update", "--trust", "--workspace", workspace.path])
        XCTAssertEqual(CursorCLIUsage.promptReplies.map(\.containing), ["Continue without approval"])
        XCTAssertEqual(CursorCLIUsage.promptReplies.map(\.write), [Data("c".utf8)])
    }

    func testCursorFailureNamesTheScreenItStoppedOn() {
        XCTAssertEqual(CursorCLIUsage.failureMessage(screen: "Press any key to log in..."),
                       "Cursor Agent is signed out. Sign in to the Cursor Agent CLI, then refresh.")
        XCTAssertEqual(CursorCLIUsage.failureMessage(screen: "⚠ MCP Server Approval Required\n[c] Continue without approval"),
                       "Cursor Agent stopped on its MCP approval screen.")
        XCTAssertEqual(CursorCLIUsage.failureMessage(screen: "MCP Server Approval Required\n→ Plan, search, build anything"),
                       "Cursor Agent did not open /usage in time.")
        XCTAssertEqual(CursorCLIUsage.failureMessage(screen: "  \n"), "Cursor Agent CLI did not start.")
        XCTAssertNil(CursorCLIUsage.failureMessage(screen: "/usage   Show plan and on-demand usage\nUsage • Pro"))
    }

    /// A fake Cursor TUI: the MCP approval screen and a styled prompt arrive
    /// together, any key but `c` on that screen counts as approving, and the
    /// prompt hides "Plan, search" behind a reverse-video fake cursor.
    func testCursorCaptureDeclinesMCPApprovalAndTypesThroughTheFakeCursor() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent("cursor-log")
        try writeExecutable(at: home.appendingPathComponent(".local/bin/cursor-agent"), script: """
        #!/bin/bash
        printf 'args=%s\\n' "$*" >> '\(log.path)'
        printf 'tty=%s\\n' "$(ps -o tty= -p $$ | tr -d ' ')" >> '\(log.path)'
        printf 'size=%s\\n' "$(stty size)" >> '\(log.path)'
        stty raw -echo
        prompt=$'\\e[7mP\\e[27m\\e[2mlan, search, build anything\\e[22m'
        printf '\\r\\n MCP Server Approval Required\\r\\n \\342\\226\\266 [a] Approve all servers\\r\\n   [c] Continue without approval\\r\\n   [q] Quit\\r\\n%s\\r\\n' "$prompt"
        IFS= read -r -n1 key
        printf 'dialog=%s\\n' "$key" >> '\(log.path)'
        [ "$key" = "c" ] || exit 3
        printf '\\r\\n Cursor Agent\\r\\n \\342\\206\\222 %s\\r\\n' "$prompt"
        typed=""
        while [ "${#typed}" -lt 6 ]; do IFS= read -r -n1 ch; typed="$typed$ch"; done
        printf 'typed=%s\\n' "$typed" >> '\(log.path)'
        printf '\\r\\n /usage   Show plan and on-demand usage\\r\\n'
        IFS= read -r -n1 enter
        printf 'Usage \\342\\200\\242 Premium      Resets Oct 20\\r\\nMonthly plan and on-demand usage\\r\\nIncluded   17%% used\\r\\n  Auto     17%% used\\r\\n  API      0%% used\\r\\n'
        exec sleep 30
        """)
        let snapshot = await AIUsageFetcher.fetch(.cursor, transport: NoHTTP(), homeDirectory: home)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.plan, "Premium")
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "autoPercentUsed" })?.usedPercent, 17)
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "apiPercentUsed" })?.usedPercent, 0)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let workspace = AgentCLI.usageWorkspace(homeDirectory: home).path
        XCTAssertEqual(lines.first, "args=--disable-auto-update --trust --workspace \(workspace)")
        XCTAssertTrue(lines.contains("dialog=c"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("typed=/usage"), lines.joined(separator: "\n"))
        // The TUI's controlling terminal is the PTY, so it hangs up with Geraldine.
        XCTAssertTrue(lines.contains { $0.hasPrefix("tty=ttys") }, lines.joined(separator: "\n"))
        // Rows and columns reach the TUI; at zero it lays the prompt out one column wide.
        XCTAssertTrue(lines.contains("size=40 120"), lines.joined(separator: "\n"))
    }

    // MARK: - Terminal capture

    func testScreenMatchingSeesThroughStyling() {
        let prompt = "\u{1b}[2m→ \u{1b}[22m\u{1b}[7mP\u{1b}[27m\u{1b}[2mlan, search, build anything\u{1b}[22m"
        XCTAssertFalse(AgentPTY.containsLoose(prompt, "Plan, search"))
        XCTAssertTrue(AgentPTY.containsLoose(AgentPTY.stripANSI(prompt), "Plan, search"))
        XCTAssertEqual(AgentPTY.stripANSI("\u{1b}[>1u\u{1b}[<uCursor Agent"), "Cursor Agent")
    }

    func testPTYAnswersDeviceQueriesBeforeGrokWillPaint() {
        var responder = AgentPTY.QueryResponder()
        let startup = "\u{1b}[?1000h\u{1b}[?u\u{1b}[c\u{1b}[6n\u{1b}[>0q"
        let replies = responder.replies(for: startup, colorQuery: true).compactMap { String(data: $0, encoding: .utf8) }
        XCTAssertTrue(replies.contains("\u{1b}[1;1R"))
        XCTAssertTrue(replies.contains("\u{1b}P>|xterm-256color\u{1b}\\"))
        XCTAssertTrue(replies.contains("\u{1b}[?62;1;4;6;9;15;22;29c"))
        XCTAssertTrue(replies.contains("\u{1b}[?0u"))
        XCTAssertTrue(responder.deviceAttributes)
        XCTAssertTrue(responder.kittyKeyboard)
        let trust = responder.replies(
            for: "Do you trust the contents of this directory?\nGrok Build may run or modify contents",
            colorQuery: true
        )
        XCTAssertEqual(trust, [Data("y\r".utf8)])
    }

    func testPTYStripsTerminalDecorationAndPreservesPositionedTextBoundaries() {
        let terminal = "\u{1b}]0;Grok Build\u{07}\u{1b}[?2026h\u{1b}[1mUsage\u{1b}[22m"
            + "\u{1b}[12;25H\u{1b}[38;2;108;108;108;48;2;20;20;20mResets: October 15, 01:27\u{1b}[0m"
            + "\u{1b}[14;25fSession usage\u{1b}[?2026l\u{1b}=\u{1b}>"
        XCTAssertEqual(AgentPTY.stripANSI(terminal), "Usage\nResets: October 15, 01:27\nSession usage")
        let plain = "Weekly limit (X Premium+)\n13%\nResets: October 15, 01:27"
        XCTAssertEqual(AgentPTY.stripANSI(plain), plain)
    }

    func testMissingGrokAndCursorCLIsStayUnavailableWithoutHTTP() async {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("missing-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for provider in [AICodingProvider.grok, .cursor] {
            let snapshot = await AIUsageFetcher.fetch(provider, transport: NoHTTP(), homeDirectory: home)
            guard case .error = snapshot.status else {
                XCTFail("\(provider) must not invent usage"); continue
            }
        }
    }

    // MARK: - Helpers

    private func makeHome() throws -> URL {
        let root = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let home = root.appendingPathComponent("grok-cursor-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeExecutable(at url: URL, script: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int,
                                _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Grok and Cursor must only use their CLIs")
            throw URLError(.unsupportedURL)
        }
    }
}
