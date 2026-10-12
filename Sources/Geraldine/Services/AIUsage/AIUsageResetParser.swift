import Foundation
import CoreFoundation

/// Reset text the agent CLIs print beside a meter:
/// Claude `Sep 16 at 9pm (Asia/Manila)` or `9pm (Asia/Manila)`,
/// Grok `September 24, 01:27`, Cursor `Oct 6`, Antigravity `in 106h4m42s`,
/// or ISO 8601. Missing years roll forward only across the existing year-boundary
/// heuristic; recently passed dates remain stale.
enum AIUsageResetParser {
    struct Reset: Equatable {
        var date: Date
        var dateOnly: Bool
    }

    static func parse(_ raw: String, now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Reset? {
        guard isRepresentable(now) else { return nil }
        let text = normalizedText(raw)
        guard !text.isEmpty else { return nil }
        if let date = AIUsageJSON.date(text), text.contains("-") || text.contains("T") {
            return Reset(date: date, dateOnly: false)
        }
        if let seconds = duration(text) {
            return adding(seconds, to: now).map { Reset(date: $0, dateOnly: false) }
        }
        return calendarDate(text, now: now, fallbackZone: timeZone)
    }

    private static func normalizedText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t·•:│|").union(.whitespacesAndNewlines))
        // A separated terminal bullet is decoration; an attached minus is data.
        if let bullet = text.range(of: #"^[-–—]\s+"#, options: .regularExpression) { text.removeSubrange(bullet) }
        if let range = text.range(of: #"^resets?\b[:\s]*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t·•:│|").union(.whitespacesAndNewlines))
        return text
    }

    /// `in 106h4m42s`, `4d 10h`, `2 hours 5 minutes`. The whole string must be
    /// duration units, so `Sep 16 at 9pm` is never read as minutes.
    static func duration(_ text: String) -> TimeInterval? {
        var rest = text.lowercased().trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("in ") { rest.removeFirst(3) }
        let unit = #"(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)(?![a-z])"#
        guard !rest.isEmpty,
              rest.range(of: #"^(?:\s*"# + unit + #"[\s,]*(?:and\s+)?)+$"#, options: .regularExpression) != nil,
              let regex = try? NSRegularExpression(pattern: unit) else { return nil }
        var total: TimeInterval = 0
        for match in regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
            guard let valueRange = Range(match.range(at: 1), in: rest),
                  let unitRange = Range(match.range(at: 2), in: rest),
                  let value = Double(rest[valueRange]), value.isFinite else { return nil }
            switch rest[unitRange].first {
            case "d": total += value * 86_400
            case "h": total += value * 3_600
            case "m": total += value * 60
            default: total += value
            }
        }
        return total.isFinite && total > 0 ? total : nil
    }

    private static func calendarDate(_ text: String, now: Date, fallbackZone: TimeZone) -> Reset? {
        guard isRepresentable(now) else { return nil }
        var body = text
        var zone = fallbackZone
        // Claude appends the account's zone: "(Asia/Manila)".
        if let match = body.range(of: #"\(([^)]+)\)\s*$"#, options: .regularExpression) {
            let name = body[match].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            guard let named = TimeZone(identifier: name) ?? TimeZone(abbreviation: name) else { return nil }
            zone = named
            body.removeSubrange(match)
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:(?:(?:mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?),?\s+)?([a-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4,}))?)?\s*(?:,|at)?\s*(?:(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: body).map { String(body[$0]) }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let month = group(1).flatMap(monthNumber)
        if group(1) != nil, month == nil { return nil }
        let day = group(2).flatMap { Int($0) }
        let year = group(3).flatMap { Int($0) }
        // Foundation reserves Int.max for an unset DateComponents field.
        if group(3) != nil, year.map({ $0 > 0 && $0 != NSDateComponentUndefined }) != true { return nil }
        var hour = group(4).flatMap { Int($0) }
        let minute = group(5).flatMap { Int($0) } ?? 0
        if let meridiem = group(6)?.lowercased().replacingOccurrences(of: ".", with: ""), let raw = hour {
            guard (1...12).contains(raw) else { return nil }
            hour = (raw % 12) + (meridiem == "pm" ? 12 : 0)
        }
        guard month != nil || hour != nil,
              hour.map({ (0...23).contains($0) }) ?? true, (0...59).contains(minute) else { return nil }

        var components = DateComponents()
        components.hour = hour ?? 0
        components.minute = hour == nil ? 0 : minute
        if let month, let day {
            components.month = month
            components.day = day
            let thisYear = year ?? calendar.component(.year, from: now)
            components.year = thisYear
            guard var date = exactDate(components, calendar: calendar) else { return nil }
            // No printed year: only a year boundary ("Jan 3" read on Dec 30) rolls
            // forward. A recently passed date stays past, so the tile hides it.
            if year == nil, date.timeIntervalSince(now) < -183 * 86_400 {
                let (nextYear, overflow) = thisYear.addingReportingOverflow(1)
                guard !overflow else { return nil }
                components.year = nextYear
                guard let next = exactDate(components, calendar: calendar) else { return nil }
                date = next
            }
            return Reset(date: date, dateOnly: hour == nil)
        }
        // Time only: today in that zone, or tomorrow once it has passed.
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        components.year = today.year
        components.month = today.month
        components.day = today.day
        guard var date = exactDate(components, calendar: calendar) else { return nil }
        if date <= now {
            // Advance the calendar day, then revalidate the requested wall time.
            // Adding a day to 02:30 itself would normalize a DST gap to 03:30.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  isRepresentable(tomorrow) else { return nil }
            let next = calendar.dateComponents([.year, .month, .day], from: tomorrow)
            components.year = next.year
            components.month = next.month
            components.day = next.day
            guard let nextDate = exactDate(components, calendar: calendar) else { return nil }
            date = nextDate
        }
        return Reset(date: date, dateOnly: false)
    }

    private static func monthNumber(_ name: String) -> Int? {
        let key = name.lowercased()
        let months = ["january", "february", "march", "april", "may", "june",
                      "july", "august", "september", "october", "november", "december"]
        return months.firstIndex { key == $0 || key == String($0.prefix(3)) || ($0 == "september" && key == "sept") }
            .map { $0 + 1 }
    }

    /// Validate against Foundation's actual calendar representation, not a
    /// product date ceiling. A finite Double alone can still be clamped by ICU.
    static func isRepresentable(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite, Int(exactly: seconds.rounded(.towardZero)) != nil else { return false }
        let components = utcCalendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second], from: date)
        guard let roundTrip = utcCalendar.date(from: components) else { return false }
        let remainder = date.timeIntervalSince(roundTrip)
        return remainder >= 0 && remainder < 1
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Calendar.date(from:) normalizes invalid dates and nonexistent local
    /// times. Require all supplied components to survive the round trip.
    private static func exactDate(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components), isRepresentable(date) else { return nil }
        let units: [Calendar.Component] = [.year, .month, .day, .hour, .minute, .second]
        let actual = calendar.dateComponents(Set(units), from: date)
        guard units.allSatisfy({ unit in
            components.value(for: unit).map { $0 == actual.value(for: unit) } ?? true
        }) else { return nil }
        return date
    }

    /// JSON booleans bridge to NSNumber; they are never timestamps or seconds.
    private static func resetNumber(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        guard let number = AIUsageJSON.number(value), number.isFinite else { return nil }
        return number
    }

    private static func adding(_ seconds: TimeInterval, to now: Date) -> Date? {
        guard seconds.isFinite, seconds > 0, isRepresentable(now) else { return nil }
        let date = now.addingTimeInterval(seconds)
        guard date > now, isRepresentable(date) else { return nil }
        return date
    }

    /// Absolute provider fields accept epoch seconds/milliseconds (including
    /// numeric strings) or a complete ISO timestamp with an explicit offset.
    static func timestamp(_ value: Any?) -> Date? {
        if let number = resetNumber(value) {
            // Preserve the existing seconds/milliseconds provider convention.
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            let date = Date(timeIntervalSince1970: seconds)
            return isRepresentable(date) ? date : nil
        }
        guard let text = AIUsageJSON.string(value),
              let regex = try? NSRegularExpression(pattern: #"^(\d{4,})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?([Zz]|[+-]\d{2}:?\d{2})\z"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let year = group(1).flatMap(Int.init), year > 0, year != NSDateComponentUndefined,
              let month = group(2).flatMap(Int.init), (1...12).contains(month),
              let day = group(3).flatMap(Int.init), (1...31).contains(day),
              let hour = group(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = group(5).flatMap(Int.init), (0...59).contains(minute),
              let second = group(6).flatMap(Int.init), (0...59).contains(second),
              let zone = group(8) else { return nil }
        var offset = 0
        if zone.lowercased() != "z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), hours < 24,
                  let minutes = Int(digits.suffix(2)), minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        guard let timeZone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = utcCalendar
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let whole = exactDate(components, calendar: calendar) else { return nil }
        let fraction = group(7).flatMap { Double("0." + $0) } ?? 0
        let date = whole.addingTimeInterval(fraction)
        return isRepresentable(date) ? date : nil
    }

    /// Relative fields have seconds semantics, whether JSON encodes a number
    /// or numeric string. Printed duration phrases are allowed, calendar dates
    /// in these fields are not.
    static func countdown(_ value: Any?, now: Date) -> Date? {
        if let seconds = resetNumber(value) { return adding(seconds, to: now) }
        guard var text = AIUsageJSON.string(value) else { return nil }
        if let prefix = text.range(of: #"^resets?\b[:\s]*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(prefix)
        }
        return duration(text).flatMap { adding($0, to: now) }
    }

    /// First `Resets …` phrase on one line of terminal text.
    static func phrase(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\bresets?\b:?\s*([^\n│|]+)"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let phrase = text[range].trimmingCharacters(in: .whitespaces)
        return phrase.isEmpty ? nil : phrase
    }

    /// Parse the first reset phrase without making each terminal reader repeat
    /// the extraction step. Explicit timestamps in provider JSON stay separate.
    static func parsePhrase(in text: String, now: Date) -> Reset? {
        phrase(in: text).flatMap { parse($0, now: now) }
    }

    /// Known CLI fallback fields only. Provider readers apply their explicit
    /// timestamp precedence first (Antigravity reset_time, Codex reset_at).
    /// Sorted fallback order preserves precedence between established keys.
    static func reset(in object: [String: Any], now: Date) -> Reset? {
        for key in object.keys.sorted() {
            let value = object[key]
            switch key.lowercased() {
            case "reset_after_seconds", "reset_in_seconds", "reset_seconds", "reset_in",
                 "resetafterseconds", "resetinseconds", "resetin":
                if let date = countdown(value, now: now) { return Reset(date: date, dateOnly: false) }
            case "reset_at", "resets_at", "reset_time", "resettime", "resetsat", "resetdate", "reset_date":
                if let date = timestamp(value) { return Reset(date: date, dateOnly: false) }
                // Some CLI versions print a calendar date in these fields.
                // Preserve that format, without interpreting it as a duration.
                if let text = AIUsageJSON.string(value),
                   let reset = calendarDate(normalizedText(text), now: now, fallbackZone: .autoupdatingCurrent) {
                    return reset
                }
            case "reset", "resets":
                if let text = AIUsageJSON.string(value), let reset = parse(text, now: now) { return reset }
            default: break
            }
        }
        return nil
    }
}
