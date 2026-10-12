import XCTest
@testable import Geraldine

/// Reset times each agent CLI prints beside its meters, carried onto the windows
/// the tiles draw. Fixtures are the CLIs' own wording.
final class AIUsageResetTests: XCTestCase {
    private static let manila = TimeZone(identifier: "Asia/Manila")!
    private static let utc = TimeZone(identifier: "UTC")!

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
                             _ second: Int = 0, in zone: TimeZone = utc) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))!
    }

    private static var englishUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    // MARK: - Claude

    func testClaudeResultTextCarriesEachWindowsResetInItsPrintedZone() throws {
        let text = """
        Current session: 9% used · resets Sep 16 at 9pm (Asia/Manila)
        Current week (all models): 12% used · resets Sep 22 at 3pm (Asia/Manila)
        Current week (Fable): 8% used · resets Sep 22 at 3:30pm (Asia/Manila)
        """
        let now = Self.date(2026, 9, 15, 12)
        let snapshot = try ClaudeCLIUsage.parseResultText(text, now: now).get()
        func reset(_ id: String) -> Date? { snapshot.windows.first { $0.id == id }?.resetsAt }
        XCTAssertEqual(reset("five_hour"), Self.date(2026, 9, 16, 21, in: Self.manila))
        XCTAssertEqual(reset("seven_day"), Self.date(2026, 9, 22, 15, in: Self.manila))
        XCTAssertEqual(reset("seven_day_fable"), Self.date(2026, 9, 22, 15, 30, in: Self.manila))
        XCTAssertFalse(snapshot.windows.contains { $0.resetIsDateOnly })
    }

    func testClaudeWithoutResetTextStillParsesAndHidesTheReset() throws {
        let snapshot = try ClaudeCLIUsage.parseResultText("Current session: 40% used", now: Date()).get()
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 40)
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertNil(snapshot.windows.first.flatMap { AIUsageResetText.caption($0) })
    }

    func testClaudeWeeklyLimitPhraseAndTimeOnlySessionReset() {
        let now = Self.date(2026, 10, 12, 4) // Oct 12, noon in Manila
        let phrase = AIUsageResetParser.phrase(in: "weekly limit resets Oct 13 at 3pm (Asia/Manila)")
        XCTAssertEqual(phrase, "Oct 13 at 3pm (Asia/Manila)")
        XCTAssertEqual(AIUsageResetParser.parse(phrase ?? "", now: now),
                       .init(date: Self.date(2026, 10, 13, 15, in: Self.manila), dateOnly: false))
        // Time only: later today, or tomorrow once that hour has passed.
        XCTAssertEqual(AIUsageResetParser.parse("9pm (Asia/Manila)", now: now)?.date,
                       Self.date(2026, 10, 12, 21, in: Self.manila))
        XCTAssertEqual(AIUsageResetParser.parse("resets 9am (Asia/Manila)", now: now)?.date,
                       Self.date(2026, 10, 13, 9, in: Self.manila))
    }

    func testMissingYearRollsForwardAndExplicitYearIsKept() {
        let now = Self.date(2026, 12, 30, 12)
        XCTAssertEqual(AIUsageResetParser.parse("Jan 3 at 3pm", now: now, timeZone: Self.utc)?.date,
                       Self.date(2027, 1, 3, 15))
        XCTAssertEqual(AIUsageResetParser.parse("Jan 3, 2026 at 3pm", now: now, timeZone: Self.utc)?.date,
                       Self.date(2026, 1, 3, 15))
        // A passed reset is stale data, not next year's.
        XCTAssertEqual(AIUsageResetParser.parse("Dec 30 at 1am", now: now, timeZone: Self.utc)?.date,
                       Self.date(2026, 12, 30, 1))
    }

    // MARK: - Grok and Cursor

    func testGrokModalResetIsReadInLocalTime() throws {
        let modal = """
        │  Weekly limit (X Premium+)                                                 │
        │  ███████░░░░░░░░░░░░░░░░░░░░░░░  22%                                       │
        │  Resets: September 24, 01:27                                               │
        """
        let now = Self.date(2026, 9, 20)
        let snapshot = try GrokCLIUsage.parse(Data(modal.utf8), now: now).get()
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .autoupdatingCurrent
        let expected = local.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 1, minute: 27))
        XCTAssertEqual(snapshot.windows.first?.resetsAt, expected)
        XCTAssertEqual(snapshot.windows.first?.resetIsDateOnly, false)
        XCTAssertEqual(snapshot.sharedReset?.id, "pool")
        // Same line as the bar, as older builds draw it. Already past: stays
        // in the past so the tile hides it rather than jumping a year.
        let passed = AIUsageResetParser.parse("100%Resets: September 17, 01:27".components(separatedBy: "%")[1],
                                              now: now, timeZone: Self.utc)
        XCTAssertEqual(passed?.date, Self.date(2026, 9, 17, 1, 27))
        XCTAssertNil(passed.flatMap { AIUsageResetText.short($0.date, now: now) })
    }

    func testCursorDateOnlyResetCoversEveryMeterWithoutAnInventedHour() throws {
        let pager = """
        Usage • Ultra                                                                                           Resets Oct 6
        Monthly plan and on-demand usage

        Category        Current             Usage
        Included        71% used            █████████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░
          Auto          67% used            ██████████████████████████████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░
          API           100% used           ████████████████████████████████████████████████████████████████████████████████
        """
        let now = Self.date(2026, 9, 20)
        let snapshot = try CursorCLIUsage.parse(Data(pager.utf8), now: now).get()
        XCTAssertEqual(Set(snapshot.windows.compactMap(\.resetsAt)).count, 1)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetIsDateOnly && $0.resetsAt != nil })
        XCTAssertNotNil(snapshot.sharedReset, "Both drawn pools share the billing-cycle reset")
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .autoupdatingCurrent
        XCTAssertEqual(snapshot.windows.first?.resetsAt,
                       local.date(from: DateComponents(year: 2026, month: 10, day: 6)))
    }

    // MARK: - Antigravity and Codex

    func testAntigravityPrefersISOResetAndFallsBackToPrintedCountdown() throws {
        let payload = """
        {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[
          {"buckets":[
            {"id":"gemini-weekly","remaining_fraction":1,"reset_time":"2026-09-23T05:12:15Z"},
            {"id":"gemini-5h","remaining_fraction":0.75,"reset_in":"Resets in 106h4m42s"}]},
          {"buckets":[
            {"id":"3p-weekly","remaining_fraction":0.5,"reset_after_seconds":3600},
            {"id":"3p-5h","remaining_fraction":0.01}]}
        ]}}}
        """
        let now = Self.date(2026, 9, 18)
        let snapshot = try AntigravityCLIUsage.parse(Data(payload.utf8), now: now).get()
        func reset(_ id: String) -> Date? { snapshot.windows.first { $0.id == id }?.resetsAt }
        XCTAssertEqual(reset("gemini-weekly"), Self.date(2026, 9, 23, 5, 12, 15))
        XCTAssertEqual(reset("gemini-5h"), now.addingTimeInterval(106 * 3600 + 4 * 60 + 42))
        XCTAssertEqual(reset("3p-weekly"), now.addingTimeInterval(3600))
        XCTAssertNil(reset("3p-5h"))
        XCTAssertNil(snapshot.sharedReset, "Missing and differing resets are not shared")
    }

    func testCodexCountdownIsAnchoredToTheReadTime() throws {
        let body = #"{"rate_limit":{"primary_window":{"used_percent":29,"reset_after_seconds":3600}}}"#
        let now = Self.date(2026, 9, 18)
        let snapshot = try AIUsageParser.codex(from: Data(body.utf8), now: now).get()
        XCTAssertEqual(snapshot.windows.first?.resetsAt, now.addingTimeInterval(3600))
    }

    // MARK: - Parser edges

    func testDurationsMustBeWholePhrases() {
        XCTAssertEqual(AIUsageResetParser.duration("in 106h4m42s"), 106 * 3600 + 4 * 60 + 42)
        XCTAssertEqual(AIUsageResetParser.duration("4d 10h"), 4 * 86_400 + 10 * 3600)
        XCTAssertEqual(AIUsageResetParser.duration("in 2 hours and 5 minutes"), 2 * 3600 + 5 * 60)
        XCTAssertEqual(AIUsageResetParser.duration("45 mins"), 45 * 60)
        XCTAssertNil(AIUsageResetParser.duration("Sep 16 at 9pm"))
        XCTAssertNil(AIUsageResetParser.duration("10 months"))
        XCTAssertNil(AIUsageResetParser.duration("0m"))
        XCTAssertNil(AIUsageResetParser.duration(""))
    }

    func testUnreadableResetTextIsHiddenNotGuessed() {
        let now = Self.date(2026, 9, 18)
        for text in ["", "soon", "Feb 30 at 3pm", "Oct 13 at 13pm", "Smarch 4", "25:00", "Mon 3pm"] {
            XCTAssertNil(AIUsageResetParser.parse(text, now: now, timeZone: Self.utc), text)
        }
    }

    func testISOAndTwentyFourHourText() {
        let now = Self.date(2026, 9, 18)
        XCTAssertEqual(AIUsageResetParser.parse("2026-09-23T05:12:15Z", now: now)?.date,
                       Self.date(2026, 9, 23, 5, 12, 15))
        XCTAssertEqual(AIUsageResetParser.parse("Resets: Sept 24, 13:05", now: now, timeZone: Self.utc)?.date,
                       Self.date(2026, 9, 24, 13, 5))
    }

    // MARK: - Copy

    func testShortCountdownCopy() {
        let now = Self.date(2026, 10, 12, 12)
        let calendar = Self.englishUTC
        func short(_ seconds: TimeInterval) -> String? {
            AIUsageResetText.short(now.addingTimeInterval(seconds), now: now, calendar: calendar)
        }
        XCTAssertEqual(short(30), "in 1m")
        XCTAssertEqual(short(38 * 60), "in 38m")
        XCTAssertEqual(short(3 * 3600), "in 3h")
        XCTAssertEqual(short(4 * 3600 + 12 * 60), "in 4h 12m")
        XCTAssertEqual(short(4 * 86_400 + 10 * 3600 + 30), "in 4d 10h")
        XCTAssertEqual(short(2 * 86_400), "in 2d")
        XCTAssertEqual(short(10 * 86_400), "Oct 22")
        XCTAssertNil(short(0))
        XCTAssertNil(short(-60), "A passed reset means stale numbers, not a countdown")
    }

    func testDateOnlyCopyNeverShowsAnHour() {
        let now = Self.date(2026, 10, 5, 18)
        let calendar = Self.englishUTC
        func short(_ date: Date) -> String? {
            AIUsageResetText.short(date, dateOnly: true, now: now, calendar: calendar)
        }
        XCTAssertEqual(short(Self.date(2026, 10, 5)), "today")
        XCTAssertEqual(short(Self.date(2026, 10, 6)), "tomorrow")
        XCTAssertEqual(short(Self.date(2026, 10, 9)), "Oct 9")
        XCTAssertNil(short(Self.date(2026, 10, 4)))
        XCTAssertEqual(AIUsageResetText.absolute(Self.date(2026, 10, 9), dateOnly: true, now: now, calendar: calendar),
                       "Oct 9")
        XCTAssertEqual(AIUsageResetText.absolute(Self.date(2027, 1, 9), dateOnly: true, now: now, calendar: calendar),
                       "Jan 9, 2027")
    }

    func testAbsoluteCopyIncludesTimeAndCaptionsReadNaturally() {
        let now = Self.date(2026, 10, 12, 12)
        let calendar = Self.englishUTC
        let absolute = AIUsageResetText.absolute(Self.date(2026, 10, 13, 15), now: now, calendar: calendar)
        XCTAssertTrue(absolute.hasPrefix("Oct 13"), absolute)
        XCTAssertTrue(absolute.contains("3:00"), absolute)
        XCTAssertFalse(absolute.contains("2026"), absolute)

        let window = AIUsageWindow(id: "seven_day", title: "All models", usedPercent: 12,
                                   resetsAt: now.addingTimeInterval(4 * 86_400 + 10 * 3600 + 30))
        XCTAssertEqual(AIUsageResetText.caption(window, now: now), "Resets in 4d 10h")
        XCTAssertTrue(AIUsageResetText.detail(window, now: now)?.hasPrefix("resets in 4d 10h (") == true)
        let unknown = AIUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 9)
        XCTAssertNil(AIUsageResetText.caption(unknown, now: now))
        XCTAssertNil(AIUsageResetText.detail(unknown, now: now))
    }

    func testSharedResetUsesDisplayedPoolsAndKeepsTheStrictMinuteTolerance() {
        let date = Self.date(2026, 10, 13)
        var snapshot = AIUsageSnapshot(provider: .cursor, status: .ready, plan: nil, windows: [
            .init(id: "totalPercentUsed", title: "Total", usedPercent: 99),
            .init(id: "autoPercentUsed", title: "Models", usedPercent: 20, resetsAt: date),
            .init(id: "apiPercentUsed", title: "Other", usedPercent: 40,
                  resetsAt: date.addingTimeInterval(59))
        ], fetchedAt: nil, sourceLabel: nil)
        XCTAssertEqual(snapshot.sharedReset?.id, "autoPercentUsed",
                       "The hidden rollup does not participate in reset sharing")
        snapshot.windows[2].resetsAt = date.addingTimeInterval(60)
        XCTAssertNil(snapshot.sharedReset)
        snapshot.windows[2].resetsAt = date
        snapshot.windows[2].resetIsDateOnly = true
        XCTAssertNil(snapshot.sharedReset, "A day and an exact instant have different precision")
        snapshot.windows[2].resetIsDateOnly = false
        snapshot.windows[2].resetsAt = nil
        XCTAssertNil(snapshot.sharedReset)
    }

    func testSharingDoesNotChooseAFutureResetWhenTheSharedDateIsStale() {
        let now = Self.date(2026, 10, 13)
        let window = AIUsageWindow(id: "pool", title: "Pool", usedPercent: 80, resetsAt: now)
        let snapshot = AIUsageSnapshot(provider: .grok, status: .ready, plan: nil,
                                       windows: [window], fetchedAt: nil, sourceLabel: nil)
        XCTAssertEqual(snapshot.sharedReset, window)
        XCTAssertNil(AIUsageResetText.caption(window, now: now))
        XCTAssertNil(AIUsageResetText.detail(window, now: now))
    }

    func testAntigravityExplicitTimestampWinsWhenCountdownAlsoExists() throws {
        let now = Self.date(2026, 10, 12)
        let payload = """
        {"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[
          {"id":"gemini-weekly","remaining_fraction":0.5,"reset_time":"2026-10-15T12:00:00Z","reset_after_seconds":3600},
          {"id":"gemini-5h","remaining_fraction":0.5},
          {"id":"3p-weekly","remaining_fraction":0.5},
          {"id":"3p-5h","remaining_fraction":0.5}
        ]}]}}}
        """
        let snapshot = try AntigravityCLIUsage.parse(Data(payload.utf8), now: now).get()
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Self.date(2026, 10, 15, 12))
    }

    func testCountdownRoundingAtHourDayAndWeekBoundaries() {
        let now = Self.date(2026, 10, 12, 12)
        for (interval, expected) in [(3599.0, "in 1h"), (86_399, "in 1d"), (604_799, "Oct 19")] {
            XCTAssertEqual(AIUsageResetText.short(now.addingTimeInterval(interval), now: now,
                                                  calendar: Self.englishUTC), expected)
        }
    }
}
