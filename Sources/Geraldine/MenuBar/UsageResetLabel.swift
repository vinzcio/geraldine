import SwiftUI

/// Reset copy at the tile's presentation time. The parent owns the minute
/// cadence, so visible and assistive text expire together.
struct UsageResetLabel: View {
    let window: AIUsageWindow
    let now: Date
    var calendar: Calendar = .autoupdatingCurrent
    var font: Font
    var style: AIUsageResetText.CaptionStyle = .standalone

    var body: some View {
        content(at: now, calendar: calendar)
    }

    /// The same content used by the tile, with an explicit clock for
    /// deterministic offscreen verification of expiry and date-only resets.
    @ViewBuilder
    func content(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> some View {
        if let copy = AIUsageResetText.caption(window, style: style, now: date, calendar: calendar) {
            Text(copy)
                .font(font.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)

        }
    }
}
