import SwiftUI

/// The dedicated Calendar page in the main window. Everything the calendar popover
/// shows is configured here — what appears, how the date and time read, and which
/// world clocks are listed.
struct CalendarSettingsView: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar").font(.rounded(28, .bold))
                    Text("Set up the calendar and world clocks that appear in the menu bar popover.")
                        .font(.title3).foregroundStyle(.secondary)
                }

                preview

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("In The Popover", subtitle: "Choose what shows when you open Geraldine.")
                    Toggle("Show Month Calendar", isOn: $calendar.showCalendar)
                    Divider()
                    Toggle("Show Week Numbers", isOn: $calendar.showWeekNumbers)
                        .disabled(!calendar.showCalendar)
                    Toggle("Highlight Weekends", isOn: $calendar.highlightWeekends)
                        .disabled(!calendar.showCalendar)
                    Picker("First Day Of Week", selection: $calendar.firstWeekday) {
                        ForEach(FirstWeekday.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(!calendar.showCalendar)
                }
                .card()

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader("Date & Time", subtitle: "How today's date and the clocks read.")
                    Picker("Time Format", selection: $calendar.clockStyle) {
                        ForEach(ClockStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show Seconds", isOn: $calendar.showSeconds)
                    Divider()
                    Picker("Date Style", selection: $calendar.dateStyle) {
                        ForEach(DateStyle.allCases) { Text($0.label).tag($0) }
                    }
                    if calendar.dateStyle == .custom {
                        customFormatField
                    }
                }
                .card()

                WorldClocksSettings()
            }
            .padding(26)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    // MARK: Live preview

    private var preview: some View {
        TimelineView(.periodic(from: Date(), by: calendar.tickInterval)) { context in
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(calendar.dateString(for: context.date))
                        .font(.rounded(17, .semibold))
                    Text(calendar.timeString(for: context.date))
                        .font(.rounded(14, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Live Preview")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
            .card()
        }
    }

    private var customFormatField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("EEEE, MMM d", text: $calendar.customDateFormat)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            Text("Uses Unicode date tokens — e.g. EEEE (weekday), MMM (month), d (day), yyyy (year).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - World clocks

private struct WorldClocksSettings: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("World Clocks", subtitle: "Track other time zones in the popover.")
                Spacer()
                Button {
                    picking = true
                } label: {
                    Label("Add Time Zone", systemImage: "plus")
                }
                .controlSize(.small)
            }

            Toggle("Show World Clocks", isOn: $calendar.showWorldClocks)
            Toggle("Show Day & Night Icons", isOn: $calendar.showDayNightIcons)
                .disabled(!calendar.showWorldClocks)
            Toggle("Time Travel Slider", isOn: $calendar.showTimeTravel)
                .disabled(!calendar.showWorldClocks)
            Text("Drag the slider in the popover to see your time against each zone at any hour.")
                .font(.caption).foregroundStyle(.secondary)

            if calendar.clocks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                    Text("No world clocks yet. Add a time zone to see it in the popover.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                clockList
            }
        }
        .card()
        .sheet(isPresented: $picking) {
            TimeZonePickerSheet(existing: Set(calendar.clocks.map(\.timeZoneID))) { id in
                calendar.addClock(timeZoneID: id)
            }
        }
    }

    private var clockList: some View {
        VStack(spacing: 0) {
            ForEach(Array(calendar.clocks.enumerated()), id: \.element.id) { index, clock in
                if index > 0 { Divider() }
                ClockRow(clock: clock)
            }
        }
    }

    private struct ClockRow: View {
        @EnvironmentObject private var calendar: CalendarSettingsStore
        let clock: WorldClock
        @State private var label: String = ""

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(WorldClock.cityName(for: clock.timeZoneID))
                        .font(.callout.weight(.medium))
                    let region = WorldClock.regionName(for: clock.timeZoneID)
                    if !region.isEmpty {
                        Text(region).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                TextField("Custom Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onChange(of: label) { _, newValue in calendar.setLabel(newValue, for: clock) }
                Button(role: .destructive) {
                    if let idx = calendar.clocks.firstIndex(where: { $0.id == clock.id }) {
                        calendar.removeClocks(at: IndexSet(integer: idx))
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove This Clock")
            }
            .padding(.vertical, 8)
            .onAppear { label = clock.label }
        }
    }
}

// MARK: - Time-zone picker

private struct TimeZonePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Set<String>
    let onPick: (String) -> Void

    @State private var query = ""

    /// One row's precomputed display fields — sorted and built once (see `allZones`) so
    /// typing in the search field only filters, never re-sorts ~400 zones or rebuilds
    /// a TimeZone per visible row.
    private struct Zone: Identifiable {
        let id: String
        let city: String
        let region: String
        let gmt: String
    }

    private static let allZones: [Zone] = TimeZone.knownTimeZoneIdentifiers.sorted().map { id in
        let seconds = TimeZone(identifier: id)?.secondsFromGMT(for: Date()) ?? 0
        return Zone(id: id,
                    city: WorldClock.cityName(for: id),
                    region: WorldClock.regionName(for: id),
                    gmt: "GMT" + WorldClock.gmtOffsetLabel(seconds: seconds))
    }

    private var zones: [Zone] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.allZones }
        return Self.allZones.filter {
            $0.id.localizedCaseInsensitiveContains(trimmed) ||
            $0.city.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Time Zone").font(.rounded(16, .bold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search cities or zones", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 16)

            List(zones) { zone in
                Button {
                    onPick(zone.id)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(zone.city)
                                .foregroundStyle(.primary)
                            if !zone.region.isEmpty {
                                Text(zone.region).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if existing.contains(zone.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.good)
                        } else {
                            Text(zone.gmt)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(existing.contains(zone.id))
            }
            .listStyle(.inset)
        }
        .frame(width: 440, height: 520)
    }
}
