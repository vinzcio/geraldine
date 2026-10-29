import SwiftUI

/// Remaining-usage tile for one coding assistant. Visual treatment follows the
/// Claude Opus spec: muted plate, brand wash, remaining as a ring or unrolled
/// capsule, app icon, and level signaled on the numeral — not by recoloring the
/// track. Small tiles stay chrome-free so a row of four reads as one family.
struct AIUsageWidget: View {
    let identity: AIUsageIdentity
    let size: WidgetSize
    @EnvironmentObject private var usage: AIUsageMonitor
    var body: some View {
        TimelineView(.everyMinute) { context in
            presentation(at: context.date)
        }
        .onAppear { usage.refreshIfStale() }
    }

    /// The live tile and offscreen checks enter through the same presentation.
    func presentation(at now: Date, calendar: Calendar = .autoupdatingCurrent) -> AIUsageTile {
        AIUsageTile(identity: identity, size: size, snapshot: usage.snapshot(for: identity),
                    tileName: usage.tileName(for: identity), displayName: usage.displayName(for: identity),
                    now: now, calendar: calendar)
    }
}

/// One presentation time owns visible reset copy, help, and accessibility. The
/// parent supplies the existing minute cadence; this view never polls usage.
struct AIUsageTile: View {
    let identity: AIUsageIdentity
    let size: WidgetSize
    let snapshot: AIUsageSnapshot
    let tileName: String
    let displayName: String
    let now: Date
    var calendar: Calendar = .autoupdatingCurrent
    @EnvironmentObject private var usage: AIUsageMonitor
    @EnvironmentObject private var state: AppState
    @Environment(\.widgetCustomizationActive) private var customizationActive

    private var provider: AICodingProvider { identity.provider }
    private var bars: [AIUsageWindow] { snapshot.displayWindows }
    private var showsPairedWindows: Bool { snapshot.hasDisplayableUsage && bars.count >= 2 }
    private var usesTimeWindowRows: Bool {
        provider == .claude || (provider == .codex &&
            snapshot.plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "plus")
    }
    private var remaining: Double? { bars.first?.remainingPercent ?? snapshot.remainingPercent }
    /// Large tiles have room beside each label. Narrower tiles reserve a
    /// footer, so a horizontal fit fallback cannot discard every reset.
    private var showsResetPerRow: Bool {
        size == .large && bars.count > 1 && visibleSharedReset == nil
    }

    private func hasVisibleReset(_ window: AIUsageWindow) -> Bool {
        AIUsageResetText.caption(window, now: now, calendar: calendar) != nil
    }

    private func sharedReset(in windows: [AIUsageWindow]) -> AIUsageWindow? {
        guard let first = windows.first, let date = first.resetsAt,
              windows.allSatisfy({ window in
                  guard let other = window.resetsAt, hasVisibleReset(window) else { return false }
                  return abs(other.timeIntervalSince(date)) < 60 && window.resetIsDateOnly == first.resetIsDateOnly
              }) else { return nil }
        return first
    }

    private var visibleSharedReset: AIUsageWindow? { sharedReset(in: bars) }

    /// Prefer the tightest window with a meaningful reset. A missing or stale
    /// headline must not conceal another window's known date.
    private var footerReset: AIUsageWindow? {
        visibleSharedReset ?? bars.filter(hasVisibleReset).min {
            if $0.remainingPercent == $1.remainingPercent { return $0.title < $1.title }
            return $0.remainingPercent < $1.remainingPercent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                switch size {
                case .small:  smallBody
                case .medium: mediumBody
                case .large:  largeBody
                }
            }
            if snapshot.status.isConnected {
                Text(UsageAge.text(snapshot.fetchedAt, now: now))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                if case .error = snapshot.status, snapshot.hasDisplayableUsage {
                    Text("Couldn't refresh").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background { tileBackground }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(snapshot.cachedSourceDescription ?? "")
        .help(helpText)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            tileHeader(nameFont: .caption2.weight(.semibold), markSize: 16)
            Spacer(minLength: 0)
            if snapshot.hasDisplayableUsage {
                dataBlock(percentSize: 22, percentMarkSize: 11)
            } else {
                statusLine
            }
        }
    }

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                tileHeader(nameFont: .caption.weight(.semibold), markSize: 16)
                actionRow
            }
            Spacer(minLength: 0)
            if snapshot.hasDisplayableUsage {
                dataBlock(percentSize: 26, percentMarkSize: 13)
            } else {
                statusLine
            }
        }
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                tileHeader(nameFont: .caption.weight(.semibold), markSize: 16)
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                actionRow
            }
            if snapshot.hasDisplayableUsage {
                dataBlock(percentSize: 26, percentMarkSize: 13)
            } else {
                statusLine
            }
        }
    }

    private func tileHeader(nameFont: Font, markSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            CodingAssistantMark(provider: provider, size: markSize)
            Text(tileName)
                .font(nameFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            statusGlyph
        }
    }

    @ViewBuilder
    private func dataBlock(percentSize: CGFloat, percentMarkSize: CGFloat) -> some View {
        if provider == .antigravity {
            antigravityQuotas
        } else if usesTimeWindowRows {
            if size == .large {
                withResetFooter { timeWindowRows(compact: false) }
            } else {
                // Keep the reset in both fits; compact rows preserve every quota.
                ViewThatFits(in: .vertical) {
                    withResetFooter { timeWindowRows(compact: false) }
                    withResetFooter { timeWindowRows(compact: true) }
                }
                .animation(nil, value: bars.count)
            }
        } else if showsPairedWindows {
            withResetFooter { pairedWindows }
        } else {
            remainingHeadline(percent: remaining, percentSize: percentSize, percentMarkSize: percentMarkSize)
            UsageRemainingBar(remaining: remaining, tint: provider.tint, height: 4)
            if let window = footerReset {
                resetFooter(window)
            }
        }
    }

    private var pairedWindows: some View {
        VStack(spacing: 8) {
            ForEach(bars.prefix(2)) { window in
                equalWindow(window)
            }
        }
    }

    @ViewBuilder
    private func withResetFooter<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if !showsResetPerRow, let window = footerReset {
            VStack(alignment: .leading, spacing: 5) {
                content()
                resetFooter(window)
            }
        } else {
            content()
        }
    }

    /// "Resets in 4d 10h". A small tile with several rows names the window:
    /// "5h resets in 2h 14m".
    private func resetFooter(_ window: AIUsageWindow) -> some View {
        let subject = visibleSharedReset == nil && bars.count > 1 ? resetSubject(window) : nil
        let style = subject.map { AIUsageResetText.CaptionStyle.summary(subject: $0) } ?? .standalone
        return UsageResetLabel(window: window, now: now, calendar: calendar, font: .system(size: 10), style: style)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row label followed by its own reset, when the tile is wide enough.
    private func labelWithReset(_ label: Text, window: AIUsageWindow, font: Font, showReset: Bool? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            if showReset ?? showsResetPerRow, hasVisibleReset(window) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    label.lineLimit(1).fixedSize()
                    UsageResetLabel(window: window, now: now, calendar: calendar, font: font, style: .inline)
                        .fixedSize()
                }
            }
            label.lineLimit(1).minimumScaleFactor(0.85)
        }
    }

    // Opus design: compact typography/spacing only; quota bars remain 4pt.
    private func timeWindowRows(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 8) {
            ForEach(bars) { window in
                VStack(spacing: compact ? 2 : 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        labelWithReset(
                            Text(timeWindowLabel(window, abbreviated: size == .small))
                                .font(.system(size: compact ? 10 : 11))
                                .foregroundStyle(.secondary),
                            window: window,
                            font: .system(size: compact ? 10 : 11)
                        )
                        Spacer(minLength: 0)
                        Text("\(Int(window.remainingPercent.rounded()))%")
                            .font(.system(size: compact ? 12 : 16, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .fixedSize()
                    }
                    .frame(height: compact ? 15 : 19)
                    UsageRemainingBar(remaining: window.remainingPercent, tint: provider.tint, height: 4)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func timeWindowLabel(_ window: AIUsageWindow, abbreviated: Bool) -> String {
        if provider == .claude {
            if window.id == "five_hour" { return abbreviated ? "5h" : "5-hour session" }
            if window.id == "seven_day" { return abbreviated ? "Week · All" : "Weekly · All models" }
            if window.title == "Fable" { return abbreviated ? "Week · Fable" : "Weekly · Fable" }
        }
        if provider == .codex {
            if window.durationSeconds == 18_000 { return abbreviated ? "5h" : "5-hour session" }
            if window.durationSeconds == 604_800 { return abbreviated ? "Week" : "Weekly" }
        }
        return window.title
    }

    /// Short subject for a small tile's single reset line.
    private func resetSubject(_ window: AIUsageWindow) -> String {
        if provider == .claude {
            if window.id == "five_hour" { return "5h" }
            if window.id == "seven_day" { return "All" }
        }
        if window.durationSeconds == 18_000 { return "5h" }
        if window.durationSeconds == 604_800 { return "Weekly" }
        return shortLabel(window)
    }

    var helpText: String {
        snapshot.hasDisplayableUsage && !bars.isEmpty
            ? quotaTooltip : (snapshot.cachedSourceDescription ?? accessibilityText)
    }

    private var quotaTooltip: String {
        var lines = [displayName]
        for window in bars {
            var line = "\(timeWindowLabel(window, abbreviated: false)) · \(Int(window.remainingPercent.rounded()))% left"
            if let reset = AIUsageResetText.detail(window, now: now, calendar: calendar) { line += " · " + reset }
            lines.append(line)
        }
        if let source = snapshot.cachedSourceDescription { lines.append(source) }
        // The tile keeps a failed check's last values; say why and how old they are.
        if case .error(let message) = snapshot.status {
            lines.append("Last check failed: " + message)
            if let fetchedAt = snapshot.fetchedAt { lines.append("Showing values from \(fetchTime(fetchedAt)).") }
        }
        return lines.joined(separator: "\n")
    }

    /// "6:47 PM" today, "Oct 13, 6:47 PM" on an earlier day.
    private func fetchTime(_ date: Date) -> String {
        guard calendar.isDate(date, inSameDayAs: now) else {
            return AIUsageResetText.absolute(date, now: now, calendar: calendar)
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                               locale: calendar.locale ?? .autoupdatingCurrent,
                                               calendar: calendar, timeZone: calendar.timeZone))
    }

    private var antigravityQuotas: some View {
        VStack(alignment: .leading, spacing: size == .small ? 3 : 5) {
            quotaGroup("Gemini", ids: ["gemini-weekly", "gemini-5h"])
            quotaGroup("Claude / GPT", ids: ["3p-weekly", "3p-5h"])
            if size == .small, let shared = visibleSharedReset {
                UsageResetLabel(window: shared, now: now, calendar: calendar, font: .system(size: 10))
            }
        }
    }

    private func quotaGroup(_ title: String, ids: [String]) -> some View {
        let rows = bars.filter { ids.contains($0.id) }
        let shared = sharedReset(in: rows)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if size != .small, let shared {
                    UsageResetLabel(window: shared, now: now, calendar: calendar, font: .system(size: 10))
                }
            }
            ForEach(rows) { window in
                HStack(spacing: 3) {
                    labelWithReset(
                        Text(window.id.hasSuffix("weekly") ? "Weekly" : "5-hour")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary),
                        window: window,
                        font: .system(size: 10),
                        showReset: size != .small && shared == nil
                    )
                    Spacer(minLength: 0)
                    UsageRemainingBar(remaining: window.remainingPercent, tint: provider.tint, height: 3)
                        .frame(width: size == .small ? 18 : 48)
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .help([window.title, AIUsageResetText.detail(window, now: now, calendar: calendar)]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            // At 146pt the selected group's own footer supplies attribution.
            // Keep all four percentages and bars, without tiny type or clipping.
            if size == .small, visibleSharedReset == nil,
               let reset = footerReset, ids.contains(reset.id) {
                let style: AIUsageResetText.CaptionStyle = shared == nil
                    ? .summary(subject: reset.id.hasSuffix("weekly") ? "Weekly" : "5h") : .standalone
                UsageResetLabel(window: reset, now: now, calendar: calendar, font: .system(size: 10), style: style)
            }
        }
    }

    private func remainingHeadline(percent: Double?, percentSize: CGFloat, percentMarkSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(percent.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.rounded(percentSize, .semibold))
                .foregroundStyle(UsageRemainingRing.numeralColor(for: percent))
                .monospacedDigit()
            if percent != nil {
                Text("%")
                    .font(.rounded(percentMarkSize, .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func equalWindow(_ window: AIUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                labelWithReset(
                    Text(shortLabel(window))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary),
                    window: window,
                    font: .caption2
                )
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(window.remainingPercent.rounded()))")
                        .font(.rounded(16, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UsageRemainingRing.numeralColor(for: window.remainingPercent))
                    Text("%")
                        .font(.rounded(10, .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            UsageRemainingBar(remaining: window.remainingPercent, tint: provider.tint, height: 4)
        }
    }

    @ViewBuilder private var statusLine: some View {
        let compact = size == .small
        switch snapshot.status {
        case .disconnected:
            Text("Usage hidden")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .needsSignIn:
            Text(compact ? "Unavailable" : provider.usageUnavailableHint)
                .font(.caption2)
                .foregroundStyle(Theme.warn)
                .lineLimit(compact ? 1 : 2)
        case .loading:
            Text(compact ? "Updating…" : "Updating remaining usage…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .ready:
            if let window = snapshot.headline {
                Text(AIUsageResetText.caption(window, now: now, calendar: calendar) ?? "Remaining usage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .error(let message):
            Text(compact ? "Unavailable" : message)
                .font(.caption2)
                .foregroundStyle(Theme.bad)
                .lineLimit(compact ? 1 : 2)
        }
    }

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 8) {
            switch snapshot.status {
            case .disconnected:
                button("Show Usage") { connect() }
            case .needsSignIn:
                button("Retry") { usage.connect(identity) }
            case .loading:
                ProgressView().controlSize(.mini)
            case .ready:
                Button(action: { usage.connect(identity) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.quiet(Theme.accent, compact: true))
                .help("Refresh remaining usage")
            case .error:
                button("Refresh") { usage.connect(identity) }
            }
            Spacer(minLength: 0)
        }
    }

    private func shortLabel(_ window: AIUsageWindow) -> String {
        let id = window.id.lowercased()
        if id == "seven_day" { return "All" }
        if id == "autopercentused" { return "Models" }
        if id == "apipercentused" { return "Other" }
        if id.contains("fable") || id == "seven_day_overage_included" { return "Fable" }
        if window.title.lowercased().contains("fable") { return "Fable" }
        return window.title
    }

    @ViewBuilder private var statusGlyph: some View {
        switch snapshot.status {
        case .loading:
            ProgressView().controlSize(.mini)
        case .needsSignIn, .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Chart.amber)
        default:
            EmptyView()
        }
    }

    private var tileBackground: some View {
        let connected = snapshot.status == .ready
        return RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.surfaceMuted)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                provider.tint.opacity(connected ? 0.06 : 0.03),
                                provider.tint.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.surfaceRaised.opacity(0.6), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(customizationActive ? Theme.accent.opacity(0.24) : provider.tint.opacity(0.14),
                                  lineWidth: 1)
            )
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.quiet(Theme.accent, compact: true))
    }

    private func connect() {
        state.connectAIUsage(identity)
    }

    var accessibilityText: String {
        let name = displayName
        let status: String
        switch snapshot.status {
        case .disconnected: status = "hidden"
        case .needsSignIn: status = "unavailable"
        case .loading: status = "updating"
        case .ready: status = ""
        case .error(let message): status = "error, " + message
        }
        var parts = ["\(name) usage"]
        if !status.isEmpty { parts.append(status) }
        if snapshot.hasDisplayableUsage {
            for window in bars {
                var text = "\(timeWindowLabel(window, abbreviated: false)), \(Int(window.remainingPercent.rounded())) percent left"
                if let reset = AIUsageResetText.detail(window, now: now, calendar: calendar) { text += ", " + reset }
                parts.append(text)
            }
        }
        if snapshot.status.isConnected { parts.append(UsageAge.text(snapshot.fetchedAt, now: now)) }
        return parts.joined(separator: ", ")
    }

}

struct CodingAssistantMark: View {
    let provider: AICodingProvider
    var size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.surfaceRaised)
                // Grok's mark is white, like its app icon. Its chip keeps the
                // dark surface in light mode too; on the white one it vanished.
                .environment(\.colorScheme, provider == .grok ? .dark : colorScheme)
            if provider == .grok {
                GrokGShape()
                    .fill(Color(red: 252 / 255, green: 252 / 255, blue: 252 / 255))
                    .frame(width: size * 0.62, height: size * 0.62)
            } else if let icon = provider.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: provider.systemImage)
                    .font(.system(size: max(9, size * 0.62), weight: .semibold))
                    .foregroundStyle(provider.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

struct UsageRemainingBar: View {
    var remaining: Double?
    var tint: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat((remaining ?? 0) / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                if let remaining, remaining > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * fraction)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct UsageRemainingRing: View {
    var remaining: Double?
    var tint: Color
    var lineWidth: CGFloat
    var percentFont: CGFloat
    var showsCaption: Bool
    var showsPercentSign: Bool = true
    var isLoading: Bool = false

    var body: some View {
        let progress = CGFloat((remaining ?? 0) / 100)
        ZStack {
            Circle()
                .stroke(tint.opacity(remaining == nil ? 0.10 : 0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining == nil ? 0 : max(0.02, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(centerTitle)
                    .font(.rounded(percentFont, .semibold))
                    .foregroundStyle(Self.numeralColor(for: remaining))
                    .monospacedDigit()
                if showsCaption {
                    Text("left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var centerTitle: String {
        guard let remaining else { return "—" }
        if showsPercentSign {
            return "\(Int(remaining.rounded()))%"
        }
        return "\(Int(remaining.rounded()))"
    }

    static func numeralColor(for remaining: Double?) -> Color {
        guard let remaining else { return Color.secondary }
        switch remaining {
        case 20...: return Color.primary
        case 8..<20: return Theme.Chart.amber
        default: return Theme.Chart.red
        }
    }

    /// Settings and older call sites color a remaining-percent label. The
    /// track itself stays on the provider tint; only the numeral shifts.
    static func tint(for remaining: Double?, brand: Color) -> Color {
        numeralColor(for: remaining) == Color.primary ? brand : numeralColor(for: remaining)
    }
}
