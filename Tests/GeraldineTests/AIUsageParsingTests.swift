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
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day"])
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
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["Fable", "All models"])
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
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day_overage_included", "seven_day"])
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["Fable", "All models"])
        XCTAssertEqual(snapshot.displayWindows.first?.remainingPercent, 60)
        XCTAssertEqual(snapshot.displayWindows.last?.remainingPercent, 88)
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
        XCTAssertTrue(text.contains("never sent to Geraldine"))
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
