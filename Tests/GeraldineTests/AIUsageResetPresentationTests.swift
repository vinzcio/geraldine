import SwiftUI
import XCTest
@testable import Geraldine

@MainActor
final class AIUsageResetPresentationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
    }

    func testEachCaptionStyleKeepsItsExistingCopy() {
        let window = AIUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 12,
                                   resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60))
        let cases: [(AIUsageResetText.CaptionStyle, String)] = [
            (.standalone, "Resets in 2h 14m"),
            (.summary(subject: "5h"), "5h resets in 2h 14m"),
            (.clause, "resets in 2h 14m"),
            (.inline, "· resets in 2h 14m"),
            (.countdown, "in 2h 14m")
        ]
        for (style, expected) in cases {
            XCTAssertEqual(AIUsageResetText.caption(window, style: style, now: now, calendar: calendar), expected)
            var expired = window
            expired.resetsAt = now
            XCTAssertNil(AIUsageResetText.caption(expired, style: style, now: now, calendar: calendar))
        }
    }

    func testSettingsUsesAbsoluteCopyWhileTooltipKeepsCountdownAndDate() throws {
        let window = AIUsageWindow(id: "pool", title: "Pool", usedPercent: 12,
                                   resetsAt: now.addingTimeInterval(27 * 3600))
        let settings = try XCTUnwrap(AIUsageResetText.detail(window, style: .absolute, now: now, calendar: calendar))
        XCTAssertTrue(settings.hasPrefix("resets Oct 13"), settings)
        XCTAssertTrue(settings.contains("3:00"), settings)
        XCTAssertFalse(settings.contains("in "), settings)
        let tooltip = try XCTUnwrap(AIUsageResetText.detail(window, now: now, calendar: calendar))
        XCTAssertTrue(tooltip.hasPrefix("resets in 1d 3h (Oct 13"), tooltip)

        var dateOnly = window
        dateOnly.resetsAt = calendar.startOfDay(for: now)
        dateOnly.resetIsDateOnly = true
        XCTAssertEqual(AIUsageResetText.caption(dateOnly, now: now, calendar: calendar), "Resets today")
        XCTAssertEqual(AIUsageResetText.detail(dateOnly, style: .absolute, now: now, calendar: calendar), "resets Oct 12")
        XCTAssertEqual(AIUsageResetText.detail(dateOnly, now: now, calendar: calendar), "resets Oct 12")
        XCTAssertNil(AIUsageResetText.detail(dateOnly, style: .absolute,
                                            now: now.addingTimeInterval(86_400), calendar: calendar))
    }

    func testActualLabelContentDisappearsAtExpiryAndKeepsDateOnlyUntilTomorrow() throws {
        var window = AIUsageWindow(id: "pool", title: "Pool", usedPercent: 12, resetsAt: now)
        let empty = try pixels(window: .init(id: "unknown", title: "Unknown", usedPercent: 12), at: now)
        // ImageRenderer can vary antialiased text edges by one 8-bit channel
        // level even for identical empty-label content. Visible copy differs more.
        XCTAssertLessThanOrEqual(try difference(pixels(window: window, at: now), empty), 1)
        XCTAssertGreaterThan(try difference(pixels(window: window, at: now.addingTimeInterval(-60)), empty), 1)

        window.resetsAt = calendar.startOfDay(for: now)
        window.resetIsDateOnly = true
        XCTAssertGreaterThan(try difference(pixels(window: window, at: now), empty), 1)
        XCTAssertLessThanOrEqual(try difference(pixels(window: window, at: now.addingTimeInterval(86_400)), empty), 1)
    }

    func testTileHelpAndVoiceOverFollowTheInjectedMinuteAndExpiry() {
        let window = AIUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 12,
                                   resetsAt: now.addingTimeInterval(120))
        let snapshot = AIUsageSnapshot(provider: .claude, status: .ready, plan: nil,
                                       windows: [window], fetchedAt: now, sourceLabel: nil,
                                       accountEmail: "client@example.com")
        for (offset, countdown) in [(0.0, "in 2m"), (60.0, "in 1m"), (120.0, "")] {
            let tile = AIUsageTile(identity: .init(.claude, accountKey: "client"), size: .small,
                                  snapshot: snapshot, tileName: "Client", displayName: "Claude · Client",
                                  now: now.addingTimeInterval(offset), calendar: calendar)
            for text in [tile.helpText, tile.accessibilityText] {
                XCTAssertTrue(text.contains("Claude · Client"), text)
                if countdown.isEmpty {
                    XCTAssertFalse(text.contains("resets"), text)
                } else {
                    XCTAssertTrue(text.contains("resets " + countdown), text)
                }
            }
        }
    }

    func testRefreshPreservesAccountAndDescribesRetainedWindows() {
        let window = AIUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 12,
                                   resetsAt: now.addingTimeInterval(120))
        let ready = AIUsageSnapshot(provider: .claude, status: .ready, plan: "Team",
                                   windows: [window], fetchedAt: now, sourceLabel: ClaudeUsageCache.sourceLabel,
                                   accountEmail: "client@example.com")
        for snapshot in [AIUsageSnapshot.loading(.claude, preserving: ready),
                         AIUsageSnapshot.failed(.claude, message: "Offline", preserving: ready)] {
            XCTAssertEqual(snapshot.accountEmail, ready.accountEmail)
            XCTAssertEqual(snapshot.windows, ready.windows)
            XCTAssertEqual(snapshot.fetchedAt, ready.fetchedAt)
            XCTAssertEqual(snapshot.sourceLabel, ready.sourceLabel)
            for offset in [60.0, 120.0] {
                let tile = AIUsageTile(identity: .init(.claude, accountKey: "client"), size: .small,
                                      snapshot: snapshot, tileName: "Client", displayName: "Claude · Client",
                                      now: now.addingTimeInterval(offset), calendar: calendar)
                for text in [tile.helpText, tile.accessibilityText] {
                    XCTAssertTrue(text.contains("Claude · Client"), text)
                    XCTAssertTrue(text.contains("88"), text)
                    XCTAssertEqual(text.contains("resets in 1m"), offset == 60, text)
                }
                XCTAssertTrue(tile.accessibilityText.contains(snapshot.status == .loading ? "updating" : "Offline"))
            }
        }
    }

    func testRenderedTileAndMetadataExpireTogetherAtMinuteAndDayBoundaries() throws {
        for dateOnly in [false, true] {
            let date = dateOnly ? calendar.startOfDay(for: now) : now.addingTimeInterval(120)
            let window = AIUsageWindow(id: "five_hour", title: "5-hour", usedPercent: 12,
                                       resetsAt: date, resetIsDateOnly: dateOnly)
            let snapshot = AIUsageSnapshot(provider: .claude, status: .ready, plan: nil,
                                           windows: [window], fetchedAt: now, sourceLabel: nil)
            var unknown = snapshot
            unknown.windows[0].resetsAt = nil
            let offsets = dateOnly ? [0.0, 86_400.0] : [0.0, 60.0, 120.0]
            for size in WidgetSize.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    var previous: Data?
                    for offset in offsets {
                        let time = now.addingTimeInterval(offset)
                        let tile = AIUsageTile(identity: .init(.claude, accountKey: "client"), size: size,
                                              snapshot: snapshot, tileName: "Client", displayName: "Claude · Client",
                                              now: time, calendar: calendar)
                        let actual = try tilePixels(tile, scheme: scheme)
                        let empty = try tilePixels(AIUsageTile(identity: tile.identity, size: size, snapshot: unknown,
                                                              tileName: "Client", displayName: "Claude · Client",
                                                              now: time, calendar: calendar), scheme: scheme)
                        let visible = offset < (dateOnly ? 86_400 : 120)
                        XCTAssertEqual(difference(actual, empty) > 1, visible)
                        XCTAssertEqual(tile.helpText.contains("resets"), visible)
                        XCTAssertEqual(tile.accessibilityText.contains("resets"), visible)
                        if let previous, !dateOnly { XCTAssertGreaterThan(difference(previous, actual), 1) }
                        previous = actual
                    }
                }
            }
        }
    }

    private func tilePixels(_ tile: AIUsageTile, scheme: ColorScheme) throws -> Data {
        let width = CGFloat(tile.size.span) * 146 + CGFloat(tile.size.span - 1) * 8
        let view = tile.frame(width: width, height: 132)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func difference(_ lhs: Data, _ rhs: Data) -> Int {
        XCTAssertEqual(lhs.count, rhs.count)
        return zip(lhs, rhs).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    private func pixels(window: AIUsageWindow, at date: Date) throws -> Data {
        let label = UsageResetLabel(window: window, now: date, font: .system(size: 10), style: .inline)
        let view = HStack {
            Text("Usage")
            label.content(at: date, calendar: calendar)
        }
        .frame(width: 300, height: 40)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.bitsPerComponent, 8)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }
}
