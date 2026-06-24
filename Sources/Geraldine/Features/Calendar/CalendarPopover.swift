import SwiftUI

/// Start of the current minute. The live clocks anchor their periodic schedule here so
/// ticks land on real wall-clock boundaries — not on the arbitrary instant the popover
/// opened, which would otherwise leave the shown minute stale by up to ~59s.
private func clockAnchor() -> Date {
    Calendar.current.dateInterval(of: .minute, for: Date())?.start ?? Date()
}

/// The calendar as a draggable, reorderable popover widget — same chrome, drag handle,
/// and drop behavior as the metric tiles, but always full-width. Holds today's date +
/// live time, a navigable month grid, and (folded in, not a separate widget) the world
/// clocks with a time-travel slider. Driven by `CalendarSettingsStore`.
struct CalendarWidget: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @State private var monthOffset = 0

    private var workingCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = calendar.firstWeekday.resolved(using: .current)
        return c
    }

    private var anchor: Date {
        workingCalendar.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
    }

    var body: some View {
        let model = MonthModel.make(anchor: anchor, calendar: workingCalendar)
        return VStack(alignment: .leading, spacing: 8) {
            header
            if calendar.showCalendar {
                todayLine
                navigation(monthStart: model.monthStart)
                weekdayHeader
                weeks(model)
            }
            if calendar.hasVisibleClocks {
                if calendar.showCalendar { Divider().padding(.top, 2) }
                WorldClocksSection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.snappy(duration: 0.22), value: monthOffset)
        .widgetDropTarget(.calendar)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.caption).foregroundStyle(Theme.accent)
            Text("Calendar").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            WidgetControls(kind: .calendar, size: .large)
        }
    }

    private var todayLine: some View {
        TimelineView(.periodic(from: clockAnchor(), by: calendar.tickInterval)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(calendar.dateString(for: context.date))
                    .font(.rounded(13, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(calendar.timeString(for: context.date))
                    .font(.rounded(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func weeks(_ model: MonthModel) -> some View {
        ForEach(Array(model.weeks.enumerated()), id: \.offset) { index, week in
            HStack(spacing: 0) {
                if calendar.showWeekNumbers {
                    Text("\(model.weekNumbers[index])")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20)
                }
                ForEach(week, id: \.self) { day in
                    DayCell(date: day,
                            inMonth: workingCalendar.isDate(day, equalTo: model.monthStart, toGranularity: .month),
                            isToday: workingCalendar.isDateInToday(day),
                            isWeekend: calendar.highlightWeekends && workingCalendar.isDateInWeekend(day))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func navigation(monthStart: Date) -> some View {
        HStack(spacing: 4) {
            Text(monthTitle(monthStart))
                .font(.rounded(15, .bold))
            Spacer()
            navButton("chevron.left", help: "Previous Month") { monthOffset -= 1 }
            Button {
                withAnimation(.snappy(duration: 0.22)) { monthOffset = 0 }
            } label: {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(monthOffset == 0 ? Color.secondary : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(monthOffset == 0)
            .help("Jump to Today")
            .pointingHandCursor()
            navButton("chevron.right", help: "Next Month") { monthOffset += 1 }
        }
    }

    private func navButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .pointingHandCursor()
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            if calendar.showWeekNumbers {
                Image(systemName: "number")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
            }
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = workingCalendar.veryShortStandaloneWeekdaySymbols
        let first = workingCalendar.firstWeekday
        return (0..<7).map { symbols[(first - 1 + $0) % symbols.count] }
    }

    private func monthTitle(_ date: Date) -> String {
        Self.monthTitleFormatter.string(from: date)
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()
}

// MARK: - Day cell

private struct DayCell: View {
    let date: Date
    let inMonth: Bool
    let isToday: Bool
    let isWeekend: Bool

    private var day: Int { Calendar.current.component(.day, from: date) }

    var body: some View {
        Text("\(day)")
            .font(.system(size: 12, weight: isToday ? .bold : .regular))
            .monospacedDigit()
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .foregroundStyle(foreground)
            .background {
                if isToday {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 25, height: 25)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 4, y: 1)
                }
            }
    }

    private var foreground: Color {
        if isToday { return .white }
        if !inMonth { return .secondary.opacity(0.35) }
        if isWeekend { return Theme.accent2 }
        return .primary
    }
}

// MARK: - World clocks (folded into the calendar widget)

/// The world-clock list plus Dato-style "time travel": a slider that shifts the displayed
/// moment so you can read your local time against each zone's time at any hour. Not a
/// separate widget — it lives inside `CalendarWidget`.
private struct WorldClocksSection: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore

    /// Hours added to "now" while scrubbing the slider. 0 == the current moment.
    @State private var travelHours: Double = 0

    private let travelRange = -12.0...12.0
    private var isTraveling: Bool { travelHours != 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TimelineView(.periodic(from: clockAnchor(), by: calendar.tickInterval)) { context in
                let shown = context.date.addingTimeInterval(travelHours * 3600)
                VStack(spacing: 8) {
                    ForEach(calendar.clocks) { clock in
                        WorldClockRow(clock: clock, now: shown, highlighted: isTraveling)
                    }
                }
            }
            if calendar.showTimeTravel {
                timeTravel
            }
        }
        .onDisappear { travelHours = 0 }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe").font(.caption).foregroundStyle(Theme.accent2)
            Text("World Clocks").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if isTraveling {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { travelHours = 0 }
                } label: {
                    Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reset to the current time")
                .pointingHandCursor()
            }
        }
    }

    // The slider sits outside the TimelineView so periodic ticks never rebuild it
    // mid-drag; only the label, which shows a live time, ticks.
    private var timeTravel: some View {
        VStack(spacing: 3) {
            TimelineView(.periodic(from: clockAnchor(), by: calendar.tickInterval)) { context in
                let shown = context.date.addingTimeInterval(travelHours * 3600)
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(isTraveling ? Theme.accent : .secondary)
                    Text(label(localNow: shown))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isTraveling ? Theme.accent : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isTraveling {
                        Text(offsetText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Slider(value: $travelHours, in: travelRange, step: 0.25)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .padding(.top, 2)
    }

    /// "Your time · Wed 3:30 PM" while traveling, otherwise an invitation to scrub.
    private func label(localNow: Date) -> String {
        guard isTraveling else { return "Drag to compare times" }
        return "Your time · \(Self.weekday.string(from: localNow)) \(calendar.timeString(for: localNow))"
    }

    private var offsetText: String {
        let totalMinutes = Int((abs(travelHours) * 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let sign = travelHours >= 0 ? "+" : "−"
        if hours > 0 && minutes > 0 { return "\(sign)\(hours)h \(minutes)m" }
        if hours > 0 { return "\(sign)\(hours)h" }
        return "\(sign)\(minutes)m"
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}

private struct WorldClockRow: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore
    let clock: WorldClock
    let now: Date
    /// Subtly emphasize the time while time-traveling so the scrubbed value stands out.
    var highlighted: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            if calendar.showDayNightIcons, let tz = clock.timeZone {
                let day = isDaytime(in: tz)
                Image(systemName: day ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(day ? Theme.warn : Theme.accent)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(clock.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let tz = clock.timeZone {
                    Text(offsetAndDayLabel(tz))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(calendar.timeString(for: now, timeZone: clock.timeZone))
                .font(.rounded(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(highlighted ? Theme.accent : .primary)
        }
    }

    private func isDaytime(in tz: TimeZone) -> Bool {
        var cal = Calendar.current
        cal.timeZone = tz
        let hour = cal.component(.hour, from: now)
        return (6..<18).contains(hour)
    }

    /// "+5:45 · Tomorrow", "−5h", "Same Time" relative to the local zone.
    private func offsetAndDayLabel(_ tz: TimeZone) -> String {
        let diff = tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        var parts: [String] = []

        if diff == 0 {
            parts.append("Same Time")
        } else {
            parts.append(WorldClock.gmtOffsetLabel(seconds: diff))
        }

        if let relative = relativeDayLabel(tz) {
            parts.append(relative)
        }
        return parts.joined(separator: " · ")
    }

    private func relativeDayLabel(_ tz: TimeZone) -> String? {
        // Compare the civil calendar day in each zone (not the absolute instant), so a
        // zone where it's already the next date reads "Tomorrow" even a few hours ahead.
        var cal = Calendar.current
        cal.timeZone = .current
        let local = cal.dateComponents([.year, .month, .day], from: now)
        cal.timeZone = tz
        let there = cal.dateComponents([.year, .month, .day], from: now)

        let utc = Self.utcCalendar
        guard let localDate = utc.date(from: local), let thereDate = utc.date(from: there) else { return nil }
        let days = utc.dateComponents([.day], from: localDate, to: thereDate).day ?? 0
        switch days {
        case ..<0: return "Yesterday"
        case 0:    return nil
        default:   return "Tomorrow"
        }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}
