import XCTest
@testable import Geraldine

final class CalendarModelTests: XCTestCase {

    func testMonthModelMakeGeneratesSixWeeks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6))!

        let model = MonthModel.make(anchor: date, calendar: calendar)

        XCTAssertEqual(model.weeks.count, 6)
        for week in model.weeks {
            XCTAssertEqual(week.count, 7)
        }
    }

    func testMonthModelFirstWeekdayRespected() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2 // Monday
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6))!

        let model = MonthModel.make(anchor: date, calendar: calendar)

        // August 1, 2026 is Saturday. If week starts on Monday, first week starts on July 27, 2026 (Monday).
        let firstDay = model.weeks[0][0]
        let weekday = calendar.component(.weekday, from: firstDay)
        XCTAssertEqual(weekday, 2, "First day of month grid should be Monday")
    }

    func testDateInSameDayAsComparison() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let morning = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 8))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 8, day: 6, hour: 20))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 8))!

        XCTAssertTrue(calendar.isDate(morning, inSameDayAs: evening))
        XCTAssertFalse(calendar.isDate(morning, inSameDayAs: nextDay))
    }
}
