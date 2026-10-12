import XCTest
@testable import Geraldine

final class AIUsageGrokCursorCLITests: XCTestCase {
    private static let grokTerminal = """
    Weekly limit (X Premium+)██████████████████████████████100%Resets: September 17, 01:27
    Weekly limit left: 0%
    """

    /// Live Grok 1.0.34 `/usage` modal: the used percent sits on the next
    /// framed row, far more than 80 characters after the plan name.
    private static let grokLiveModal = """
    │  Context usage  Usage limit  Session info                                  │
    │────────────────────────────────────────────────────────────────────────────│
    │  Weekly limit (X Premium+)                                                 │
    │                                                                            │
    │  ███████░░░░░░░░░░░░░░░░░░░░░░░  22%                                       │
    │  Resets: September 24, 01:27                                               │
    │                                                                            │
    │  Loading session usage…                                                    │
    """

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

    private static let cursorCompact = """
    Monthly plan and on-demand usage
    Included: 71% used
    Auto: 67% used
    API: 100% used
    On-Demand: Disabled
    """

    func testGrokParsesTUIWeeklyLimitAndRejectsModelErrors() throws {
        let now = Date(timeIntervalSince1970: 3)
        let ready = try GrokCLIUsage.parse(Data(Self.grokTerminal.utf8), now: now).get()
        XCTAssertEqual(ready.sourceLabel, GrokCLIUsage.sourceLabel)
        XCTAssertEqual(ready.plan, "X Premium+")
        XCTAssertEqual(ready.windows.first?.id, "pool")
        XCTAssertEqual(ready.windows.first?.usedPercent, 100)
        XCTAssertEqual(ready.windows.first?.remainingPercent, 0)
        let live = try GrokCLIUsage.parse(Data(Self.grokLiveModal.utf8), now: now).get()
        XCTAssertEqual(live.plan, "X Premium+")
        XCTAssertEqual(live.windows.first?.title, "Weekly")
        XCTAssertEqual(live.windows.first?.usedPercent, 22)
        XCTAssertEqual(live.windows.first?.remainingPercent, 78)
        let jsonReady = try GrokCLIUsage.parse(Data(#"{"creditUsagePercent":10}"#.utf8), now: now).get()
        XCTAssertEqual(jsonReady.windows.first?.usedPercent, 10)
        guard case .failure = GrokCLIUsage.parse(
            Data(#"{"type":"error","message":"API error (status 402 Payment Required)"}"#.utf8),
            now: now
        ) else {
            return XCTFail("Model or payment errors are not usage windows")
        }
        XCTAssertNil(GrokCLIUsage.parseTerminal("API error (status 402 Payment Required): Grok Build usage balance exhausted", now: now))
        XCTAssertNil(GrokCLIUsage.parseTerminal("Couldn't load usage: timeout", now: now))
        XCTAssertNil(GrokCLIUsage.parseTerminal("No billing data available.", now: now))
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

    func testGrokColoredModalPreservesThePrintedReset() throws {
        // Sanitized Grok 1.0.50 /usage rows, including its true-color sequences.
        let modal = """
        \u{1b}[1mWeekly limit (X Premium+)\u{1b}[22m                                                 \u{1b}[38;2;88;88;88;48;2;20;20;20m
        \u{1b}[38;2;120;120;120;48;2;20;20;20m████\u{1b}[38;2;88;88;88;48;2;20;20;20m░░░░░░░░░░░░░░░░░░░░░░░░░░\u{1b}[38;2;225;225;225;48;2;20;20;20m  13%                                       \u{1b}[38;2;88;88;88;48;2;20;20;20m
        \u{1b}[38;2;108;108;108;48;2;20;20;20mResets: October 15, 01:27\u{1b}[38;2;225;225;225;48;2;20;20;20m                                                 \u{1b}[38;2;88;88;88;48;2;20;20;20m
        """
        try assertGrokPrintedReset(modal)
    }

    func testGrokCursorPositionedRedrawSeparatesResetFromSessionUsage() throws {
        // The same live modal can arrive as cursor moves with no newlines.
        let modal = "\u{1b}[9;25H\u{1b}[1m\u{1b}[38;2;225;225;225;48;2;20;20;20mWeekly limit (X Premium+)"
            + "\u{1b}[11;25H\u{1b}[22m\u{1b}[38;2;120;120;120;48;2;20;20;20m████\u{1b}[38;2;88;88;88;48;2;20;20;20m░░░░░░░░░░░░░░░░░░░░░░░░░░"
            + "\u{1b}[11;57H\u{1b}[38;2;225;225;225;48;2;20;20;20m13%"
            + "\u{1b}[12;25H\u{1b}[38;2;108;108;108;48;2;20;20;20mResets: October 15, 01:27"
            + "\u{1b}[14;25H\u{1b}[1m\u{1b}[38;2;225;225;225;48;2;20;20;20mSession usage: no model calls yet in this session.\u{1b}[0m"
        try assertGrokPrintedReset(modal)
    }

    func testGrokMissingOrInvalidResetDoesNotInventADate() throws {
        for reset in ["", "\u{1b}[38;2;108;108;108mResets: unavailable\u{1b}[0m",
                      "\u{1b}[38;2;108;108;108mResets: October 35, 01:27\u{1b}[0m"] {
            let modal = "\u{1b}[1mWeekly limit (X Premium+)\u{1b}[22m\n13%\n" + reset
            let snapshot = try GrokCLIUsage.parse(Data(modal.utf8), now: Date()).get()
            XCTAssertEqual(snapshot.windows.first?.remainingPercent, 87)
            XCTAssertNil(snapshot.windows.first?.resetsAt)
        }
    }

    func testPTYStripsTerminalDecorationAndPreservesPositionedTextBoundaries() {
        let terminal = "\u{1b}]0;Grok Build\u{07}\u{1b}[?2026h\u{1b}[1mUsage\u{1b}[22m"
            + "\u{1b}[12;25H\u{1b}[38;2;108;108;108;48;2;20;20;20mResets: October 15, 01:27\u{1b}[0m"
            + "\u{1b}[14;25fSession usage\u{1b}[?2026l\u{1b}=\u{1b}>"
        XCTAssertEqual(AgentPTY.stripANSI(terminal), "Usage\nResets: October 15, 01:27\nSession usage")
        let plain = "Weekly limit (X Premium+)\n13%\nResets: October 15, 01:27"
        XCTAssertEqual(AgentPTY.stripANSI(plain), plain)
    }

    func testCursorColoredUsagePreservesItsResetAndMeters() throws {
        let terminal = "\u{1b}[1mUsage • Ultra\u{1b}[22m  \u{1b}[2mResets Oct 16\u{1b}[0m\n"
            + Self.cursorCompact
        let snapshot = try CursorCLIUsage.parse(Data(terminal.utf8), now: Date(timeIntervalSince1970: 1_791_763_200)).get()
        XCTAssertEqual(snapshot.windows.first(where: { $0.id == "totalPercentUsed" })?.usedPercent, 71)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt != nil && $0.resetIsDateOnly })
    }

    private func assertGrokPrintedReset(_ terminal: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12)))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 1, minute: 27)))
        let snapshot = try GrokCLIUsage.parse(Data(terminal.utf8), now: now).get()
        XCTAssertEqual(snapshot.plan, "X Premium+", file: file, line: line)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 87, file: file, line: line)
        XCTAssertEqual(snapshot.windows.first?.resetsAt, expected, file: file, line: line)
        XCTAssertEqual(snapshot.windows.first?.resetIsDateOnly, false, file: file, line: line)
    }

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

    private struct NoHTTP: AIUsageTransporting {
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Grok and Cursor must only use their CLIs")
            throw URLError(.unsupportedURL)
        }
    }
}
