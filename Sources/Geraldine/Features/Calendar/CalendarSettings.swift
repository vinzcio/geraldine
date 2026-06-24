import SwiftUI
import Foundation

// MARK: - World clock

/// A clock for one time zone, shown in the calendar popover. The label is optional —
/// when empty, the city is derived from the time-zone identifier.
struct WorldClock: Codable, Identifiable, Equatable {
    var id: UUID
    var timeZoneID: String
    var label: String

    init(id: UUID = UUID(), timeZoneID: String, label: String = "") {
        self.id = id
        self.timeZoneID = timeZoneID
        self.label = label
    }

    var timeZone: TimeZone? { TimeZone(identifier: timeZoneID) }

    /// The user's label if set, otherwise the city pulled from the identifier.
    var name: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? WorldClock.cityName(for: timeZoneID) : trimmed
    }

    /// "America/New_York" → "New York", "Europe/London" → "London".
    static func cityName(for id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id)
            .replacingOccurrences(of: "_", with: " ")
    }

    /// "America/New_York" → "America".
    static func regionName(for id: String) -> String {
        let parts = id.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts[0].replacingOccurrences(of: "_", with: " ")
    }

    /// A GMT offset (in seconds) as a signed clock offset: "+9h", "+5:45", "−5h".
    /// Whole hours render with an "h"; fractional zones (Kathmandu, Kolkata) as "H:MM".
    static func gmtOffsetLabel(seconds: Int) -> String {
        let totalMinutes = abs(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let sign = seconds >= 0 ? "+" : "−"
        return minutes == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours):\(String(format: "%02d", minutes))"
    }
}

// MARK: - Format choices

/// How the time is shown in the popover header and world clocks.
enum ClockStyle: String, Codable, CaseIterable, Identifiable {
    case system, twelveHour, twentyFourHour

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:        return "System"
        case .twelveHour:    return "12-Hour"
        case .twentyFourHour: return "24-Hour"
        }
    }
}

/// How today's date is shown above the month grid.
enum DateStyle: String, Codable, CaseIterable, Identifiable {
    case full      // Wednesday, June 24, 2026
    case long      // June 24, 2026
    case medium    // Wed, Jun 24
    case custom    // user-supplied DateFormatter pattern

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full:   return "Full"
        case .long:   return "Long"
        case .medium: return "Medium"
        case .custom: return "Custom"
        }
    }

    /// Localized template for the built-in styles; nil for `.custom`.
    var template: String? {
        switch self {
        case .full:   return "EEEEMMMMdyyyy"
        case .long:   return "MMMMdyyyy"
        case .medium: return "EEEMMMd"
        case .custom: return nil
        }
    }
}

/// Which day a calendar week starts on. `.system` follows the user's locale.
enum FirstWeekday: Int, Codable, CaseIterable, Identifiable {
    case system = 0
    case sunday = 1
    case monday = 2
    case saturday = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system:   return "System"
        case .sunday:   return "Sunday"
        case .monday:   return "Monday"
        case .saturday: return "Saturday"
        }
    }

    /// The 1…7 Calendar weekday for this choice (Sunday = 1).
    func resolved(using calendar: Calendar) -> Int {
        self == .system ? calendar.firstWeekday : rawValue
    }
}

// MARK: - Store

/// Everything that drives the calendar block in the menu-bar popover. The user edits
/// these from the Calendar page in the main window; the popover reads them live.
@MainActor
final class CalendarSettingsStore: ObservableObject {
    private enum Key {
        static let showCalendar = "calendar.showCalendar"
        static let firstWeekday = "calendar.firstWeekday"
        static let showWeekNumbers = "calendar.showWeekNumbers"
        static let highlightWeekends = "calendar.highlightWeekends"
        static let clockStyle = "calendar.clockStyle"
        static let showSeconds = "calendar.showSeconds"
        static let dateStyle = "calendar.dateStyle"
        static let customDateFormat = "calendar.customDateFormat"
        static let showWorldClocks = "calendar.showWorldClocks"
        static let showDayNightIcons = "calendar.showDayNightIcons"
        static let showTimeTravel = "calendar.showTimeTravel"
        static let clocks = "calendar.worldClocks.v1"
    }

    @Published var showCalendar: Bool {
        didSet { defaults.set(showCalendar, forKey: Key.showCalendar) }
    }
    @Published var firstWeekday: FirstWeekday {
        didSet { defaults.set(firstWeekday.rawValue, forKey: Key.firstWeekday) }
    }
    @Published var showWeekNumbers: Bool {
        didSet { defaults.set(showWeekNumbers, forKey: Key.showWeekNumbers) }
    }
    @Published var highlightWeekends: Bool {
        didSet { defaults.set(highlightWeekends, forKey: Key.highlightWeekends) }
    }
    @Published var clockStyle: ClockStyle {
        didSet { defaults.set(clockStyle.rawValue, forKey: Key.clockStyle); cachedTimeFormatter = nil }
    }
    @Published var showSeconds: Bool {
        didSet { defaults.set(showSeconds, forKey: Key.showSeconds); cachedTimeFormatter = nil }
    }
    @Published var dateStyle: DateStyle {
        didSet { defaults.set(dateStyle.rawValue, forKey: Key.dateStyle); cachedDateFormatter = nil }
    }
    @Published var customDateFormat: String {
        didSet { defaults.set(customDateFormat, forKey: Key.customDateFormat); cachedDateFormatter = nil }
    }
    @Published var showWorldClocks: Bool {
        didSet { defaults.set(showWorldClocks, forKey: Key.showWorldClocks) }
    }
    @Published var showDayNightIcons: Bool {
        didSet { defaults.set(showDayNightIcons, forKey: Key.showDayNightIcons) }
    }
    @Published var showTimeTravel: Bool {
        didSet { defaults.set(showTimeTravel, forKey: Key.showTimeTravel) }
    }
    @Published var clocks: [WorldClock] {
        didSet { persistClocks() }
    }

    private let defaults: UserDefaults

    // Formatters are rebuilt only when their inputs change (see the didSets above), not
    // on every tick — building a DateFormatter is expensive and these run per clock row.
    private var cachedTimeFormatter: DateFormatter?
    private var cachedDateFormatter: DateFormatter?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        showCalendar = defaults.object(forKey: Key.showCalendar) as? Bool ?? true
        firstWeekday = FirstWeekday(rawValue: defaults.integer(forKey: Key.firstWeekday)) ?? .system
        showWeekNumbers = defaults.bool(forKey: Key.showWeekNumbers)
        highlightWeekends = defaults.object(forKey: Key.highlightWeekends) as? Bool ?? true
        clockStyle = ClockStyle(rawValue: defaults.string(forKey: Key.clockStyle) ?? "") ?? .system
        showSeconds = defaults.bool(forKey: Key.showSeconds)
        dateStyle = DateStyle(rawValue: defaults.string(forKey: Key.dateStyle) ?? "") ?? .full
        customDateFormat = defaults.string(forKey: Key.customDateFormat) ?? "EEEE, MMM d"
        showWorldClocks = defaults.object(forKey: Key.showWorldClocks) as? Bool ?? true
        showDayNightIcons = defaults.object(forKey: Key.showDayNightIcons) as? Bool ?? true
        showTimeTravel = defaults.object(forKey: Key.showTimeTravel) as? Bool ?? true

        if let data = defaults.data(forKey: Key.clocks),
           let decoded = try? JSONDecoder().decode([WorldClock].self, from: data) {
            clocks = decoded
        } else {
            clocks = []
        }
    }

    /// Refresh interval for the live readouts: 1s while seconds are shown, otherwise 60s.
    var tickInterval: TimeInterval { showSeconds ? 1 : 60 }

    /// World clocks are only shown when enabled and at least one zone has been added.
    var hasVisibleClocks: Bool { showWorldClocks && !clocks.isEmpty }

    /// Whether the calendar widget shows anything at all (drives its presence in the grid).
    var appearsInPopover: Bool { showCalendar || hasVisibleClocks }

    // MARK: World-clock editing

    func addClock(timeZoneID: String) {
        guard !clocks.contains(where: { $0.timeZoneID == timeZoneID }) else { return }
        clocks.append(WorldClock(timeZoneID: timeZoneID))
    }

    func removeClocks(at offsets: IndexSet) {
        clocks.remove(atOffsets: offsets)
    }

    func setLabel(_ label: String, for clock: WorldClock) {
        guard let index = clocks.firstIndex(where: { $0.id == clock.id }) else { return }
        clocks[index].label = label
    }

    private func persistClocks() {
        guard let data = try? JSONEncoder().encode(clocks) else { return }
        defaults.set(data, forKey: Key.clocks)
    }

    // MARK: Formatting

    /// The time of `date`, optionally rendered in another zone, following the chosen style.
    func timeString(for date: Date, timeZone: TimeZone? = nil) -> String {
        let formatter = timeFormatter()
        formatter.timeZone = timeZone ?? .current
        return formatter.string(from: date)
    }

    /// Today's date rendered with the chosen style (or the custom pattern).
    func dateString(for date: Date) -> String {
        dateFormatter().string(from: date)
    }

    private func timeFormatter() -> DateFormatter {
        if let cachedTimeFormatter { return cachedTimeFormatter }
        let formatter = DateFormatter()
        formatter.locale = .current
        switch clockStyle {
        case .system:
            // `j` resolves to the locale's preferred 12/24-hour clock.
            let template = showSeconds ? "jmmss" : "jmm"
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .current)
        case .twelveHour:
            formatter.dateFormat = showSeconds ? "h:mm:ss a" : "h:mm a"
        case .twentyFourHour:
            formatter.dateFormat = showSeconds ? "HH:mm:ss" : "HH:mm"
        }
        cachedTimeFormatter = formatter
        return formatter
    }

    private func dateFormatter() -> DateFormatter {
        if let cachedDateFormatter { return cachedDateFormatter }
        let formatter = DateFormatter()
        formatter.locale = .current
        if let template = dateStyle.template {
            formatter.setLocalizedDateFormatFromTemplate(template)
        } else {
            let pattern = customDateFormat.trimmingCharacters(in: .whitespacesAndNewlines)
            formatter.dateFormat = pattern.isEmpty ? "EEEE, MMM d" : pattern
        }
        cachedDateFormatter = formatter
        return formatter
    }
}

// MARK: - Month layout

/// Six calendar weeks covering the month that contains `anchor`, laid out so the
/// first column matches the chosen first day of week.
struct MonthModel {
    let monthStart: Date
    let weeks: [[Date]]
    let weekNumbers: [Int]

    static func make(anchor: Date, calendar: Calendar) -> MonthModel {
        let firstWeekday = calendar.firstWeekday
        let comps = calendar.dateComponents([.year, .month], from: anchor)
        let monthStart = calendar.date(from: comps) ?? calendar.startOfDay(for: anchor)

        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart

        var weeks: [[Date]] = []
        var weekNumbers: [Int] = []
        for week in 0..<6 {
            var days: [Date] = []
            for day in 0..<7 {
                let date = calendar.date(byAdding: .day, value: week * 7 + day, to: gridStart) ?? gridStart
                days.append(date)
            }
            weeks.append(days)
            weekNumbers.append(calendar.component(.weekOfYear, from: days[0]))
        }
        return MonthModel(monthStart: monthStart, weeks: weeks, weekNumbers: weekNumbers)
    }
}
