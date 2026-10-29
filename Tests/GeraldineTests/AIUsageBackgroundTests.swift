import XCTest
@testable import Geraldine

private actor UsageGate {
    private var pending: [AIUsageIdentity: CheckedContinuation<AIUsageSnapshot, Never>] = [:]
    private(set) var calls: [AIUsageIdentity: Int] = [:]
    func fetch(_ id: AIUsageIdentity) async -> AIUsageSnapshot {
        calls[id, default: 0] += 1
        return await withCheckedContinuation { pending[id] = $0 }
    }
    func count(_ id: AIUsageIdentity) -> Int { calls[id, default: 0] }
    func finish(_ id: AIUsageIdentity, at: Date, failed: Bool = false) {
        let value = failed ? AIUsageSnapshot.failed(id.provider, message: "offline") : AIUsageSnapshot(
            provider: id.provider, status: .ready, plan: nil,
            windows: [.init(id: "test", title: "Weekly", usedPercent: 25)], fetchedAt: at, sourceLabel: "fixture")
        pending.removeValue(forKey: id)?.resume(returning: value)
    }
}

@MainActor
final class AIUsageBackgroundTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "UsageBackgroundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Background work failed to reach expected state")
    }
    private func home() -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"] ?? NSTemporaryDirectory())
    }

    func testSlowLoginDoesNotGateNewLoginOrAnotherProvidersCadence() async {
        let gate = UsageGate(), slow = AIUsageIdentity(.claude), fast = AIUsageIdentity(.codex)
        let sibling = AIUsageIdentity(.claude, accountKey: "work")
        var now = Date(timeIntervalSince1970: 1000)
        let monitor = AIUsageMonitor(defaults: defaults(), now: { now }, userHome: home()) { id, _ in await gate.fetch(id) }
        defer { monitor.stop() }
        monitor.connect(slow)
        await until { await gate.count(slow) == 1 }
        monitor.connect(fast)
        monitor.connect(sibling)
        await until { let a = await gate.count(fast); let b = await gate.count(sibling); return a == 1 && b == 1 }
        await gate.finish(fast, at: now)
        await gate.finish(sibling, at: now)
        await until { monitor.snapshot(for: fast).status == .ready && monitor.snapshot(for: sibling).status == .ready }
        now.addTimeInterval(AIUsageMonitor.refreshInterval)
        monitor.refreshIfStale()
        monitor.refreshIfStale()
        await until { let a = await gate.count(fast); let b = await gate.count(sibling); return a == 2 && b == 2 }
        XCTAssertEqual(monitor.snapshot(for: fast).remainingPercent, 75)
        XCTAssertTrue(monitor.isRefreshing(sibling))
        let slowCalls = await gate.count(slow)
        XCTAssertEqual(slowCalls, 1)
        await gate.finish(fast, at: now, failed: true)
        await gate.finish(sibling, at: now)
        await gate.finish(slow, at: now)
        await until { !monitor.isRefreshing }
        XCTAssertEqual(monitor.snapshot(for: fast).remainingPercent, 75)
        XCTAssertEqual(monitor.snapshot(for: fast).fetchedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(monitor.snapshot(for: sibling).status, .ready)
    }

    func testAllProvidersAndSiblingCachesAreAvailableBeforeAnyRefreshOnRelaunch() async {
        let defaults = defaults(), date = Date(timeIntervalSince1970: 1000)
        let ids = AICodingProvider.allCases.map { AIUsageIdentity($0) } + [AIUsageIdentity(.codex, accountKey: "work")]
        let first = AIUsageMonitor(defaults: defaults, now: { date }, userHome: home()) { id, now in
            AIUsageSnapshot(provider: id.provider, status: .ready, plan: nil,
                            windows: [.init(id: "test", title: "Weekly", usedPercent: 25)], fetchedAt: now, sourceLabel: "fixture")
        }
        first.syncShownIdentities(Set(ids))
        await until { !first.isRefreshing }
        first.stop()
        let gate = UsageGate()
        let restored = AIUsageMonitor(defaults: defaults, now: { date.addingTimeInterval(600) }, userHome: home()) { id, _ in await gate.fetch(id) }
        for id in ids { XCTAssertEqual(restored.snapshot(for: id).remainingPercent, 75) }
        restored.start()
        await until { await gate.calls.count == ids.count }
        for id in ids { XCTAssertEqual(restored.snapshot(for: id).fetchedAt, date); await gate.finish(id, at: date, failed: true) }
        await until { !restored.isRefreshing }
        restored.stop()
    }

    func testDisconnectAndStopRejectLateResultsWithoutOverlappingReconnect() async {
        let gate = UsageGate(), id = AIUsageIdentity(.cursor)
        let monitor = AIUsageMonitor(defaults: defaults(), userHome: home()) { id, _ in await gate.fetch(id) }
        monitor.connect(id)
        await until { await gate.count(id) == 1 }
        monitor.disconnect(id)
        await gate.finish(id, at: .now)
        await until { !monitor.isRefreshing }
        XCTAssertEqual(monitor.snapshot(for: id).status, .disconnected)
        monitor.connect(id)
        await until { await gate.count(id) == 2 }
        monitor.stop()
        monitor.connect(id)
        let count = await gate.count(id)
        XCTAssertEqual(count, 2)
        await gate.finish(id, at: .now)
        await until { await gate.count(id) == 3 }
        XCTAssertEqual(monitor.snapshot(for: id).status, .loading)
        await gate.finish(id, at: .now)
        await until { !monitor.isRefreshing }
        monitor.stop()
    }

    func testHistoryDoesNotWaitForPricesOrSlowProviderAndRestoresCache() async {
        actor HistoryGate {
            var price: CheckedContinuation<Data, Error>?
            var slow: CheckedContinuation<AIHistoryRead, Error>?
            func prices() async throws -> Data { try await withCheckedThrowingContinuation { price = $0 } }
            func read(_ id: AIUsageIdentity) async throws -> AIHistoryRead {
                if id.provider == .cursor { return try await withCheckedThrowingContinuation { slow = $0 } }
                return AIHistoryRead(records: [.init(model: "fixture", date: .now, tokens: .init(input: 10), reportedCost: 2)], source: "fixture")
            }
            func release() { price?.resume(throwing: HistoryReadError.invalid); slow?.resume(throwing: HistoryReadError.invalid) }
            var ready: Bool { price != nil && slow != nil }
        }
        let gate = HistoryGate(), defaults = defaults()
        let monitor = AIUsageHistoryMonitor(defaults: defaults, readHistory: { id, _ in try await gate.read(id) }, fetchPrices: { try await gate.prices() })
        let ids = AICodingProvider.allCases.map { AIUsageIdentity($0) }
        monitor.start()
        monitor.refreshIfStale(ids)
        await until { await gate.ready && monitor.summaries.count == ids.count - 1 }
        XCTAssertEqual(monitor.summaries[AIUsageIdentity(.pi)]?.tokens.total, 10)
        XCTAssertEqual(monitor.summaries[AIUsageIdentity(.pi)]?.cost, 2)
        let restored = AIUsageHistoryMonitor(defaults: defaults, readHistory: { _, _ in throw HistoryReadError.invalid }, fetchPrices: { throw HistoryReadError.invalid })
        XCTAssertEqual(restored.summaries.count, ids.count - 1)
        await gate.release()
        await until { monitor.reading.isEmpty }
        XCTAssertNotNil(monitor.errors[AIUsageIdentity(.cursor)])
        monitor.stop(); restored.stop()
    }

    func testHistoryStalenessUsesEachLoginAndFailureKeepsOriginalAge() async {
        let defaults = defaults(), id = AIUsageIdentity(.muse)
        var now = Date(timeIntervalSince1970: 1000)
        actor Reader {
            var calls = 0
            func read() throws -> AIHistoryRead {
                calls += 1
                if calls > 1 { throw HistoryReadError.invalid }
                return AIHistoryRead(records: [], source: "fixture")
            }
        }
        let reader = Reader()
        let monitor = AIUsageHistoryMonitor(defaults: defaults, now: { now }, readHistory: { _, _ in try await reader.read() }, fetchPrices: { throw HistoryReadError.invalid })
        monitor.refreshIfStale([id])
        await until { monitor.reading.isEmpty }
        now.addTimeInterval(60)
        monitor.refreshIfStale([id])
        let firstCalls = await reader.calls
        XCTAssertEqual(firstCalls, 1)
        now.addTimeInterval(300)
        monitor.refreshIfStale()
        await until { monitor.reading.isEmpty }
        XCTAssertEqual(monitor.summaries[id]?.updatedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertNotNil(monitor.errors[id])
        monitor.stop()
    }

    func testRelaunchDoesNotRestoreQuotaWindowsAfterTheirReset() async {
        let defaults = defaults(), date = Date(timeIntervalSince1970: 1000), id = AIUsageIdentity(.codex)
        let first = AIUsageMonitor(defaults: defaults, now: { date }, userHome: home()) { id, now in
            AIUsageSnapshot(provider: id.provider, status: .ready, plan: nil,
                            windows: [.init(id: "test", title: "Weekly", usedPercent: 25, resetsAt: now.addingTimeInterval(60))],
                            fetchedAt: now, sourceLabel: "fixture")
        }
        first.connect(id)
        await until { !first.isRefreshing }
        first.stop()
        let restored = AIUsageMonitor(defaults: defaults, now: { date.addingTimeInterval(600) }, userHome: home()) { id, _ in .failed(id.provider, message: "offline") }
        XCTAssertTrue(restored.snapshot(for: id).windows.isEmpty)
        restored.connect(id)
        await until { !restored.isRefreshing }
        restored.disconnect(id)
        restored.connect(id)
        XCTAssertTrue(restored.snapshot(for: id).windows.isEmpty)
        await until { !restored.isRefreshing }
        restored.stop()
    }

    func testHistoryPricesArrivingLaterRepriceAlreadyVisibleTotals() async {
        actor PriceGate {
            var pending: CheckedContinuation<Data, Error>?
            func prices() async throws -> Data { try await withCheckedThrowingContinuation { pending = $0 } }
            func release() { pending?.resume(returning: Data(#"{"fixture":{"input_cost_per_token":0.1,"output_cost_per_token":0.2}}"#.utf8)) }
        }
        let gate = PriceGate(), id = AIUsageIdentity(.opencode)
        let monitor = AIUsageHistoryMonitor(defaults: defaults(), readHistory: { _, _ in
            AIHistoryRead(records: [.init(model: "fixture", date: .now, tokens: .init(input: 10))], source: "fixture")
        }, fetchPrices: { try await gate.prices() })
        monitor.refresh(id)
        await until { await gate.pending != nil && monitor.summaries[id] != nil }
        XCTAssertEqual(monitor.summaries[id]?.unpricedRecords, 1)
        await gate.release()
        await until { monitor.summaries[id]?.cost == 1 }
        XCTAssertEqual(monitor.summaries[id]?.tokens.total, 10)
        monitor.stop()
    }

    func testAgeTextUsesLastSuccessAndHandlesFutureClock() {
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(UsageAge.text(date, now: date.addingTimeInterval(180)), "Updated 3 min ago")
        XCTAssertEqual(UsageAge.text(date, now: date.addingTimeInterval(-30)), "Updated just now")
        XCTAssertEqual(UsageAge.text(nil, now: date), "No successful update yet")
    }
}
