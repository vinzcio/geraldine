import SwiftUI

/// Remaining-usage tile for one coding assistant. Visual treatment follows the
/// Claude Opus spec: muted plate, brand wash, remaining as a ring or unrolled
/// capsule, app icon, and level signaled on the numeral — not by recoloring the
/// track. Small tiles stay chrome-free so a row of four reads as one family.
struct AIUsageWidget: View {
    let provider: AICodingProvider
    let size: WidgetSize
    @EnvironmentObject private var usage: AIUsageMonitor
    @EnvironmentObject private var state: AppState
    @Environment(\.widgetCustomizationActive) private var customizationActive

    private var snapshot: AIUsageSnapshot { usage.snapshot(for: provider) }
    private var bars: [AIUsageWindow] { snapshot.displayWindows }
    private var showsPairedWindows: Bool { snapshot.status == .ready && bars.count >= 2 }
    private var remaining: Double? { bars.first?.remainingPercent ?? snapshot.remainingPercent }

    var body: some View {
        Group {
            switch size {
            case .small:  smallBody
            case .medium: mediumBody
            case .large:  largeBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background { tileBackground }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(snapshot.cachedSourceDescription ?? "")
        .help(snapshot.cachedSourceDescription ?? accessibilityText)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            tileHeader(nameFont: .caption2.weight(.semibold), markSize: 16)
            Spacer(minLength: 0)
            if snapshot.status == .ready {
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
            if snapshot.status == .ready {
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
            if snapshot.status == .ready {
                dataBlock(percentSize: 26, percentMarkSize: 13)
            } else {
                statusLine
            }
        }
    }

    private func tileHeader(nameFont: Font, markSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            CodingAssistantMark(provider: provider, size: markSize)
            Text(provider.title)
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
        } else if showsPairedWindows {
            VStack(spacing: 8) {
                ForEach(bars.prefix(2)) { window in
                    equalWindow(window)
                }
            }
        } else {
            remainingHeadline(percent: remaining, percentSize: percentSize, percentMarkSize: percentMarkSize)
            UsageRemainingBar(remaining: remaining, tint: provider.tint, height: 4)
        }
    }

    private var antigravityQuotas: some View {
        VStack(alignment: .leading, spacing: 5) {
            quotaGroup("Gemini", ids: ["gemini-weekly", "gemini-5h"])
            quotaGroup("Claude / GPT", ids: ["3p-weekly", "3p-5h"])
        }
    }

    private func quotaGroup(_ title: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(bars.filter { ids.contains($0.id) }) { window in
                HStack(spacing: 3) {
                    Text(window.id.hasSuffix("weekly") ? "Weekly" : "5-hour")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    UsageRemainingBar(remaining: window.remainingPercent, tint: provider.tint, height: 3)
                        .frame(width: size == .small ? 18 : 48)
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .help(window.title + " · " + resetCopy(window.resetsAt))
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
                Text(shortLabel(window))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                Text(resetCopy(window.resetsAt))
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
                button("Retry") { usage.connect(provider) }
            case .loading:
                ProgressView().controlSize(.mini)
            case .ready:
                Button(action: { usage.connect(provider) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.quiet(Theme.accent, compact: true))
                .help("Refresh remaining usage")
            case .error:
                button("Refresh") { usage.connect(provider) }
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
        state.connectAIUsage(provider)
    }

    private var accessibilityText: String {
        let name = provider.title
        switch snapshot.status {
        case .disconnected:
            return "\(name) usage, hidden"
        case .needsSignIn:
            return "\(name) usage, unavailable"
        case .loading:
            return "\(name) usage, updating"
        case .ready:
            if showsPairedWindows {
                let parts = (provider == .antigravity ? bars : Array(bars.prefix(2))).map { window in
                    "\(shortLabel(window)) \(Int(window.remainingPercent.rounded())) percent"
                }
                return "\(name) " + parts.joined(separator: ", ")
            }
            if let remaining {
                return "\(name) remaining \(Int(remaining.rounded())) percent"
            }
            return "\(name) usage"
        case .error(let message):
            return "\(name) usage error, \(message)"
        }
    }

    private func resetCopy(_ date: Date?) -> String {
        guard let date else { return "Remaining usage" }
        return "Resets \(Self.resetFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private static let resetFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct CodingAssistantMark: View {
    let provider: AICodingProvider
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.surfaceRaised)
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
