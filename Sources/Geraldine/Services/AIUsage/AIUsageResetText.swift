import Foundation

/// Reset copy shared by tiles, Settings, tooltips, and VoiceOver. Countdowns
/// stay short enough for a one-column tile; a date-only reset never gains an
/// invented hour.
enum AIUsageResetText {
    /// The copy variants used by the tile's footer, rows, and compact groups.
    /// Each case describes a complete phrase, so conflicting flags are impossible.
    enum CaptionStyle {
        case standalone
        case summary(subject: String)
        case clause
        case inline
        case countdown

        fileprivate func text(_ short: String) -> String {
            switch self {
            case .standalone: return "Resets " + short
            case .summary(let subject): return "\(subject) resets \(short)"
            case .clause: return "resets " + short
            case .inline: return "· resets " + short
            case .countdown: return short
            }
        }
    }

    enum DetailStyle {
        case relativeAndAbsolute
        /// Settings does not tick, so its caption uses only the absolute reset.
        case absolute
    }

    /// "in 38m", "in 4h 12m", "in 4d 10h", or "Oct 13" beyond a week.
    /// Nil once the reset has passed: the numbers are stale until the next read.
    static func short(_ date: Date, dateOnly: Bool = false, now: Date = Date(),
                      calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard AIUsageResetParser.isRepresentable(date), AIUsageResetParser.isRepresentable(now) else { return nil }
        let interval = date.timeIntervalSince(now)
        if dateOnly {
            guard calendar.startOfDay(for: date) >= calendar.startOfDay(for: now) else { return nil }
            if calendar.isDate(date, inSameDayAs: now) { return "today" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow" }
            return day(date, now: now, calendar: calendar)
        }
        guard interval > 0 else { return nil }
        let roundedMinutes = (interval / 60).rounded(.up)
        // Dates beyond a week use the calendar. Never convert an unbounded
        // provider interval to Int just to decide which presentation to use.
        if roundedMinutes >= 7 * 1440 { return day(date, now: now, calendar: calendar) }
        guard let minutes = Int(exactly: roundedMinutes) else { return nil }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
        return "in \(mins)m"
    }

    /// "Oct 13, 3:00 PM" (year added outside the current year), or "Oct 6".
    static func absolute(_ date: Date, dateOnly: Bool = false, now: Date = Date(),
                         calendar: Calendar = .autoupdatingCurrent) -> String {
        guard AIUsageResetParser.isRepresentable(date), AIUsageResetParser.isRepresentable(now) else { return "" }
        guard !dateOnly else { return day(date, now: now, calendar: calendar) }
        return date.formatted(dayStyle(date, now: now, calendar: calendar).hour().minute())
    }

    /// Tile copy: "Resets in 4d 10h" or "Resets Oct 13".
    static func caption(_ window: AIUsageWindow, style: CaptionStyle = .standalone,
                        now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let date = window.resetsAt,
              let short = short(date, dateOnly: window.resetIsDateOnly, now: now, calendar: calendar) else { return nil }
        return style.text(short)
    }

    /// Settings, tooltip, and VoiceOver copy: "resets in 4d 10h (Oct 13, 3:00 PM)".
    static func detail(_ window: AIUsageWindow, style: DetailStyle = .relativeAndAbsolute,
                       now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String? {
        guard let date = window.resetsAt,
              let short = short(date, dateOnly: window.resetIsDateOnly, now: now, calendar: calendar) else { return nil }
        let absolute = absolute(date, dateOnly: window.resetIsDateOnly, now: now, calendar: calendar)
        switch style {
        case .relativeAndAbsolute where short.hasPrefix("in "):
            return "resets \(short) (\(absolute))"
        case .relativeAndAbsolute, .absolute:
            return "resets \(absolute)"
        }
    }

    private static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        date.formatted(dayStyle(date, now: now, calendar: calendar))
    }

    private static func dayStyle(_ date: Date, now: Date, calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle(date: .omitted, time: .omitted,
                                     locale: calendar.locale ?? .autoupdatingCurrent,
                                     calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return style
    }
}
