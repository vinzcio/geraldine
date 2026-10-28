import AppKit
import SwiftUI
import XCTest
@testable import Geraldine

/// Opt-in native surface checks. Windows stay outside all screens and are never made
/// key; all account/process data is synthetic. FEATURE_SURFACE_DIR must name
/// a task-owned output directory.
@MainActor
final class FeatureSurfaceTests: XCTestCase {
    private var output: URL {
        get throws {
            guard let path = ProcessInfo.processInfo.environment["FEATURE_SURFACE_DIR"] else {
                throw XCTSkip("Set FEATURE_SURFACE_DIR for background native UI checks")
            }
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func testCodingUsageStatesAndActions() throws {
        let directory = try output
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let snapshot = AIUsageSnapshot(provider: .claude, status: .ready, plan: "Example plan",
            windows: [
                AIUsageWindow(id: "week", title: "Weekly allowance", usedPercent: 40, resetsAt: now.addingTimeInterval(86400)),
                AIUsageWindow(id: "session", title: "Five-hour allowance", usedPercent: 75, resetsAt: nil),
                AIUsageWindow(id: "extra", title: "Additional provider window", usedPercent: 10,
                              resetsAt: now.addingTimeInterval(172800), resetIsDateOnly: true)
            ], fetchedAt: now, sourceLabel: "Example CLI", accountEmail: "person@example.com")
        for scheme in [ColorScheme.light, .dark] {
            var refreshes = 0
            let surface = mount(CodingUsageAccountCard(title: "Claude · Example", snapshot: snapshot,
                isRefreshing: false, refresh: { refreshes += 1 }, show: { XCTFail("Ready accounts must not reconnect through Show Usage") })
                .padding(20).environment(\.colorScheme, scheme), size: CGSize(width: 640, height: 460))
            defer { surface.window.close() }
            try capture(surface.host, to: directory.appendingPathComponent("usage-\(scheme == .dark ? "dark" : "light").png"))
            click(surface, x: 553, y: 54)
            XCTAssertEqual(refreshes, 1, "The native Refresh button must invoke its action")
            XCTAssertFalse(surface.window.isKeyWindow)
            XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(surface.window.frame) })
        }

        var shows = 0
        let hidden = mount(CodingUsageAccountCard(title: "Codex · Example", snapshot: .disconnected(.codex),
            isRefreshing: false, refresh: { XCTFail("Hidden accounts cannot refresh") }, show: { shows += 1 }),
            size: CGSize(width: 620, height: 200))
        defer { hidden.window.close() }
        try capture(hidden.host, to: directory.appendingPathComponent("usage-hidden.png"))
        click(hidden, x: 550, y: 40)
        XCTAssertEqual(shows, 1)

        let failed = mount(CodingUsageAccountCard(title: "Claude · Example",
            snapshot: .failed(.claude, message: "CLI unavailable.", preserving: snapshot),
            isRefreshing: false, refresh: {}, show: {}), size: CGSize(width: 620, height: 480))
        defer { failed.window.close() }
        try capture(failed.host, to: directory.appendingPathComponent("usage-cached-error.png"))
    }

    func testCommandSurfaceInvokesSelectedDestination() throws {
        let directory = try output
        var selected: GeraldineCommand?
        let surface = mount(CommandSearchView { selected = $0 }, size: CGSize(width: 600, height: 460))
        defer { surface.window.close() }
        try capture(surface.host, to: directory.appendingPathComponent("command-search.png"))
        click(surface, x: 230, y: 205)
        XCTAssertEqual(selected?.action, .module(.activity))
        XCTAssertFalse(surface.window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(surface.window.frame) })
    }

    func testCommandTypingAndReturnOpenMatchingSection() throws {
        let directory = try output
        var selected: GeraldineCommand?
        let surface = mount(CommandSearchView { selected = $0 }, size: CGSize(width: 600, height: 460))
        defer { surface.window.close() }
        click(surface, x: 200, y: 32)
        sendKey(surface.window, characters: "show memory", keyCode: 0)
        settle(surface.host)
        try capture(surface.host, to: directory.appendingPathComponent("command-search-memory.png"))
        sendKey(surface.window, characters: "\r", keyCode: 36)
        settle(surface.host)
        XCTAssertEqual(selected?.action, .activity(.memory))
        XCTAssertFalse(surface.window.isKeyWindow)
    }

    func testChartDragSharesInspectionTime() throws {
        let directory = try output
        let fixture = InspectionFixture()
        let surface = mount(InspectionSurface(fixture: fixture), size: CGSize(width: 620, height: 260))
        defer { surface.window.close() }
        sendMouse(.leftMouseDown, surface, x: 300, y: 60)
        sendMouse(.leftMouseDragged, surface, x: 406.6666667, y: 60)
        settle(surface.host)
        XCTAssertEqual(try XCTUnwrap(fixture.time), 90, accuracy: 0.01)
        try capture(surface.host, to: directory.appendingPathComponent("shared-chart-cursor.png"))
        sendMouse(.leftMouseUp, surface, x: 406.6666667, y: 60)
        settle(surface.host)
        XCTAssertNil(fixture.time)
        sendKey(surface.window, characters: "\u{F702}", keyCode: 123)
        settle(surface.host)
        XCTAssertEqual(fixture.time, 90, "Arrow-key inspection must update the shared cursor too")
        XCTAssertFalse(surface.window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(surface.window.frame) })
    }

    func testCommandArrowKeyChangesTheSelectedResult() throws {
        _ = try output
        var selected: GeraldineCommand?
        let surface = mount(CommandSearchView { selected = $0 }, size: CGSize(width: 600, height: 460))
        defer { surface.window.close() }
        click(surface, x: 200, y: 32)
        sendKey(surface.window, characters: "show memory", keyCode: 0)
        settle(surface.host)
        sendKey(surface.window, characters: "\u{F701}", keyCode: 125)
        settle(surface.host)
        sendKey(surface.window, characters: "\r", keyCode: 36)
        settle(surface.host)
        XCTAssertEqual(selected?.action, .module(.activity))
        XCTAssertFalse(surface.window.isKeyWindow)
    }

    func testRenderProcessDetail() throws {
        let directory = try output
        let group = try XCTUnwrap(ProcessGroup.ranked([
            ProcUsage(id: 101, name: "Editor", cpu: 20, mem: 2, executablePath: "/Applications/Editor.app/Contents/MacOS/Editor"),
            ProcUsage(id: 102, name: "Renderer", cpu: 100, mem: 3, executablePath: "/Applications/Editor.app/Contents/Helpers/Renderer")
        ], byMemory: false).first)
        let surface = mount(ProcessDetailView(group: group, isCurrent: true), size: CGSize(width: 580, height: 480))
        defer { surface.window.close() }
        try capture(surface.host, to: directory.appendingPathComponent("process-detail.png"))
    }

    func testAppUpdateCardStatesAndNotice() throws {
        let directory = try output
        let now = Date()
        let release = AppUpdateRelease(version: "0.2.1", build: "104")
        func status(_ change: (inout AppUpdatePresentation.Input) -> Void) -> AppUpdateStatusText {
            var input = AppUpdatePresentation.Input(
                isEnabled: true, startupError: nil, activity: .idle, lastCheck: now.addingTimeInterval(-600),
                lastError: nil, automaticallyChecks: true, automaticallyInstalls: true, blockers: [], outcome: nil
            )
            change(&input)
            return AppUpdatePresentation.status(input, now: now)
        }
        let cards: [(name: String, status: AppUpdateStatusText, action: AppUpdateCardAction, enabled: Bool)] = [
            ("up-to-date", status { _ in }, .checkNow(enabled: true), true),
            ("ready", status { $0.activity = .ready(release); $0.blockers = [.windowOpen] }, .restart, true),
            ("available", status { $0.activity = .available(release); $0.automaticallyInstalls = false },
             .viewUpdate(enabled: true), true),
            ("downloading", status { $0.activity = .downloading(release) }, .progress, true),
            ("error", status { $0.lastError = "The network connection was lost." }, .checkNow(enabled: true), true),
            ("updated", status { $0.outcome = .updated(release, at: now) }, .checkNow(enabled: true), true),
            ("off", status { $0.isEnabled = false }, .none, false)
        ]
        for scheme in [ColorScheme.light, .dark] {
            for card in cards {
                // The same section card Settings draws around it.
                let view = VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SectionHeader("Updates", subtitle: card.enabled
                        ? "Geraldine checks geraldine.hemisthia.com for new versions and verifies each one before installing it."
                        : "Published Geraldine releases update themselves.")
                    AppUpdateStatusCard(status: card.status, versionText: "0.2.0 (101)",
                                        updatesEnabled: card.enabled, action: card.action) {}
                    if card.enabled {
                        AppUpdatePreferences(checksAutomatically: .constant(true),
                                             installsAutomatically: .constant(card.name != "available"))
                    }
                }
                .card(padding: Theme.Spacing.lg, tier: .raised, cornerRadius: Theme.Radius.raised)
                .padding(20)
                .frame(width: 680, alignment: .topLeading)
                .environment(\.colorScheme, scheme)
                let surface = mount(view, size: CGSize(width: 680, height: card.enabled ? 360 : 240))
                defer { surface.window.close() }
                let name = "updates-\(card.name)-\(scheme == .dark ? "dark" : "light").png"
                try capture(surface.host, to: directory.appendingPathComponent(name))
            }
        }

        var restarts = 0
        var reviews = 0
        let notices = mount(VStack(spacing: 8) {
            AppUpdateNoticeButton(release: release, isReady: true) { restarts += 1 }
            AppUpdateNoticeButton(release: release, isReady: false) { reviews += 1 }
        }.padding(12).frame(width: 280), size: CGSize(width: 280, height: 132))
        defer { notices.window.close() }
        try capture(notices.host, to: directory.appendingPathComponent("updates-notices.png"))
        click(notices, x: 140, y: 36)
        XCTAssertEqual(restarts, 1, "The ready notice restarts to update")
        XCTAssertEqual(reviews, 0)
        XCTAssertFalse(notices.window.isKeyWindow)
    }

    private func mount(_ view: some View, size: CGSize) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(view.transaction { $0.disablesAnimations = true }
            .background(Color(nsColor: .windowBackgroundColor))))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) })
        settle(host)
        return (window, host)
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
    }

    private func click(_ surface: (window: NSWindow, host: NSHostingView<AnyView>), x: CGFloat, y: CGFloat) {
        sendMouse(.leftMouseDown, surface, x: x, y: y)
        sendMouse(.leftMouseUp, surface, x: x, y: y)
        settle(surface.host)
    }

    private func sendMouse(_ type: NSEvent.EventType,
                           _ surface: (window: NSWindow, host: NSHostingView<AnyView>), x: CGFloat, y: CGFloat) {
        let local = CGPoint(x: x, y: surface.host.isFlipped ? y : surface.host.bounds.height - y)
        let point = surface.host.convert(local, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: surface.window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            XCTFail("Could not construct test-window event")
            return
        }
        surface.window.sendEvent(event)
    }

    private func capture(_ host: NSView, to url: URL) throws {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private func sendKey(_ window: NSWindow, characters: String, keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          characters: characters, charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: keyCode) else {
            XCTFail("Could not construct test-window key event")
            return
        }
        window.sendEvent(event)
    }
}

@MainActor
private final class InspectionFixture: ObservableObject {
    @Published var time: TimeInterval?
}

private struct InspectionSurface: View {
    @ObservedObject var fixture: InspectionFixture
    var body: some View {
        VStack(spacing: 24) {
            graph("CPU", values: [0.2, 0.4, 0.6])
            graph("Memory", values: [0.5, 0.6, 0.7])
        }.padding(20)
    }
    private func graph(_ title: String, values: [Double]) -> some View {
        TimelineSparkGraph(samples: zip([80.0, 90.0, 100.0], values).map { MetricSample(timestamp: $0.0, value: $0.1) },
                           window: 30, now: Date(timeIntervalSinceReferenceDate: 100), tint: .blue,
                           domain: 0...1, gapThreshold: 15,
                           inspectionValueFormatter: { Fmt.percent($0) },
                           inspectionAccessibilityLabel: "\(title) test history", inspectionTime: $fixture.time)
            .frame(height: 90)
    }
}
