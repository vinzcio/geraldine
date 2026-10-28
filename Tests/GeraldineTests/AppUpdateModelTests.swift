import XCTest
import GeraldineControl
@testable import Geraldine

final class AppUpdateModelTests: XCTestCase {
    private let publicKey = "mU+iSnhLnPfYeOkQ5/JVXvLNf3C2K0VFc/q4hlR4uz0="

    // MARK: - Configuration

    func testPublishedBuildNamesItsHTTPSFeedAndKey() {
        let configuration = AppUpdateConfiguration(info: [
            "SUFeedURL": "https://geraldine.hemisthia.com/updates/appcast.xml",
            "SUPublicEDKey": publicKey,
            "GeraldineUpdateChannel": "production"
        ])
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.feedURL?.host, "geraldine.hemisthia.com")
        XCTAssertEqual(configuration.channel, "production")
    }

    func testLocalBuildsAndUnsafeFeedsNeverUpdate() {
        let rejected: [[String: Any]] = [
            [:],
            ["SUFeedURL": "https://geraldine.hemisthia.com/updates/appcast.xml"],
            ["SUFeedURL": "https://geraldine.hemisthia.com/updates/appcast.xml", "SUPublicEDKey": "  "],
            ["SUFeedURL": "http://geraldine.hemisthia.com/updates/appcast.xml", "SUPublicEDKey": publicKey],
            ["SUFeedURL": "file:///tmp/appcast.xml", "SUPublicEDKey": publicKey],
            ["SUFeedURL": "not a url", "SUPublicEDKey": publicKey],
            ["SUPublicEDKey": publicKey]
        ]
        for info in rejected {
            XCTAssertFalse(AppUpdateConfiguration(info: info).isEnabled, "\(info)")
        }
        // Only a loopback test feed may be plain HTTP.
        XCTAssertTrue(AppUpdateConfiguration(info: [
            "SUFeedURL": "http://127.0.0.1:8123/appcast.xml", "SUPublicEDKey": publicKey
        ]).isEnabled)
    }

    // MARK: - Automatic restart policy

    func testOpenWindowMenuOrPausedSessionBlocksAnAutomaticRestart() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func blockers(window: Bool = false, menu: Bool = false, paused: Bool = false) -> [AppUpdateInstallBlocker] {
            AppUpdateInstallPolicy.blockers(
                AppUpdateInstallContext(mainWindowPresented: window, menuBarPopoverVisible: menu, keepAwakePaused: paused),
                lastInteraction: nil,
                now: now
            )
        }
        XCTAssertEqual(blockers(), [])
        XCTAssertEqual(blockers(window: true), [.windowOpen])
        XCTAssertEqual(blockers(menu: true), [.menuOpen])
        XCTAssertEqual(blockers(paused: true), [.keepAwakePaused])
        XCTAssertEqual(blockers(window: true, menu: true, paused: true), [.windowOpen, .menuOpen, .keepAwakePaused])
    }

    func testClosingTheMenuOrWindowStartsAQuietInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let closed = AppUpdateInstallContext(mainWindowPresented: false, menuBarPopoverVisible: false, keepAwakePaused: false)
        let justClosed = now.addingTimeInterval(-30)
        XCTAssertEqual(AppUpdateInstallPolicy.blockers(closed, lastInteraction: justClosed, now: now), [.recentlyUsed])
        XCTAssertEqual(
            AppUpdateInstallPolicy.retryDelay(for: [.recentlyUsed], lastInteraction: justClosed, now: now),
            AppUpdateInstallPolicy.fallbackRetryInterval
        )
        let almostQuiet = now.addingTimeInterval(-(AppUpdateInstallPolicy.quietInterval - 15))
        XCTAssertEqual(AppUpdateInstallPolicy.retryDelay(for: [.recentlyUsed], lastInteraction: almostQuiet, now: now), 15,
                       accuracy: 0.001)
        let quiet = now.addingTimeInterval(-AppUpdateInstallPolicy.quietInterval)
        XCTAssertEqual(AppUpdateInstallPolicy.blockers(closed, lastInteraction: quiet, now: now), [])
        // An open surface is the reason that matters; the quiet interval is not stacked on top.
        let open = AppUpdateInstallContext(mainWindowPresented: true, menuBarPopoverVisible: false, keepAwakePaused: false)
        XCTAssertEqual(AppUpdateInstallPolicy.blockers(open, lastInteraction: justClosed, now: now), [.windowOpen])
        XCTAssertEqual(
            AppUpdateInstallPolicy.retryDelay(for: [.windowOpen], lastInteraction: justClosed, now: now),
            AppUpdateInstallPolicy.fallbackRetryInterval
        )
    }

    // MARK: - Relaunch handoff

    private func makeStore() -> (AppUpdateRelaunchHandoffStore, UserDefaults, () -> Void) {
        let suite = "AppUpdateModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppUpdateRelaunchHandoffStore(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    private func handoff(createdAt: Date, bootTime: Date?) -> AppUpdateRelaunchHandoff {
        AppUpdateRelaunchHandoff(
            createdAt: createdAt,
            bootTime: bootTime,
            fromVersion: "0.2.0",
            fromBuild: "101",
            target: AppUpdateRelease(version: "0.2.1", build: "104"),
            keepAwake: KeepAwakeSessionHandoff(
                activeSince: createdAt.addingTimeInterval(-600),
                activeUntil: nil,
                wasPaused: false,
                stayActivePulseUptime: 5_000,
                stayActiveLastUserInput: createdAt.addingTimeInterval(-900)
            )
        )
    }

    func testHandoffIsReadOnceByTheLaunchThatFollowsOnTheSameBoot() {
        let (store, defaults, cleanup) = makeStore()
        defer { cleanup() }
        let boot = Date(timeIntervalSince1970: 900_000)
        let written = handoff(createdAt: Date(timeIntervalSince1970: 1_000_000), bootTime: boot)
        store.save(written)

        let read = store.consume(now: written.createdAt.addingTimeInterval(4), bootTime: boot.addingTimeInterval(0.5))
        XCTAssertEqual(read, written)
        XCTAssertNil(defaults.object(forKey: AppUpdateRelaunchHandoffStore.defaultsKey))
        XCTAssertNil(store.consume(now: written.createdAt.addingTimeInterval(5), bootTime: boot))
    }

    func testStaleRebootedOrUnbootedHandoffsAreDiscarded() {
        let (store, defaults, cleanup) = makeStore()
        defer { cleanup() }
        let boot = Date(timeIntervalSince1970: 900_000)
        let created = Date(timeIntervalSince1970: 1_000_000)
        let cases: [(handoff: AppUpdateRelaunchHandoff, now: Date, boot: Date?)] = [
            (handoff(createdAt: created, bootTime: boot), created.addingTimeInterval(AppUpdateRelaunchHandoffStore.maximumAge + 1), boot),
            (handoff(createdAt: created, bootTime: boot), created.addingTimeInterval(-60), boot),
            (handoff(createdAt: created, bootTime: boot), created.addingTimeInterval(3), boot.addingTimeInterval(400)),
            (handoff(createdAt: created, bootTime: boot), created.addingTimeInterval(3), nil),
            (handoff(createdAt: created, bootTime: nil), created.addingTimeInterval(3), boot)
        ]
        for item in cases {
            store.save(item.handoff)
            XCTAssertNil(store.consume(now: item.now, bootTime: item.boot))
            XCTAssertNil(defaults.object(forKey: AppUpdateRelaunchHandoffStore.defaultsKey), "The record is removed even when it is not used")
        }
    }

    func testUnreadableOrFutureFormatHandoffsAreRemoved() throws {
        let (store, defaults, cleanup) = makeStore()
        defer { cleanup() }
        let boot = Date(timeIntervalSince1970: 900_000)
        defaults.set(Data("not json".utf8), forKey: AppUpdateRelaunchHandoffStore.defaultsKey)
        XCTAssertNil(store.consume(now: Date(timeIntervalSince1970: 1_000_000), bootTime: boot))
        XCTAssertNil(defaults.object(forKey: AppUpdateRelaunchHandoffStore.defaultsKey))

        defaults.set("a string", forKey: AppUpdateRelaunchHandoffStore.defaultsKey)
        XCTAssertNil(store.consume(now: Date(timeIntervalSince1970: 1_000_000), bootTime: boot))
        XCTAssertNil(defaults.object(forKey: AppUpdateRelaunchHandoffStore.defaultsKey))

        var future = handoff(createdAt: Date(timeIntervalSince1970: 1_000_000), bootTime: boot)
        future.format = AppUpdateRelaunchHandoff.currentFormat + 1
        defaults.set(try JSONEncoder().encode(future), forKey: AppUpdateRelaunchHandoffStore.defaultsKey)
        XCTAssertNil(store.consume(now: future.createdAt, bootTime: boot))
        XCTAssertNil(defaults.object(forKey: AppUpdateRelaunchHandoffStore.defaultsKey))
    }

    func testCurrentBootTimeIsReadableAndStable() throws {
        let first = try XCTUnwrap(SystemBoot.time())
        let second = try XCTUnwrap(SystemBoot.time())
        XCTAssertLessThan(first, Date())
        XCTAssertEqual(first.timeIntervalSince(second), 0, accuracy: AppUpdateRelaunchHandoffStore.bootTimeTolerance)
    }

    func testRelaunchOutcomeComparesTheRunningBuild() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let written = handoff(createdAt: now, bootTime: now)
        XCTAssertEqual(
            AppUpdateRelaunchOutcome(handoff: written, runningVersion: "0.2.1", runningBuild: "104", now: now),
            .updated(AppUpdateRelease(version: "0.2.1", build: "104"), at: now)
        )
        XCTAssertEqual(
            AppUpdateRelaunchOutcome(handoff: written, runningVersion: "0.2.0", runningBuild: "101", now: now),
            .notUpdated(target: AppUpdateRelease(version: "0.2.1", build: "104"), runningVersion: "0.2.0", at: now)
        )
        var untargeted = written
        untargeted.target = nil
        XCTAssertNil(AppUpdateRelaunchOutcome(handoff: untargeted, runningVersion: "0.2.0", runningBuild: "101", now: now))
    }

    // MARK: - Presentation

    func testStatusTextNamesWhatTheUpdaterIsDoing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let release = AppUpdateRelease(version: "0.2.1", build: "104")
        func status(_ change: (inout AppUpdatePresentation.Input) -> Void) -> AppUpdateStatusText {
            var input = AppUpdatePresentation.Input(
                isEnabled: true, startupError: nil, activity: .idle, lastCheck: nil, lastError: nil,
                automaticallyChecks: true, automaticallyInstalls: true, blockers: [], outcome: nil
            )
            change(&input)
            return AppUpdatePresentation.status(input, now: now, calendar: calendar)
        }

        XCTAssertEqual(status { $0.isEnabled = false }.title, "Updates Are Off In This Build")
        XCTAssertEqual(status { $0.startupError = "Bad key" },
                       AppUpdateStatusText(title: "Updates Couldn't Start", detail: "Bad key", tone: .attention))
        XCTAssertEqual(status { _ in }.detail, "Geraldine checks for updates every hour.")
        XCTAssertEqual(status { $0.automaticallyChecks = false }.detail, "Automatic checks are off.")
        XCTAssertEqual(status { $0.activity = .checking }.title, "Checking For Updates…")
        XCTAssertEqual(status { $0.activity = .available(release) }.detail, "It downloads in the background.")
        XCTAssertEqual(status { $0.activity = .available(release); $0.automaticallyInstalls = false }.detail,
                       "Review what's new, then install it when you're ready.")
        XCTAssertEqual(status { $0.activity = .downloading(release) }.title, "Downloading Geraldine 0.2.1…")
        XCTAssertEqual(status { $0.activity = .ready(release); $0.blockers = [.windowOpen] },
                       AppUpdateStatusText(title: "Geraldine 0.2.1 Is Ready",
                                           detail: "Geraldine restarts to finish updating after you close its window.",
                                           tone: .good))
        XCTAssertEqual(status { $0.activity = .ready(release); $0.automaticallyInstalls = false }.detail,
                       "Restart Geraldine to finish updating.")
        XCTAssertEqual(status { $0.activity = .installing(release) }.title, "Installing Geraldine 0.2.1…")
        XCTAssertEqual(status { $0.lastError = "The network connection was lost." },
                       AppUpdateStatusText(title: "Couldn't Check For Updates",
                                           detail: "The network connection was lost.", tone: .attention))

        let checked = now.addingTimeInterval(-120)
        let upToDate = status { $0.lastCheck = checked }
        XCTAssertEqual(upToDate.title, "Geraldine Is Up To Date")
        XCTAssertEqual(upToDate.detail, "Last checked today at \(checked.formatted(date: .omitted, time: .shortened)).")
        XCTAssertEqual(status { $0.outcome = .updated(release, at: now) }.title, "Updated To Geraldine 0.2.1")
        XCTAssertEqual(
            status { $0.outcome = .notUpdated(target: release, runningVersion: "0.2.0", at: now) }.detail,
            "Geraldine 0.2.1 didn't install, so this is still 0.2.0. The next check tries again."
        )
        // A ready update outranks an older error.
        XCTAssertEqual(status { $0.activity = .ready(release); $0.lastError = "old" }.title, "Geraldine 0.2.1 Is Ready")
    }

    func testReadyDetailExplainsEachWait() {
        XCTAssertEqual(AppUpdatePresentation.readyDetail(automaticallyInstalls: true, blockers: []),
                       "Restarting to finish updating…")
        XCTAssertEqual(AppUpdatePresentation.readyDetail(automaticallyInstalls: true, blockers: [.menuOpen]),
                       "Geraldine restarts to finish updating after you close the menu bar panel.")
        XCTAssertEqual(AppUpdatePresentation.readyDetail(automaticallyInstalls: true, blockers: [.keepAwakePaused]),
                       "Geraldine restarts to finish updating once Keep Awake resumes.")
        XCTAssertEqual(AppUpdatePresentation.readyDetail(automaticallyInstalls: true, blockers: [.recentlyUsed]),
                       "Geraldine restarts to finish updating in a couple of minutes.")
    }

    // MARK: - Lane isolation

    func testOnlyAValidSupportFolderNameMovesSharedState() {
        XCTAssertEqual(SupportDirectory.folderName(in: [:]), "Geraldine")
        XCTAssertEqual(SupportDirectory.folderName(in: [SupportDirectory.infoKey: "Geraldine Update Test"]),
                       "Geraldine Update Test")
        for invalid in ["", "  ", "../Geraldine", ".hidden", "a/b", "a:b"] {
            XCTAssertEqual(SupportDirectory.folderName(in: [SupportDirectory.infoKey: invalid]), "Geraldine", invalid)
        }
        // The CLI and a production app agree on the default socket.
        XCTAssertEqual(
            ControlEndpointPath.socket(folder: "Geraldine"),
            ControlEndpointPath.socket(folder: nil)
        )
        XCTAssertTrue(ControlEndpointPath.socket(folder: "Geraldine Update Test")
            .hasSuffix("/Geraldine Update Test/control.sock"))
    }
}

private enum ControlEndpointPath {
    static func socket(folder: String?) -> String {
        if let folder {
            return ControlEndpoint.socketURL(environment: [:], supportFolderName: folder).path
        }
        return ControlEndpoint.socketURL(environment: [:]).path
    }
}
