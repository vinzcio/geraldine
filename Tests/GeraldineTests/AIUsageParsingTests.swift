import XCTest
@testable import Geraldine

final class AIUsageParsingTests: XCTestCase {
    func testClaudeWindowsUseRemainingPercentAndTightestHeadline() throws {
        let data = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-09-15T12:00:00Z" },
          "seven_day": { "utilization": 71.0, "resets_at": "2026-09-20T08:00:00Z" },
          "seven_day_opus": null
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.claude(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.first { $0.id == "five_hour" }?.remainingPercent, 65)
        XCTAssertEqual(snapshot.windows.first { $0.id == "seven_day" }?.remainingPercent, 29)
        XCTAssertEqual(snapshot.windows.first { $0.id == "seven_day" }?.title, "All models")
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day", "five_hour"])
        XCTAssertEqual(snapshot.headline?.id, "seven_day")
        XCTAssertEqual(snapshot.remainingPercent, 29)
    }

    func testClaudeMaxParsesFableFromWeeklyScopedLimitPercent() throws {
        let data = """
        {
          "seven_day": { "utilization": 2.0, "resets_at": "2026-09-22T07:00:00Z" },
          "limits": [
            { "kind": "weekly_all", "percent": 2 },
            {
              "kind": "weekly_scoped",
              "percent": 0,
              "resets_at": "2026-09-22T07:00:00Z",
              "scope": { "model": { "id": null, "display_name": "Fable" } }
            }
          ]
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.claude(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["All models", "Fable"])
        XCTAssertEqual(snapshot.displayWindows.first { $0.title == "Fable" }?.remainingPercent, 100)
        XCTAssertEqual(snapshot.displayWindows.first { $0.id == "seven_day" }?.remainingPercent, 98)
    }

    func testClaudeMaxShowsFableAndAllModelsBars() throws {
        let data = """
        {
          "subscription_type": "max",
          "rate_limit_tier": "default_claude_max_5x",
          "seven_day": { "utilization": 12.0, "resets_at": "2026-09-22T00:00:00Z" },
          "seven_day_overage_included": { "utilization": 40.0, "resets_at": "2026-09-22T00:00:00Z" },
          "five_hour": { "utilization": 5.0 }
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.claude(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day", "seven_day_overage_included", "five_hour"])
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["All models", "Fable", "5-hour"])
        XCTAssertEqual(snapshot.displayWindows.first?.remainingPercent, 88)
        XCTAssertEqual(snapshot.displayWindows.last?.remainingPercent, 95)
    }

    func testCodexAndGrokDrawASinglePooledBar() throws {
        let codex = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 29 },
            "secondary_window": { "used_percent": 12 }
          }
        }
        """.data(using: .utf8)!
        let snapshot = try unwrap(AIUsageParser.codex(from: codex, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.displayWindows.count, 1)
        XCTAssertEqual(snapshot.displayWindows.first?.title, "Session")
    }

    func testCodexPrimaryAndWeeklyWindows() throws {
        let data = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 29, "reset_at": 1780000000 },
            "secondary_window": { "used_percent": 12, "reset_after_seconds": 3600 }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.codex(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.headline?.remainingPercent, 71)
        XCTAssertEqual(snapshot.headline?.title, "Session")
    }

    func testGrokWeeklyPoolAndProductRows() throws {
        let billing = """
        {
          "config": {
            "creditUsagePercent": 33,
            "currentPeriod": { "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-09-20T00:00:00Z" },
            "productUsage": [
              { "product": "build", "usagePercent": 41 }
            ]
          }
        }
        """.data(using: .utf8)!
        let user = """
        { "subscriptionTier": "SuperGrok" }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.grok(from: billing, user: user, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.plan, "SuperGrok")
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 67)
        XCTAssertEqual(snapshot.windows.first?.title, "Weekly")
        XCTAssertEqual(snapshot.windows.last?.title, "Build")
        XCTAssertEqual(snapshot.windows.last?.remainingPercent, 59)
        XCTAssertEqual(snapshot.displayWindows.count, 1)
        XCTAssertEqual(snapshot.displayWindows.first?.id, "pool")
        XCTAssertEqual(snapshot.displayWindows.first?.remainingPercent, 67)
    }

    func testCursorIncludedSpendRemaining() throws {
        let data = """
        {
          "membershipType": "pro",
          "planUsage": { "totalSpend": 25, "limit": 100, "resetDate": "2026-10-01T00:00:00Z" }
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.cursor(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.remainingPercent, 75)
        XCTAssertEqual(snapshot.headline?.title, "Included")
    }

    func testCursorPercentUsedWindowsIgnoreBonusSpendOverflow() throws {
        let data = """
        {
          "billingCycleEnd": "1791280410000",
          "planUsage": {
            "totalSpend": 110450,
            "includedSpend": 40000,
            "bonusSpend": 70450,
            "limit": 40000,
            "autoPercentUsed": 24.301666666666666,
            "apiPercentUsed": 100,
            "totalPercentUsed": 32.72592592592593
          }
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.cursor(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["autoPercentUsed", "apiPercentUsed"])
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["Cursor models", "Other models"])
        let api = try XCTUnwrap(snapshot.windows.first { $0.id == "apiPercentUsed" }?.remainingPercent)
        let auto = try XCTUnwrap(snapshot.windows.first { $0.id == "autoPercentUsed" }?.remainingPercent)
        XCTAssertEqual(api, 0)
        XCTAssertEqual(auto, 75.7, accuracy: 0.01)
        XCTAssertEqual(snapshot.headline?.id, "apiPercentUsed")
    }

    func testAntigravityModelQuotaUsesRemainingFraction() throws {
        let data = """
        {
          "currentTier": { "name": "Free" },
          "models": {
            "claude-sonnet": {
              "displayName": "Claude Sonnet",
              "quotaInfo": { "remainingFraction": 0.71, "resetTime": "2026-09-16T00:00:00Z" }
            },
            "gemini-flash": {
              "displayName": "Gemini Flash",
              "quotaInfo": { "remainingFraction": 0.40 }
            }
          }
        }
        """.data(using: .utf8)!

        let snapshot = try unwrap(AIUsageParser.antigravity(from: data, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertEqual(snapshot.remainingPercent, 40)
        XCTAssertEqual(snapshot.headline?.title, "Gemini Flash")
        XCTAssertEqual(snapshot.windows.first { $0.title == "Claude Sonnet" }?.remainingPercent, 71)
    }

    func testPercentFractionAndAlreadyPercent() {
        XCTAssertEqual(AIUsageMath.percent(from: 0.29), 29)
        XCTAssertEqual(AIUsageMath.percent(from: 71), 71)
        XCTAssertEqual(AIUsageMath.clampPercent(140), 100)
        XCTAssertEqual(AIUsageMath.clampPercent(-4), 0)
    }

    func testDisclosureNamesEveryProviderAndLocalOnlyPromise() {
        let text = AIUsageDisclosure.current.text
        for name in AIUsageDisclosure.current.destinations {
            XCTAssertTrue(text.contains(name), "missing \(name)")
        }
        XCTAssertTrue(text.contains("local sign-in"))
        XCTAssertTrue(text.contains("No separate Geraldine sign-in or Keychain access"))
    }

    func testWidgetKindRoundTripForEveryProvider() {
        for provider in AICodingProvider.allCases {
            let kind = WidgetKind.aiUsage(provider)
            XCTAssertEqual(kind.id, "ai.\(provider.rawValue)")
            XCTAssertEqual(WidgetKind(id: kind.id), kind)
            XCTAssertEqual(kind.title, provider.title)
            XCTAssertTrue(kind.canResize)
            XCTAssertNil(kind.metric)
        }
    }

    private func unwrap(_ result: Result<AIUsageSnapshot, AIUsageParseError>) throws -> AIUsageSnapshot {
        switch result {
        case .success(let snapshot): return snapshot
        case .failure(let error):
            XCTFail(error.message)
            throw NSError(domain: "AIUsageParsingTests", code: 1)
        }
    }
}

@MainActor
final class AIUsageLayoutTests: XCTestCase {
    func testExistingLayoutGainsHiddenAIUsageTiles() throws {
        let suiteName = "AIUsageLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = [WidgetItem(.cpu, .small), WidgetItem(.memory, .medium)]
        defaults.set(try JSONEncoder().encode(existing), forKey: "geraldine.widgetLayout.v3")

        let layout = WidgetLayoutStore(defaults: defaults)
        XCTAssertEqual(Array(layout.items.prefix(2)), existing)
        for provider in AICodingProvider.allCases {
            let item = layout.items.first { $0.kind == .aiUsage(provider) }
            XCTAssertNotNil(item)
            XCTAssertEqual(item?.isShown, false)
            XCTAssertEqual(item?.size, .small)
        }
        XCTAssertEqual(layout.menuBarKind(hasBattery: false), .cpu)
    }

    func testConnectShowsTileAndDisconnectHidesIt() throws {
        let suiteName = "AIUsageConnectLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let layout = WidgetLayoutStore(defaults: defaults)
        XCTAssertFalse(layout.visibleItems(hasBattery: false, calendarInPopover: false)
            .contains { $0.kind == .aiUsage(.codex) })
        layout.setShown(.aiUsage(.codex), true)
        XCTAssertTrue(layout.visibleItems(hasBattery: false, calendarInPopover: false)
            .contains { $0.kind == .aiUsage(.codex) })
        layout.setShown(.aiUsage(.codex), false)
        XCTAssertFalse(layout.visibleItems(hasBattery: false, calendarInPopover: false)
            .contains { $0.kind == .aiUsage(.codex) })
    }
}

@MainActor
final class AIUsageMonitorTests: XCTestCase {
    func testConnectPersistsAndDisconnectClears() throws {
        let suiteName = "AIUsageMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = ScriptedAIUsageTransport(status: 200, body: Data("{}".utf8))
        let monitor = AIUsageMonitor(defaults: defaults, transport: transport)
        XCTAssertEqual(monitor.snapshot(for: .codex).status, .disconnected)
        monitor.connect(.codex)
        XCTAssertTrue(monitor.isConnected(.codex))
        XCTAssertEqual(defaults.stringArray(forKey: AIUsageMonitor.connectedKey), ["codex"])
        monitor.disconnect(.codex)
        XCTAssertEqual(monitor.snapshot(for: .codex).status, .disconnected)
        XCTAssertEqual(defaults.stringArray(forKey: AIUsageMonitor.connectedKey), [])
    }

    func testSyncShownProvidersConnectsVisibleTilesAndLeavesOthersAlone() throws {
        let suiteName = "AIUsageMonitorShownSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transport = ScriptedAIUsageTransport(status: 200, body: Data("{}".utf8))
        let monitor = AIUsageMonitor(defaults: defaults, transport: transport)
        monitor.syncShownProviders([.codex, .cursor])
        XCTAssertTrue(monitor.isConnected(.codex))
        XCTAssertTrue(monitor.isConnected(.cursor))
        XCTAssertFalse(monitor.isConnected(.grok))
        XCTAssertEqual(Set(defaults.stringArray(forKey: AIUsageMonitor.connectedKey) ?? []),
                       Set(["codex", "cursor"]))

        monitor.syncShownProviders([.codex, .cursor])
        XCTAssertEqual(monitor.snapshot(for: .codex).status, .loading)

        monitor.syncShownProviders([.codex])
        XCTAssertTrue(monitor.isConnected(.codex))
        XCTAssertEqual(monitor.snapshot(for: .cursor).status, .disconnected)
        XCTAssertEqual(defaults.stringArray(forKey: AIUsageMonitor.connectedKey), ["codex"])
    }

    func testPopoverOpensShareOneRefreshAndDoNotRefetchInsideTheCadence() async throws {
        let suiteName = "AIUsageMonitorSharedRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 5_000))
        let log = FetchLog()
        let monitor = AIUsageMonitor(defaults: defaults, transport: ScriptedAIUsageTransport(status: 200, body: Data()), now: clock.now) { provider, date in
            log.record(provider, at: date)
            return usageFixture(provider, at: date, remaining: 40)
        }

        monitor.syncShownProviders([.claude, .antigravity])
        await waitUntil { monitor.lastRefresh != nil && !monitor.isRefreshing }
        XCTAssertEqual(Set(log.providers), [.claude, .antigravity])
        XCTAssertEqual(log.providers.count, 2)
        XCTAssertEqual(monitor.snapshot(for: .claude).status, .ready)
        XCTAssertEqual(monitor.snapshot(for: .antigravity).status, .ready)
        let firstRefresh = try XCTUnwrap(monitor.lastRefresh)

        log.reset()
        monitor.refreshIfStale()
        monitor.refreshIfStale()
        clock.advance(30)
        monitor.refreshIfStale()
        await waitUntil { !monitor.isRefreshing }
        XCTAssertTrue(log.providers.isEmpty, "Opening the popover again inside the shared cadence must not start another fetch")
        XCTAssertEqual(monitor.lastRefresh, firstRefresh)

        clock.advance(AIUsageMonitor.refreshInterval)
        monitor.refreshIfStale()
        await waitUntil { monitor.lastRefresh != firstRefresh && !monitor.isRefreshing }
        XCTAssertEqual(Set(log.providers), [.claude, .antigravity])
        XCTAssertEqual(log.providers.count, 2)
    }

    func testInFlightSharedRefreshCoalescesPerProviderAndPopoverOpens() async throws {
        let suiteName = "AIUsageMonitorCoalesce.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 8_000))
        let log = FetchLog()
        let gate = FetchGate()
        let monitor = AIUsageMonitor(defaults: defaults, transport: ScriptedAIUsageTransport(status: 200, body: Data()), now: clock.now) { provider, date in
            log.record(provider, at: date)
            await gate.wait(for: provider)
            return usageFixture(provider, at: date, remaining: provider == .antigravity ? 70 : 90)
        }

        monitor.syncShownProviders([.claude, .antigravity])
        await waitUntil { log.providers.count == 2 }

        monitor.refreshIfStale()
        monitor.refreshConnected()
        monitor.connect(.claude)
        XCTAssertEqual(log.providers.count, 2, "In-flight providers must not start a second fetch")

        gate.releaseAll()
        await waitUntil { !monitor.isRefreshing && monitor.snapshot(for: .antigravity).status == .ready }
        XCTAssertEqual(Set(log.providers), [.claude, .antigravity])
        XCTAssertEqual(monitor.snapshot(for: .claude).remainingPercent, 90)
        XCTAssertEqual(monitor.snapshot(for: .antigravity).remainingPercent, 70)
        XCTAssertNotNil(monitor.lastRefresh)
    }

    func testReadyTilesStayReadableDuringSharedRefresh() async throws {
        let suiteName = "AIUsageMonitorSilentRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 9_000))
        let log = FetchLog()
        let gate = FetchGate()
        let monitor = AIUsageMonitor(defaults: defaults, transport: ScriptedAIUsageTransport(status: 200, body: Data()), now: clock.now) { provider, date in
            log.record(provider, at: date)
            await gate.wait(for: provider)
            return usageFixture(provider, at: date, remaining: 55)
        }

        monitor.connect(.antigravity)
        await waitUntil { log.providers.count == 1 }
        gate.releaseAll()
        await waitUntil { monitor.snapshot(for: .antigravity).status == .ready }
        XCTAssertTrue(monitor.snapshot(for: .antigravity).hasDisplayableUsage)

        clock.advance(AIUsageMonitor.refreshInterval)
        gate.reset()
        monitor.refreshIfStale()
        await waitUntil { log.providers.count == 2 }
        XCTAssertEqual(monitor.snapshot(for: .antigravity).status, .ready)
        XCTAssertEqual(monitor.snapshot(for: .antigravity).remainingPercent, 55)
        XCTAssertTrue(monitor.snapshot(for: .antigravity).hasDisplayableUsage)
        gate.releaseAll()
        await waitUntil { !monitor.isRefreshing }
    }

    func testShowingANewTileJoinsTheSharedPathWithoutRefreshingOthers() async throws {
        let suiteName = "AIUsageMonitorNewTile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 10_000))
        let log = FetchLog()
        let monitor = AIUsageMonitor(defaults: defaults, transport: ScriptedAIUsageTransport(status: 200, body: Data()), now: clock.now) { provider, date in
            log.record(provider, at: date)
            return usageFixture(provider, at: date, remaining: 33)
        }

        monitor.connect(.claude)
        await waitUntil { monitor.snapshot(for: .claude).status == .ready }
        log.reset()

        monitor.syncShownProviders([.claude, .codex])
        await waitUntil { monitor.snapshot(for: .codex).status == .ready }
        XCTAssertEqual(log.providers, [.codex])
        XCTAssertEqual(monitor.snapshot(for: .claude).status, .ready)
        monitor.refreshIfStale()
        await waitUntil { !monitor.isRefreshing }
        XCTAssertEqual(log.providers, [.codex], "A fresh shared clock must not refetch already-current tiles")
    }

    private func waitUntil(_ timeout: TimeInterval = 1, predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for usage monitor state")
    }
}

private func usageFixture(_ provider: AICodingProvider, at date: Date, remaining: Double) -> AIUsageSnapshot {
    AIUsageSnapshot(
        provider: provider,
        status: .ready,
        plan: nil,
        windows: [AIUsageWindow(id: "pool", title: "Weekly", usedPercent: 100 - remaining, resetsAt: nil)],
        fetchedAt: date,
        sourceLabel: "test"
    )
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    var now: () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AICodingProvider] = []

    var providers: [AICodingProvider] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ provider: AICodingProvider, at date: Date) {
        _ = date
        lock.lock()
        recorded.append(provider)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }
}

private final class FetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AICodingProvider: [CheckedContinuation<Void, Never>]] = [:]
    private var closed = false

    func wait(for provider: AICodingProvider) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations[provider, default: []].append(continuation)
            lock.unlock()
        }
    }

    func releaseAll() {
        lock.lock()
        closed = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        for group in waiting.values {
            for continuation in group {
                continuation.resume()
            }
        }
    }

    func reset() {
        lock.lock()
        closed = false
        continuations.removeAll()
        lock.unlock()
    }
}

struct ScriptedAIUsageTransport: AIUsageTransporting {
    let status: Int
    let body: Data

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}
