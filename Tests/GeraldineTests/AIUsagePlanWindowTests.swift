import XCTest
@testable import Geraldine

final class AIUsagePlanWindowTests: XCTestCase {
    private func codex(plan: String, primaryDuration: Int? = 18_000,
                       includeWeekly: Bool = true) throws -> AIUsageSnapshot {
        var primary: [String: Any] = ["used_percent": 35]
        if let primaryDuration { primary["limit_window_seconds"] = primaryDuration }
        var rate: [String: Any] = ["primary_window": primary]
        if includeWeekly {
            rate["secondary_window"] = ["used_percent": 20, "limit_window_seconds": 604_800]
        }
        let data = try JSONSerialization.data(withJSONObject: ["plan_type": plan, "rate_limit": rate])
        return try AIUsageParser.codex(from: data).get()
    }

    func testClaudeFiveHourCanBeTheLimitingWindowAndIsNeverTruncated() throws {
        let data = Data(#"""
        {"five_hour":{"utilization":85},"seven_day":{"utilization":20},
         "seven_day_fable":{"utilization":30}}
        """#.utf8)
        let snapshot = try AIUsageParser.claude(from: data).get()
        XCTAssertEqual(snapshot.displayWindows.map(\.id), ["seven_day", "seven_day_fable", "five_hour"])
        XCTAssertEqual(snapshot.displayWindows.map(\.remainingPercent), [80, 70, 15])
        XCTAssertEqual(snapshot.headline?.id, "five_hour")
    }

    func testClaudeUsesOnlyWindowsActuallyReturned() throws {
        for json in [#"{"five_hour":{"utilization":20}}"#, #"{"seven_day":{"utilization":20}}"#] {
            let snapshot = try AIUsageParser.claude(from: Data(json.utf8)).get()
            XCTAssertEqual(snapshot.displayWindows.count, 1)
        }
    }

    func testPlusShowsActualFiveHourAndWeeklyWindows() throws {
        let snapshot = try codex(plan: "plus")
        XCTAssertEqual(snapshot.displayWindows.map(\.title), ["Weekly", "5-hour"])
        XCTAssertEqual(snapshot.displayWindows.map(\.remainingPercent), [80, 65])
        XCTAssertEqual(snapshot.displayWindows.map(\.durationSeconds), [604_800, 18_000])
    }

    func testCurrentProWeeklyOnlyResponseStaysOneWeeklyWindow() throws {
        let snapshot = try codex(plan: "pro", primaryDuration: 604_800, includeWeekly: false)
        XCTAssertEqual(snapshot.displayWindows.count, 1)
        XCTAssertEqual(snapshot.headline?.title, "Weekly")
    }

    func testSwitchingPlanRecomputesPresentationWithoutRememberingPlusWindows() throws {
        XCTAssertEqual(try codex(plan: "plus").displayWindows.count, 2)
        for plan in ["pro", "team", "business", "enterprise", ""] {
            XCTAssertEqual(try codex(plan: plan).displayWindows.count, 1)
        }
        XCTAssertEqual(try codex(plan: " Plus ").displayWindows.count, 2)
    }

    func testPlusDoesNotInventMissingWindowsOrFiveHourDuration() throws {
        XCTAssertEqual(try codex(plan: "plus", includeWeekly: false).displayWindows.map(\.title), ["5-hour"])
        XCTAssertEqual(try codex(plan: "plus", primaryDuration: nil).displayWindows.count, 1)
        XCTAssertEqual(try codex(plan: "plus", primaryDuration: 604_800, includeWeekly: false).displayWindows.map(\.title), ["Weekly"])
    }
}
