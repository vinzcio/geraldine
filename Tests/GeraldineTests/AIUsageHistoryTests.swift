import XCTest
import SwiftUI
import AppKit
import SQLite3
@testable import Geraldine

final class AIUsageHistoryTests: XCTestCase {
    private func row(_ text: String) throws -> [String: Any] { try XCTUnwrap(AIUsageJSON.object(from: Data(text.utf8))) }
    private func parse(_ provider: AICodingProvider, _ json: String) throws -> AIHistoryRecord {
        var parser = AIHistoryParser(provider: provider)
        return try XCTUnwrap(parser.parse(row(json)).first)
    }
    private let timestamp = "2026-10-28T01:00:00Z"

    func testClaudeRepeatedContentBlocksAreOneUsageAndCacheIsDisjoint() throws {
        let record = try parse(.claude, #"{"type":"assistant","timestamp":"2026-10-28T01:00:00Z","requestId":"req","message":{"id":"msg","model":"claude-test","usage":{"input_tokens":20,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":5}}}"#)
        let result = AIHistoryReader.deduplicate([record, record])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tokens.total, 135)
    }

    func testCodexCumulativeCountersRejectRepeatedNotificationsAndCountLatestRequest() throws {
        var parser = AIHistoryParser(provider: .codex)
        _ = parser.parse(try row(#"{"type":"turn_context","payload":{"model":"gpt-test","service_tier":"priority"}}"#))
        let event = try row(#"{"type":"event_msg","timestamp":"2026-10-28T01:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120},"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":120}}}}"#)
        let first = try XCTUnwrap(parser.parse(event).first)
        XCTAssertEqual(first.tokens.input, 40); XCTAssertEqual(first.tokens.total, 120)
        XCTAssertEqual(first.speed, "fast")
        XCTAssertTrue(parser.parse(event).isEmpty)
    }

    func testGrokCompletedTurnPreservesReportedCostAndInclusiveInput() throws {
        let record = try parse(.grok, #"{"params":{"sessionId":"s","_meta":{"agentTimestampMs":1793149200000},"update":{"sessionUpdate":"turn_completed","prompt_id":"p","usage":{"modelUsage":{"grok-test":{"inputTokens":100,"cachedReadTokens":30,"cacheCreationTokens":10,"outputTokens":20,"reasoningTokens":5,"costUsdTicks":5000000000}}}}}}"#)
        XCTAssertEqual(record.tokens.input, 60); XCTAssertEqual(record.tokens.total, 120)
        XCTAssertEqual(record.reportedCost, 0.5)
    }

    func testOpenCodeAddsSeparateReasoningAndZeroCostMeansUnknown() throws {
        let record = try parse(.opencode, #"{"id":"m","role":"assistant","modelID":"test","time":{"created":1793149200000},"tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":30,"write":4}},"cost":0}"#)
        XCTAssertEqual(record.tokens.output, 25); XCTAssertEqual(record.tokens.total, 69)
        XCTAssertNil(record.reportedCost)
    }

    func testPiCacheDisjointAndReasoningAlreadyInOutput() throws {
        let record = try parse(.pi, #"{"id":"m","type":"message","timestamp":"2026-10-28T01:00:00Z","message":{"role":"assistant","provider":"openai","model":"test","usage":{"input":10,"output":20,"reasoning":5,"cacheRead":30,"cacheWrite":4,"cost":{"total":0}}}}"#)
        XCTAssertEqual(record.tokens.total, 64); XCTAssertNil(record.reportedCost)
    }

    func testMuseMicrosecondsCacheSubsetsAndSourceRunDeduplication() throws {
        let record = try parse(.muse, #"{"schema_version":1,"record_type":"event","payload_type":"runtime.session","payload_schema_version":3,"id":"envelope","recorded_at":1793149200000000,"stream":{"kind":"session","id":"s"},"payload":{"source_run_record_id":"original","event":{"kind":"automated_review_completed","model":{"model_id":"test"},"usage":{"input_tokens":100,"cached_tokens":60,"cache_write_tokens":10,"output_tokens":20,"reasoning_tokens":5}}}}"#)
        XCTAssertEqual(record.tokens.input, 30); XCTAssertEqual(record.tokens.total, 120)
        XCTAssertEqual(record.date.timeIntervalSince1970, 1793149200)
        XCTAssertEqual(record.keys, ["muse:original"])
    }

    func testPricesSeparateCachesRespectFreeRatesAndUnknownModels() throws {
        let prices = AIHistoryPrices(data: Data(#"{"test":{"input_cost_per_token":0.01,"output_cost_per_token":0.02,"cache_read_input_token_cost":0,"cache_creation_input_token_cost":0.03,"provider_specific_entry":{"fast":2}},"free":{"input_cost_per_token":0,"output_cost_per_token":0}}"#.utf8))
        var record = AIHistoryRecord(model: "test", date: .now, tokens: AIHistoryTokens(input: 10, cacheRead: 100, cacheWrite: 5, output: 20, reasoning: 10))
        XCTAssertEqual(try XCTUnwrap(prices.cost(record)), 0.65, accuracy: 0.00001)
        record.speed = "fast"; XCTAssertEqual(try XCTUnwrap(prices.cost(record)), 1.3, accuracy: 0.00001)
        record.model = "free"; XCTAssertEqual(prices.cost(record), 0)
        record.model = "unknown"; XCTAssertNil(prices.cost(record))
        record.reportedCost = 7
        let summary = AIHistorySummary(read: AIHistoryRead(records: [record], source: "fixture"), prices: prices)
        XCTAssertEqual(summary.cost, 7); XCTAssertEqual(summary.unpricedRecords, 0)
    }

    func testAntigravityProtobufRejectsTruncatedOrOverflowFields() throws {
        XCTAssertThrowsError(try AntigravityHistory.Proto(Data([10, 10, 1])))
        XCTAssertThrowsError(try AntigravityHistory.Proto(Data(repeating: 255, count: 10)))
        let proto = try AntigravityHistory.Proto(Data([16, 100, 24, 20, 40, 30]))
        XCTAssertEqual(proto.number(2), 100); XCTAssertEqual(proto.number(3), 20)
    }

    func testAntigravityOverlappingIdentitiesMergeWithoutDoubleCounting() {
        let a = AIHistoryRecord(model: "test", date: .now, tokens: AIHistoryTokens(input: 10, output: 5), keys: ["a"])
        let b = AIHistoryRecord(model: "test", date: .now, tokens: AIHistoryTokens(input: 9, output: 7), keys: ["b"])
        let bridge = AIHistoryRecord(model: "test", date: .now, tokens: AIHistoryTokens(input: 10, output: 7), keys: ["a", "b"])
        let result = AIHistoryReader.deduplicate([a, b, bridge], merge: true)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].tokens.total, 17)
    }

    func testSiblingHomesStayIsolatedAndLocalReaderRunsEndToEnd() throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".claude-work/projects/p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let event = #"{"type":"assistant","timestamp":"2026-10-28T01:00:00Z","message":{"id":"m","model":"test","usage":{"input_tokens":20,"output_tokens":5}}}"#
        try Data((event + "\n" + event + "\n").utf8).write(to: dir.appendingPathComponent("session.jsonl"))
        let reader = AIHistoryReader(home: root, environment: [:])
        XCTAssertTrue(try reader.read(AIUsageIdentity(.claude)).records.isEmpty)
        let work = try reader.read(AIUsageIdentity(.claude, accountKey: "work"))
        XCTAssertEqual(work.records.count, 1); XCTAssertEqual(work.records[0].tokens.total, 25)
        XCTAssertNil(work.notice)
    }

    func testCursorUsesOnlyFileCredentialsAndPreservesIdenticalBilledRows() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = Data(#"{"sub":"auth0|fixture"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        try JSONSerialization.data(withJSONObject: ["accessToken": "x.\(payload).x"]).write(to: dir.appendingPathComponent("auth.json"))
        let cursor = CursorHistory(fetch: { request in
            XCTAssertEqual(request.url, CursorHistory.endpoint)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=fixture") == true)
            let row: [String: Any] = ["timestamp": "1793149200000", "model": "test", "tokenUsage": ["inputTokens": 10, "cacheReadTokens": 20, "outputTokens": 5, "totalCents": 25]]
            return try JSONSerialization.data(withJSONObject: ["totalUsageEventsCount": 2, "usageEventsDisplay": [row, row]])
        })
        let read = try await cursor.read(home: root, now: Date(timeIntervalSince1970: 1793200000))
        XCTAssertEqual(read.records.count, 2)
        XCTAssertEqual(read.records.compactMap(\.reportedCost).reduce(0, +), 0.5)
    }

    private func testRoot() throws -> URL {
        let base = ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"] ?? FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: base).appendingPathComponent("history-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@MainActor
final class AIUsageHistoryWorkflowTests: XCTestCase {
    func testRefreshRetainsChosenDirectoryAndCanRenderWithoutOpeningWindows() async throws {
        let identity = AIUsageIdentity(.claude)
        let directory = URL(fileURLWithPath: "/fixture/history")
        let record = AIHistoryRecord(model: "test-model", date: Date(timeIntervalSince1970: 1793149200), tokens: AIHistoryTokens(input: 1200, cacheRead: 20000, cacheWrite: 300, output: 450, reasoning: 100))
        let monitor = AIUsageHistoryMonitor(defaults: isolatedDefaults(), readHistory: { received, folder in
            XCTAssertEqual(received, identity); XCTAssertEqual(folder, directory)
            return AIHistoryRead(records: [record], source: "Fixture history")
        }, fetchPrices: { Data(#"{"test-model":{"input_cost_per_token":0.000003,"output_cost_per_token":0.000015,"cache_read_input_token_cost":0.0000003}}"#.utf8) })
        monitor.refresh(identity, directory: directory)
        for await values in monitor.$reading.values where values.isEmpty { break }
        XCTAssertEqual(monitor.summaries[identity]?.tokens.total, 21950)
        monitor.refresh(identity)
        for await values in monitor.$reading.values where values.isEmpty { break }
        XCTAssertNil(monitor.errors[identity])
        guard let output = ProcessInfo.processInfo.environment["AI_HISTORY_RENDER_DIR"] else { return }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 16) {
                CodingUsageHistoryView(history: monitor, accounts: [AIUsageAccount(identity: identity, name: "Personal")], title: { $0.provider.title })
            }.padding(24).frame(width: scheme == .dark ? 650 : 850).background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("history-\(scheme).png"))
        }
    }

    func testHistoryFailureDoesNotReplaceLastSuccessfulTotals() async {
        actor Reader {
            var calls = 0
            func read() throws -> AIHistoryRead {
                calls += 1
                if calls > 1 { throw HistoryReadError.invalid }
                return AIHistoryRead(records: [AIHistoryRecord(model: "unknown", date: .now, tokens: AIHistoryTokens(input: 10))], source: "fixture")
            }
        }
        let reader = Reader(), id = AIUsageIdentity(.pi)
        let monitor = AIUsageHistoryMonitor(defaults: isolatedDefaults(), readHistory: { _, _ in try await reader.read() }, fetchPrices: { throw HistoryReadError.invalid })
        monitor.refresh(id)
        for await values in monitor.$reading.values where values.isEmpty { break }
        XCTAssertEqual(monitor.summaries[id]?.unpricedRecords, 1)
        monitor.refresh(id)
        for await values in monitor.$reading.values where values.isEmpty { break }
        XCTAssertEqual(monitor.summaries[id]?.tokens.total, 10)
        XCTAssertNotNil(monitor.errors[id]); XCTAssertNotNil(monitor.pricingNotice)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AIHistoryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testLiveBackgroundHistoryReaders() async throws {
        guard ProcessInfo.processInfo.environment["AI_HISTORY_LIVE"] == "1" else { throw XCTSkip("Opt-in live read-only provider history check") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = try await HistoryHTTP().data(URLRequest(url: AIHistoryPrices.url))
        let prices = AIHistoryPrices(data: data)
        XCTAssertFalse(prices.models.isEmpty)
        let selected = ProcessInfo.processInfo.environment["AI_HISTORY_LIVE_PROVIDERS"]?.split(separator: ",").map(String.init)
        for provider in AICodingProvider.allCases where selected == nil || selected!.contains(provider.rawValue) {
            let read: AIHistoryRead
            if provider == .cursor { read = try await CursorHistory().read(home: home) }
            else { read = try await Task.detached { try AIHistoryReader(home: home).read(AIUsageIdentity(provider)) }.value }
            let summary = AIHistorySummary(read: read, prices: prices)
            // Aggregate counts only: never log account identifiers, model prompts, or credentials.
            print("HISTORY_CHECK \(provider.rawValue): records=\(read.records.count), models=\(summary.models.count), tokens=\(summary.tokens.total), unpriced=\(summary.unpricedRecords), notice=\(read.notice ?? "none")")
            print("HISTORY_MODELS \(provider.rawValue): \(summary.models.map(\.model).joined(separator: ", "))")
        }
    }
}

extension AIUsageHistoryTests {
    func testSQLiteSourcesAndLegacyOpenCodeDuplicatesThroughReader() throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("storage/message/s"), withIntermediateDirectories: true)
        let json = #"{"id":"m","role":"assistant","modelID":"test","time":{"created":1793149200000},"tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":30,"write":4}},"cost":0}"#
        try Data(json.replacingOccurrences(of: "\"input\":10", with: "\"input\":1").utf8).write(to: source.appendingPathComponent("storage/message/s/m.json"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE message (id TEXT, data TEXT, time_created INTEGER)", nil, nil, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES ('m', ?, 1793149200000)", -1, &stmt, nil), SQLITE_OK)
        _ = json.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt); sqlite3_close(db)
        let reader = AIHistoryReader(home: root, environment: [:])
        let read = try reader.read(AIUsageIdentity(.opencode), directory: source)
        XCTAssertNil(read.notice); XCTAssertEqual(read.records.count, 1)
        XCTAssertEqual(read.records[0].tokens.total, 69)

        let agy = root.appendingPathComponent("agy")
        try FileManager.default.createDirectory(at: agy, withIntermediateDirectories: true)
        let file = agy.appendingPathComponent("session.db")
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE gen_metadata (idx INTEGER, data BLOB)", nil, nil, nil), SQLITE_OK)
        // Generation metadata field 1 contains usage field 4; usage categories are disjoint.
        let bytes = Data([10, 10, 34, 8, 16, 100, 24, 20, 32, 10, 40, 30])
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO gen_metadata VALUES (1, ?)", -1, &stmt, nil), SQLITE_OK)
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        sqlite3_finalize(stmt); sqlite3_close(db)
        let gravity = try reader.read(AIUsageIdentity(.antigravity), directory: agy)
        XCTAssertNil(gravity.notice); XCTAssertEqual(gravity.records.count, 1)
        XCTAssertEqual(gravity.records[0].tokens.total, 160)
        XCTAssertTrue(gravity.records[0].model.contains("unknown"))
    }

    func testCodexThreadSettingsSpeedSurvivesTurnContext() throws {
        var parser = AIHistoryParser(provider: .codex)
        _ = parser.parse(try row(#"{"type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"ultrafast"}}}"#))
        _ = parser.parse(try row(#"{"type":"turn_context","payload":{"model":"gpt-test"}}"#))
        XCTAssertEqual(parser.speed, "ultrafast")
    }
}

extension AIUsageHistoryTests {
    func testModelAliasesDoNotGuessAmbiguousPricesAndReasoningSuffixUsesExplicitRateModel() throws {
        let prices = AIHistoryPrices(data: Data(#"{"vendor-a/model":{"input_cost_per_token":1,"output_cost_per_token":2},"vendor-b/model":{"input_cost_per_token":3,"output_cost_per_token":4},"claude-test":{"input_cost_per_token":1,"output_cost_per_token":2}}"#.utf8))
        var record = AIHistoryRecord(model: "model", date: .now, tokens: AIHistoryTokens(input: 1))
        XCTAssertNil(prices.cost(record))
        record.model = "claude-test-high"; record.rateModel = "claude-test"
        XCTAssertEqual(prices.cost(record), 1)
        XCTAssertEqual(CursorHistory.rateModel("cursor-grok-4-high-fast"), "xai/grok-4")
    }

    func testCursorReconcilesOverlapWithoutRemovingLegitimateDuplicates() async throws {
        let root = try testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        let payload = Data(#"{"sub":"fixture"}"#.utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: ["accessToken": "x.\(payload).x"]).write(to: root.appendingPathComponent(".cursor/auth.json"))
        let cursor = CursorHistory(fetch: { request in
            let body = try XCTUnwrap(AIUsageJSON.object(from: request.httpBody!))
            let page = body["page"] as? Int
            func event(_ number: Int) -> [String: Any] {
                ["timestamp": 1793149200000 + number, "model": "test", "tokenUsage": ["inputTokens": 1, "totalCents": 1]]
            }
            let events = page == 1 ? (0..<1000).map(event) : [event(999), event(1000)]
            return try JSONSerialization.data(withJSONObject: ["totalUsageEventsCount": 1001, "usageEventsDisplay": events])
        })
        let read = try await cursor.read(home: root, now: Date(timeIntervalSince1970: 1793200000))
        XCTAssertEqual(read.records.count, 1001)
        XCTAssertEqual(read.records.reduce(0) { $0 + $1.tokens.total }, 1001)
    }
}
