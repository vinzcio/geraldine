import SwiftUI

/// The dedicated Calendar & Clocks page in the main window. Everything the calendar popover
/// shows is configured here — what appears, how the date and time read, and which
/// world clocks are listed.
struct CalendarSettingsView: View {
    @EnvironmentObject private var calendar: CalendarSettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ModulePage(module: .calendar, widthRole: .focused) {
            preview

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 310), spacing: Theme.Spacing.md)],
                alignment: .leading,
                spacing: Theme.Spacing.md
            ) {
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
                .card(tier: .base)

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
                            .transition(GeraldineMotion.stateTransition(reduceMotion: reduceMotion))
                    }
                }
                .card(tier: .base)
                .animation(GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
                           value: calendar.dateStyle)
            }

            WorldClocksSettings()
        }
    }

    // MARK: Live preview

    private var preview: some View {
        GeraldinePeriodicTimeline(from: Date(), by: calendar.tickInterval) { date in
            HStack(spacing: Theme.Spacing.lg) {
                ModuleGlyph(systemImage: "calendar", tint: Module.calendar.tint, size: 58)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("POPOVER PREVIEW")
                        .font(.geraldineLabel)
                        .tracking(0.8)
                        .foregroundStyle(Module.calendar.tint)
                    Text(calendar.dateString(for: date))
                        .font(.geraldineTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(calendar.timeString(for: date))
                        .font(.geraldineMetric)
                        .monospacedDigit()
                        .foregroundStyle(Module.calendar.tint)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    previewPill("Month", icon: "calendar", enabled: calendar.showCalendar)
                    previewPill("Week Numbers", icon: "number", enabled: calendar.showWeekNumbers)
                    previewPill("World Clocks", icon: "globe", enabled: calendar.hasVisibleClocks)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calendar popover preview")
            .accessibilityValue("\(calendar.dateString(for: date)), \(calendar.timeString(for: date))")
            .card(padding: Theme.Spacing.xl, tier: .tinted(Module.calendar.tint))
        }
    }

    private func previewPill(_ title: String, icon: String, enabled: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            ContextualSymbol(
                inactive: "circle",
                active: icon,
                isActive: enabled,
                tint: enabled ? Module.calendar.tint : Color.secondary,
                size: 10
            )
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(enabled ? Module.calendar.tint : Color.secondary)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background((enabled ? Module.calendar.tint : Color.secondary).opacity(0.10), in: Capsule())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .buttonStyle(.soft(Module.calendar.tint))
            }

            Toggle("Show World Clocks", isOn: $calendar.showWorldClocks)
            Toggle("Show Day & Night Icons", isOn: $calendar.showDayNightIcons)
                .disabled(!calendar.showWorldClocks)
            Toggle("Time Travel Slider", isOn: $calendar.showTimeTravel)
                .disabled(!calendar.showWorldClocks)
            Text("Drag the slider in the popover to see your time against each zone at any hour.")
                .font(.caption).foregroundStyle(.secondary)

            WorkflowPhaseHost(phase: calendar.clocks.isEmpty) {
                if calendar.clocks.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        ModuleGlyph(systemImage: "globe", tint: Module.calendar.tint, size: 36)
                        Text("No world clocks yet. Add a time zone to see it in the popover.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(Theme.Spacing.sm)
                    .background(Theme.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                } else {
                    clockList
                }
            }
        }
        .card(tier: .raised)
        .sheet(isPresented: $picking) {
            TimeZonePickerSheet(existing: Set(calendar.clocks.map(\.timeZoneID))) { id in
                if let animation = GeraldineMotion.animation(.standard, reduceMotion: reduceMotion) {
                    withAnimation(animation) { calendar.addClock(timeZoneID: id) }
                } else {
                    calendar.addClock(timeZoneID: id)
                }
            }
        }
    }

    private var clockList: some View {
        VStack(spacing: Theme.Spacing.xs) {
            ForEach(calendar.clocks) { clock in
                ClockRow(clock: clock)
            }
        }
    }

    private struct ClockRow: View {
        @EnvironmentObject private var calendar: CalendarSettingsStore
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let clock: WorldClock
        @State private var label: String = ""

        var body: some View {
            HStack(spacing: Theme.Spacing.sm) {
                ModuleGlyph(systemImage: "globe.americas.fill", tint: Module.calendar.tint, size: 34)
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
                        if let animation = GeraldineMotion.animation(.standard, reduceMotion: reduceMotion) {
                            withAnimation(animation) {
                                calendar.removeClocks(at: IndexSet(integer: idx))
                            }
                        } else {
                            calendar.removeClocks(at: IndexSet(integer: idx))
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.quiet(Theme.bad))
                .help("Remove This Clock")
                .accessibilityLabel("Remove \(clock.name)")
            }
            .padding(Theme.Spacing.xs)
            .background(Theme.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
                HStack(spacing: Theme.Spacing.xs) {
                    ModuleGlyph(systemImage: "globe", tint: Module.calendar.tint, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Add Time Zone").font(.geraldineSection)
                        Text("Choose a city for the menu bar popover.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.quiet(Module.calendar.tint))
            }
            .padding(Theme.Spacing.md)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search cities or zones", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.surfaceMuted,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .padding(.horizontal, Theme.Spacing.md)

            List(zones) { zone in
                let isExisting = existing.contains(zone.id)
                Button {
                    onPick(zone.id)
                    dismiss()
                } label: {
                    CareLedgerRow(
                        icon: "globe.americas.fill",
                        tint: Module.calendar.tint,
                        title: zone.city,
                        detail: zone.region.isEmpty ? zone.id : zone.region
                    ) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(isExisting ? "Added" : zone.gmt)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isExisting ? Theme.good : Color.secondary)
                            ContextualSymbol(
                                inactive: "plus.circle",
                                active: "checkmark.circle.fill",
                                isActive: isExisting,
                                tint: isExisting ? Theme.good : Module.calendar.tint,
                                size: 14
                            )
                        }
                    }
                }
                .buttonStyle(.geraldineSelection(Module.calendar.tint,
                                                  isSelected: isExisting,
                                                  cornerRadius: Theme.Radius.control))
                .disabled(isExisting)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityLabel(isExisting ? "\(zone.city), already added" : "Add \(zone.city), \(zone.gmt)")
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 440, height: 520)
        .background(Theme.canvas)
    }
}
