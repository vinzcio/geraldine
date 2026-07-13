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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedMonthOffset = 0
    @State private var outgoingMonthOffset: Int?
    @State private var pagingDirection = 1
    @State private var incomingMonthVisible = true
    @State private var outgoingMonthVisible = false
    @State private var monthTransitionTask: Task<Void, Never>?

    private var workingCalendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = calendar.firstWeekday.resolved(using: .current)
        return c
    }

    private func monthModel(for offset: Int) -> MonthModel {
        let anchor = workingCalendar.date(byAdding: .month, value: offset, to: Date()) ?? Date()
        return MonthModel.make(anchor: anchor, calendar: workingCalendar)
    }

    var body: some View {
        let model = monthModel(for: displayedMonthOffset)
        return VStack(alignment: .leading, spacing: 8) {
            header
            if calendar.showCalendar {
                todayLine
                navigation(monthStart: model.monthStart)
                monthGrid(model)
            }
            if calendar.hasVisibleClocks {
                if calendar.showCalendar { Divider().padding(.top, 2) }
                WorldClocksSection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .widgetDropTarget(.calendar)
        .onChange(of: reduceMotion) { _, isReduced in
            if isReduced { finishMonthTransition() }
        }
        .onDisappear { finishMonthTransition() }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.caption).foregroundStyle(Theme.accent)
            Text("Calendar & Clocks").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            WidgetControls(kind: .calendar, size: .large)
        }
    }

    private var todayLine: some View {
        GeraldinePeriodicTimeline(from: clockAnchor(), by: calendar.tickInterval) { date in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(calendar.dateString(for: date))
                    .font(.rounded(13, .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text(calendar.timeString(for: date))
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

    private func monthGrid(_ model: MonthModel) -> some View {
        ZStack {
            monthGridContent(model)
                .opacity(incomingMonthVisible ? 1 : 0)
                .offset(x: reduceMotion || incomingMonthVisible
                        ? 0 : CGFloat(pagingDirection) * 8)
                .zIndex(0)

            if let outgoingMonthOffset {
                monthGridContent(monthModel(for: outgoingMonthOffset))
                    .opacity(outgoingMonthVisible ? 1 : 0)
                    .offset(x: reduceMotion || outgoingMonthVisible
                            ? 0 : CGFloat(-pagingDirection) * 4)
                    .accessibilityHidden(true)
                    .zIndex(1)
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(monthTitle(model.monthStart)) calendar")
    }

    private func monthGridContent(_ model: MonthModel) -> some View {
        VStack(spacing: 0) {
            weekdayHeader
            weeks(model)
        }
    }

    private func navigation(monthStart: Date) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Text(monthTitle(monthStart))
                    .font(.rounded(15, .bold))
                    .opacity(incomingMonthVisible ? 1 : 0)
                    .offset(x: reduceMotion || incomingMonthVisible
                            ? 0 : CGFloat(pagingDirection) * 8)

                if let outgoingMonthOffset {
                    Text(monthTitle(monthModel(for: outgoingMonthOffset).monthStart))
                        .font(.rounded(15, .bold))
                        .opacity(outgoingMonthVisible ? 1 : 0)
                        .offset(x: reduceMotion || outgoingMonthVisible
                                ? 0 : CGFloat(-pagingDirection) * 4)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 116, alignment: .leading)
            .clipped()
            .accessibilityAddTraits(.isHeader)
            Spacer()
            navButton("chevron.left", help: "Previous Month") { changeMonth(by: -1) }
            Button {
                returnToToday()
            } label: {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(displayedMonthOffset == 0 ? Color.secondary : Theme.accent)
            }
            .buttonStyle(.quiet(Theme.accent))
            .disabled(displayedMonthOffset == 0)
            .help("Jump to Today")
            .accessibilityHint("Shows the current month")
            navButton("chevron.right", help: "Next Month") { changeMonth(by: 1) }
        }
    }

    private func navButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.quiet(Theme.accent))
        .help(help)
        .accessibilityLabel(help)
    }

    private func changeMonth(by delta: Int) {
        beginMonthTransition(to: displayedMonthOffset + delta,
                             direction: delta < 0 ? -1 : 1)
    }

    private func returnToToday() {
        guard displayedMonthOffset != 0 else { return }
        beginMonthTransition(to: 0,
                             direction: displayedMonthOffset > 0 ? -1 : 1)
    }

    private func beginMonthTransition(to value: Int, direction: Int) {
        guard value != displayedMonthOffset else { return }
        let interrupted = monthTransitionTask != nil
        monthTransitionTask?.cancel()

        withTransaction(Transaction(animation: nil)) {
            outgoingMonthOffset = interrupted ? nil : displayedMonthOffset
            outgoingMonthVisible = !interrupted
            pagingDirection = direction < 0 ? -1 : 1
            displayedMonthOffset = value
            incomingMonthVisible = false
        }

        monthTransitionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            let incomingAnimation = reduceMotion
                ? Animation.easeOut(duration: 0.10)
                : (GeraldineMotion.animation(.standard, reduceMotion: false) ?? .default)
            let outgoingAnimation = reduceMotion
                ? Animation.easeOut(duration: 0.10)
                : (GeraldineMotion.animation(.quick, reduceMotion: false) ?? .default)
            withAnimation(incomingAnimation) { incomingMonthVisible = true }
            withAnimation(outgoingAnimation) { outgoingMonthVisible = false }

            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 240))
            guard !Task.isCancelled else { return }
            outgoingMonthOffset = nil
            monthTransitionTask = nil
        }
    }

    private func finishMonthTransition() {
        monthTransitionTask?.cancel()
        monthTransitionTask = nil
        incomingMonthVisible = true
        outgoingMonthVisible = false
        outgoingMonthOffset = nil
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
            .accessibilityLabel(Self.accessibilityFormatter.string(from: date))
            .accessibilityValue(isToday ? "Today" : (isWeekend ? "Weekend" : ""))
    }

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hours added to "now" while scrubbing the slider. 0 == the current moment.
    @State private var travelHours: Double = 0

    private let travelRange = -12.0...12.0
    private var isTraveling: Bool { travelHours != 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeraldinePeriodicTimeline(from: clockAnchor(), by: calendar.tickInterval) { date in
                let shown = date.addingTimeInterval(travelHours * 3600)
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
                    travelHours = 0
                } label: {
                    Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.quiet(Theme.accent))
                .help("Reset to the current time")
                .accessibilityHint("Returns all clocks to the current time")
                .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
            }
        }
        .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isTraveling)
    }

    // The slider sits outside the TimelineView so periodic ticks never rebuild it
    // mid-drag; only the label, which shows a live time, ticks.
    private var timeTravel: some View {
        VStack(spacing: 3) {
            GeraldinePeriodicTimeline(from: clockAnchor(), by: calendar.tickInterval) { date in
                let shown = date.addingTimeInterval(travelHours * 3600)
                HStack(spacing: 5) {
                    ContextualSymbol(
                        inactive: "clock.arrow.2.circlepath",
                        active: "clock.fill",
                        isActive: isTraveling,
                        tint: isTraveling ? Theme.accent : Color.secondary,
                        size: 10
                    )
                    Text(label(localNow: shown))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isTraveling ? Theme.accent : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isTraveling {
                        Text(offsetText)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isTraveling)
            }
            Slider(value: $travelHours, in: travelRange, step: 0.25)
                .controlSize(.mini)
                .tint(Theme.accent)
                .accessibilityLabel("Time Travel")
                .accessibilityValue(timeTravelAccessibilityValue)
        }
        .padding(Theme.Spacing.xs)
        .background(Theme.accent.opacity(isTraveling ? 0.09 : 0.035),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
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

    private var timeTravelAccessibilityValue: String {
        guard isTraveling else { return "Current time" }
        let shown = Date().addingTimeInterval(travelHours * 3600)
        return "\(offsetText), \(label(localNow: shown))"
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
                ContextualSymbol(
                    inactive: "moon.fill",
                    active: "sun.max.fill",
                    isActive: day,
                    tint: day ? Theme.warn : Theme.accent,
                    size: 11
                )
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
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(highlighted ? Theme.accent.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clock.name)
        .accessibilityValue("\(calendar.timeString(for: now, timeZone: clock.timeZone)), \(clock.timeZone.map(offsetAndDayLabel) ?? "Time zone unavailable")")
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
