import XCTest
@testable import Geraldine

final class AIUsageResetValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_806_400)
    private let utc = TimeZone(identifier: "UTC")!

    func testDurationRejectsOverflowAndNegativeValues() {
        for text in [String(repeating: "9", count: 400) + "h", String(repeating: "9", count: 308) + "d", "-3h"] {
            XCTAssertNil(AIUsageResetParser.duration(text))
            XCTAssertNil(AIUsageResetParser.parse(text, now: now))
        }
    }

    func testTimestampRejectsNonFiniteBooleansAndUnrepresentableValues() {
        for value: Any in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300, 1e18, -1e18,
                           "nan", "inf", "1e300", true, false] {
            XCTAssertNil(AIUsageJSON.date(value), "\(value)")
        }
    }

    func testTimestampRejectsNormalizedOrPartialISOInput() {
        for text in ["2026-02-30T03:00:00Z", "2026-02-29T03:00:00Z", "2026-10-13T25:00:00Z",
                     "2026-10-13T03:00:60Z", "2026-10-13T03:00:00Z trailing", "2026-10-13T03:00:00+25:00",
                     "\(Int.max)-10-13T03:00:00Z"] {
            XCTAssertNil(AIUsageJSON.date(text), text)
            XCTAssertNil(AIUsageResetParser.parse(text, now: now), text)
        }
    }

    func testKnownTimestampEncodingsKeepTheSameInstant() {
        let expected = Date(timeIntervalSince1970: 1_791_806_400)
        for value: Any in [1_791_806_400, "1791806400", 1_791_806_400_000, "1791806400000",
                           "2026-10-12T12:00:00Z", "2026-10-12T20:00:00+08:00"] {
            XCTAssertEqual(AIUsageJSON.date(value), expected)
        }
        XCTAssertEqual(AIUsageJSON.date("2026-10-12T12:00:00.125Z"), expected.addingTimeInterval(0.125))
    }

    func testPrintedDatesRejectUnknownMonthAndExplicitZone() {
        for text in ["Septober 24 at 3pm", "Januarish 5 at 3pm", "Oct 13 at 3pm (Not/AZone)",
                     "Feb 29, 2027 at 3pm", "Apr 31 at 3pm", "Oct 0 at 3pm",
                     "Oct 13, " + String(repeating: "9", count: 400) + " at 3pm", "Oct 13, 0000 at 3pm", "Oct 13, \(Int.max) at 3pm"] {
            XCTAssertNil(AIUsageResetParser.parse(text, now: now, timeZone: utc), text)
        }
        XCTAssertNotNil(AIUsageResetParser.parse("Sept. 24 at 3pm (Asia/Manila)", now: now))
        XCTAssertNotNil(AIUsageResetParser.parse("September 24 at 3pm (UTC)", now: now))
    }

    func testNonexistentLocalTimesAreNotNormalizedAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeSpring = try XCTUnwrap(AIUsageJSON.date("2026-03-07T22:00:00Z"))
        XCTAssertNil(AIUsageResetParser.parse("Mar 8, 2026 at 2:30am (America/New_York)", now: beforeSpring))
        XCTAssertNil(AIUsageResetParser.parse("2:30am", now: beforeSpring, timeZone: zone))
        XCTAssertNotNil(AIUsageResetParser.parse("Mar 8, 2026 at 3:30am (America/New_York)", now: beforeSpring))
        XCTAssertNotNil(AIUsageResetParser.parse("Nov 1, 2026 at 1:30am (America/New_York)", now: beforeSpring))
    }

    func testCountdownKeysHaveExplicitUnitsAndSupportNumericStrings() {
        for value: Any in [3600, "3600"] {
            XCTAssertEqual(AIUsageResetParser.reset(in: ["reset_after_seconds": value], now: now)?.date,
                           now.addingTimeInterval(3600))
            XCTAssertEqual(AIUsageResetParser.reset(in: ["reset_in": value], now: now)?.date,
                           now.addingTimeInterval(3600))
        }
        XCTAssertEqual(AIUsageResetParser.reset(in: ["reset_in": "Resets in 2h"], now: now)?.date,
                       now.addingTimeInterval(7200))
        for object: [String: Any] in [["reset_generation": 23], ["reset_origin": 5],
                                     ["reset_after_seconds": "Oct 13 at 3pm"], ["reset_after_seconds": true],
                                     ["reset_after_seconds": "1e300"], ["reset_after_seconds": -3600],
                                     ["reset_at": "in 2h"], ["reset_time": "2 hours"]] {
            XCTAssertNil(AIUsageResetParser.reset(in: object, now: now))
        }
    }

    func testCodexRejectsBadCountdownButKeepsValidPrecedence() throws {
        func parse(_ fields: String) throws -> AIUsageWindow? {
            let data = Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":29,\(fields)}}}".utf8)
            return try AIUsageParser.codex(from: data, now: now).get().windows.first
        }
        for value in ["\"inf\"", "\"1e300\"", "true", "-3600"] {
            XCTAssertNil(try parse("\"reset_after_seconds\":\(value)")?.resetsAt)
        }
        XCTAssertEqual(try parse("\"reset_after_seconds\":\"3600\"")?.resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(try parse("\"reset_at\":1791806400,\"reset_after_seconds\":3600")?.resetsAt, now)
    }

    func testAllJSONProviderResetPathsRejectMalformedDates() throws {
        func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        func check(_ result: Result<AIUsageSnapshot, AIUsageParseError>, file: StaticString = #filePath, line: UInt = #line) throws {
            let snapshot = try result.get()
            XCTAssertFalse(snapshot.windows.isEmpty, file: file, line: line)
            XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt == nil }, file: file, line: line)
        }
        for bad: Any in [true, "1e300", "nan", "2026-02-30T03:00:00Z"] {
            try check(AIUsageParser.claude(from: data(["seven_day": ["utilization": 28, "resets_at": bad]]), now: now))
            for key in ["reset_at", "resets_at"] {
                try check(AIUsageParser.codex(from: data(["rate_limit": ["primary_window": ["used_percent": 28, key: bad]]]), now: now))
            }
            try check(CodexCLIUsage.parse(data(["id": 2, "result": ["rateLimits": ["primary": ["usedPercent": 28, "resetsAt": bad]]]]), now: now))
            try check(AIUsageParser.grok(from: data(["config": ["creditUsagePercent": 28, "currentPeriod": ["end": bad]]]), now: now))
            try check(AIUsageParser.grok(from: data(["config": ["creditUsagePercent": 28, "billingPeriodEnd": bad]]), now: now))
            for key in ["resetDate", "billingCycleEnd", "nextReset"] {
                try check(AIUsageParser.cursor(from: data(["autoPercentUsed": 28, key: bad]), now: now))
            }
            try check(AIUsageParser.cursor(from: data(["modelUsage": ["model": ["numRequests": 28, "maxRequestUsage": 100, "resetDate": bad]]]), now: now))
            try check(AIUsageParser.antigravity(from: data(["availablePromptCredits": 72, "monthlyPromptCredits": 100, "resetTime": bad]), now: now))
            for key in ["resetTime", "reset_time"] {
                try check(AIUsageParser.antigravity(from: data(["models": ["model": ["remainingFraction": 0.72, key: bad]]]), now: now))
            }
            try check(AIUsageParser.antigravity(from: data(["quotas": [["remainingFraction": 0.72, "resetTime": bad]]]), now: now))
            for key in ["reset_time", "reset_in", "reset_after_seconds"] {
                let ids = ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"]
                let buckets = ids.map { ["id": $0, "remaining_fraction": 0.72, key: bad] as [String: Any] }
                try check(AntigravityCLIUsage.parse(data(["status": "SUCCESS", "num_turns": 0,
                                                         "command": ["name": "usage", "data": ["groups": [["buckets": buckets]]]]]), now: now))
            }
        }
    }

    func testAbsoluteFallbackKeysKeepPrintedCalendarDatesWithoutAcceptingDurations() {
        for key in ["reset_at", "resets_at", "reset_date", "reset_time", "resetDate"] {
            let day = AIUsageResetParser.reset(in: [key: "Resets Oct 13 (UTC)"], now: now)
            XCTAssertEqual(day?.date, now.addingTimeInterval(12 * 3600), key)
            XCTAssertEqual(day?.dateOnly, true, key)
            let timed = AIUsageResetParser.reset(in: [key: "Oct 13 at 3pm (UTC)"], now: now)
            XCTAssertEqual(timed?.date, now.addingTimeInterval(27 * 3600), key)
            XCTAssertEqual(timed?.dateOnly, false, key)
            XCTAssertNil(AIUsageResetParser.reset(in: [key: "Resets in 2h"], now: now), key)
            XCTAssertNil(AIUsageResetParser.reset(in: [key: "Feb 30 at 3pm"], now: now), key)
        }
    }

    func testInvalidPrimaryResetFallsThroughWithoutChangingValidPrecedence() throws {
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":29,"reset_at":true,"resets_at":1791806400,"reset_after_seconds":"3600"}}}"#
        XCTAssertEqual(try AIUsageParser.codex(from: Data(payload.utf8), now: now).get().windows.first?.resetsAt, now)
        XCTAssertNil(AIUsageResetParser.parse("in 1h", now: Date(timeIntervalSince1970: .infinity)))
        XCTAssertNil(AIUsageResetParser.countdown(1e300, now: now))
        XCTAssertNil(AIUsageResetParser.countdown(3600, now: Date(timeIntervalSince1970: .nan)))
    }

    // Run after the parser red tests: the old formatter traps on these values.
    func testFormatterHidesUnsafeDatesAndHandlesLargeRepresentableDates() throws {
        for seconds in [Double.infinity, -Double.infinity, Double.nan, 1e300, -1e300, 1e18, -1e18] {
            let date = Date(timeIntervalSince1970: seconds)
            XCTAssertNil(AIUsageResetText.short(date, now: now))
            XCTAssertNil(AIUsageResetText.caption(.init(id: "pool", title: "Pool", usedPercent: 12, resetsAt: date), now: now))
            XCTAssertNil(AIUsageResetText.detail(.init(id: "pool", title: "Pool", usedPercent: 12, resetsAt: date), now: now))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let future = try XCTUnwrap(calendar.date(from: DateComponents(year: 12000, month: 1, day: 2)))
        XCTAssertNotNil(AIUsageResetText.short(future, now: now, calendar: calendar), "No arbitrary date ceiling")
        XCTAssertEqual(AIUsageResetParser.parse("Jan 2, 12000", now: now, timeZone: utc)?.date, future)
        XCTAssertNil(AIUsageResetText.short(now, now: Date(timeIntervalSince1970: .nan)))
    }
}
