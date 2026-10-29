import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Geraldine

/// Opt-in offscreen verification of the actual usage tiles, with synthetic homes
/// and fetch results. AI_USAGE_RENDER_DIR must name an owned evidence directory.
@MainActor
final class AIUsageWidgetSnapshotRenderTests: XCTestCase {
    func testRenderEveryProviderAndSize() async throws {
        guard let path = ProcessInfo.processInfo.environment["AI_USAGE_RENDER_DIR"] else {
            throw XCTSkip("Set AI_USAGE_RENDER_DIR to render synthetic usage tiles offscreen")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let home = output.appendingPathComponent("synthetic-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_791_806_400)
        var observations: [String: [String]] = [:]
        for (name, fixture) in fixtures(now: now) {
            let suite = "AIUsageWidgetSnapshotRenderTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let monitor = AIUsageMonitor(defaults: defaults, now: { now }, userHome: home) { _, _ in fixture }
            defer { monitor.stop() }
            let identity = AIUsageIdentity(fixture.provider)
            let tileName = name == "claude-client-refresh" ? "Client" : fixture.provider.title
            let displayName = name == "claude-client-refresh" ? "Claude · Client" : fixture.provider.title
            monitor.connect(identity)
            for await snapshots in monitor.$snapshots.values {
                if snapshots[identity] == fixture { break }
            }
            // Settings is another usage surface: it must keep numbers on errors
            // and show their age without running a provider or opening a window.
            let settings = ImageRenderer(content: AIUsageConnectionRow(identity: identity)
                .environmentObject(monitor).frame(width: 640).padding(12))
            settings.scale = 2
            let settingsImage = NSBitmapImageRep(cgImage: try XCTUnwrap(settings.cgImage))
            try XCTUnwrap(settingsImage.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("settings-\(name).png"))
            for size in WidgetSize.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let gridWidth: CGFloat = 608
                    let track = (gridWidth - 3 * WidgetGridMetrics.spacing) / 4
                    let width = track * CGFloat(size.span) + WidgetGridMetrics.spacing * CGFloat(size.span - 1)
                    func content(_ snapshot: AIUsageSnapshot) -> some View {
                        AIUsageTile(identity: identity, size: size, snapshot: snapshot,
                                           tileName: tileName, displayName: displayName, now: now)
                        .environmentObject(monitor)
                        .environment(\.colorScheme, scheme)
                        .frame(width: width)
                        .frame(minHeight: WidgetGridMetrics.unitHeight)
                        .frame(height: size == .large ? nil : WidgetGridMetrics.unitHeight)
                        .padding(12)
                        .background(scheme == .dark ? Color.black : Color.white)
                    }
                    let view = content(fixture)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let cgImage = try XCTUnwrap(renderer.cgImage)
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    XCTAssertEqual(CGFloat(cgImage.width) / renderer.scale, width + 24)
                    let filename = "\(name)-\(size.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                    try png.write(to: output.appendingPathComponent(filename))
                    var withoutResets = fixture
                    for index in withoutResets.windows.indices { withoutResets.windows[index].resetsAt = nil }
                    let comparison = ImageRenderer(content: content(withoutResets))
                    comparison.scale = 2
                    let emptyImage = try XCTUnwrap(comparison.cgImage)
                    let actual = try XCTUnwrap(cgImage.dataProvider?.data) as Data
                    let empty = try XCTUnwrap(emptyImage.dataProvider?.data) as Data
                    let hasReset = fixture.displayWindows.contains { AIUsageResetText.caption($0, now: now) != nil }
                    let different = actual.count != empty.count || zip(actual, empty).contains { abs(Int($0) - Int($1)) > 1 }
                    XCTAssertEqual(different, hasReset, "Reset must affect the rendered tile in \(filename)")
                    let tile = AIUsageTile(identity: identity, size: size, snapshot: fixture,
                                           tileName: tileName, displayName: displayName, now: now)
                    observations[filename] = [tile.helpText, tile.accessibilityText]

                }
            }
        }
        try JSONEncoder().encode(observations).write(to: output.appendingPathComponent("metadata.json"))
    }

    private func fixtures(now: Date) -> [(String, AIUsageSnapshot)] {
        func window(_ id: String, _ title: String, _ used: Double, _ hours: Double?,
                    duration: TimeInterval? = nil, dateOnly: Bool = false) -> AIUsageWindow {
            .init(id: id, title: title, usedPercent: used,
                  resetsAt: hours.map { now.addingTimeInterval($0 * 3600) },
                  durationSeconds: duration, resetIsDateOnly: dateOnly)
        }
        func snapshot(_ provider: AICodingProvider, _ windows: [AIUsageWindow],
                      plan: String? = nil) -> AIUsageSnapshot {
            .init(provider: provider, status: .ready, plan: plan, windows: windows,
                  fetchedAt: now, sourceLabel: nil)
        }
        return [
            ("claude", snapshot(.claude, [window("seven_day", "All models", 28, 106),
                                         window("seven_day_fable", "Fable", 18, 107),
                                         window("five_hour", "5-hour", 54, 4)])),
            ("codex-plus", snapshot(.codex, [window("primary", "Session", 42, 3, duration: 18_000),
                                             window("secondary", "Weekly", 61, 96, duration: 604_800)], plan: "Plus")),
            ("codex-pool", snapshot(.codex, [window("primary", "Session", 42, 3)], plan: "Pro")),
            ("cursor-shared-day", snapshot(.cursor, [window("autoPercentUsed", "Cursor models", 33, 72, dateOnly: true),
                                                      window("apiPercentUsed", "Other models", 100, 72, dateOnly: true)])),
            ("grok", snapshot(.grok, [window("pool", "Weekly", 22, 70)])),
            ("antigravity", snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 45, 106),
                                                    window("gemini-5h", "Gemini 5-hour", 70, 4),
                                                    window("3p-weekly", "Claude / GPT weekly", 65, 90),
                                                    window("3p-5h", "Claude / GPT 5-hour", 40, 3)])),
            ("claude-shared", snapshot(.claude, [window("seven_day", "All models", 28, 4),
                                                window("seven_day_fable", "Fable", 18, 4),
                                                window("five_hour", "5-hour", 54, 4)])),
            ("claude-single", snapshot(.claude, [window("five_hour", "5-hour", 54, 4)])),
            ("claude-known-after-missing", snapshot(.claude, [window("seven_day", "All models", 80, nil),
                                                             window("seven_day_fable", "Fable", 70, -1),
                                                             window("five_hour", "5-hour", 20, 3)])),
            ("claude-date-only", snapshot(.claude, [window("seven_day", "All models", 28, 72, dateOnly: true),
                                                   window("seven_day_fable", "Fable", 18, 72, dateOnly: true),
                                                   window("five_hour", "5-hour", 54, nil)])),
            ("codex-plus-shared", snapshot(.codex, [window("primary", "Session", 42, 3, duration: 18_000),
                                                    window("secondary", "Weekly", 61, 3, duration: 604_800)], plan: "Plus")),
            ("codex-plus-single", snapshot(.codex, [window("primary", "Session", 42, 3, duration: 18_000)], plan: "Plus")),
            ("antigravity-shared", snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 45, 106),
                                                           window("gemini-5h", "Gemini 5-hour", 70, 106),
                                                           window("3p-weekly", "Claude / GPT weekly", 65, 106),
                                                           window("3p-5h", "Claude / GPT 5-hour", 40, 106)])),
            ("antigravity-group-shared-day", snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 45, 72, dateOnly: true),
                                                                     window("gemini-5h", "Gemini 5-hour", 70, 72, dateOnly: true),
                                                                     window("3p-weekly", "Claude / GPT weekly", 65, 48, dateOnly: true),
                                                                     window("3p-5h", "Claude / GPT 5-hour", 40, 48, dateOnly: true)])),
            ("antigravity-known-after-stale", snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 45, -1),
                                                                     window("gemini-5h", "Gemini 5-hour", 70, nil),
                                                                     window("3p-weekly", "Claude / GPT weekly", 65, -1),
                                                                     window("3p-5h", "Claude / GPT 5-hour", 40, 2)])),
            // A spent Claude/GPT weekly limit turns that group's 5-hour limit off.
            ("antigravity-weekly-spent", snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 0, 160),
                                                                 window("gemini-5h", "Gemini 5-hour", 0, 4.6),
                                                                 window("3p-weekly", "Claude / GPT weekly", 100, 49)])),
            ("antigravity-kept-after-failure", AIUsageSnapshot.failed(.antigravity,
                message: "Antigravity's server is unavailable (HTTP 503).",
                preserving: snapshot(.antigravity, [window("gemini-weekly", "Gemini weekly", 0, 160),
                                                    window("gemini-5h", "Gemini 5-hour", 0, 4.6),
                                                    window("3p-weekly", "Claude / GPT weekly", 100, 49)]))),
            ("claude-client-refresh", AIUsageSnapshot.loading(.claude, preserving: snapshot(.claude,
                [window("seven_day", "All models", 28, 106), window("seven_day_fable", "Fable", 18, 107),
                 window("five_hour", "5-hour", 54, 4)], plan: "Team"))),
            ("claude-stale-missing", snapshot(.claude, [window("seven_day", "All models", 28, -1),
                                                        window("five_hour", "5-hour", 54, nil)]))
        ]
    }
}
