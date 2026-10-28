import Foundation

/// How this build finds its updates. A published build names its signed feed
/// and the feed's public key in Info.plist; a local build names neither and
/// never updates itself.
struct AppUpdateConfiguration: Equatable {
    static let channelKey = "GeraldineUpdateChannel"
    static let current = AppUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])

    let feedURL: URL?
    let hasPublicKey: Bool
    let channel: String?

    init(info: [String: Any]) {
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        feedURL = feed.flatMap(URL.init(string:)).flatMap(Self.acceptedFeedURL)
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasPublicKey = !key.isEmpty
        channel = info[Self.channelKey] as? String
    }

    var isEnabled: Bool { feedURL != nil && hasPublicKey }

    /// HTTPS only. Plain HTTP is accepted for a loopback test feed.
    private static func acceptedFeedURL(_ url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host) ? url : nil
        default: return nil
        }
    }
}

struct AppUpdateRelease: Codable, Equatable {
    /// CFBundleShortVersionString, shown to people.
    let version: String
    /// CFBundleVersion, which Sparkle compares.
    let build: String
}

enum AppUpdateActivity: Equatable {
    case idle
    case checking
    /// Found and verified, waiting for someone to choose to install it.
    case available(AppUpdateRelease)
    case downloading(AppUpdateRelease)
    /// Downloaded, verified, and staged. Installing needs a restart.
    case ready(AppUpdateRelease)
    case installing(AppUpdateRelease)

    var release: AppUpdateRelease? {
        switch self {
        case .idle, .checking: return nil
        case .available(let release), .downloading(let release),
             .ready(let release), .installing(let release):
            return release
        }
    }
}

// MARK: - Automatic installation

enum AppUpdateInstallBlocker: String, CaseIterable, Equatable {
    case windowOpen
    case menuOpen
    case keepAwakePaused
    case recentlyUsed
}

struct AppUpdateInstallContext: Equatable {
    var mainWindowPresented: Bool
    var menuBarPopoverVisible: Bool
    var keepAwakePaused: Bool
}

/// When an automatic update may restart Geraldine. Cleanup, uninstall, and
/// scan work only runs inside the main window, and closing the window unmounts
/// it, so a closed window means no such work is in flight. Keep Awake and Stay
/// Active carry across the restart; a paused session cannot, so it waits.
enum AppUpdateInstallPolicy {
    /// Closing the menu or window is never followed straight away by a restart.
    static let quietInterval: TimeInterval = 120
    /// Re-checks a blocked install even if no change notification arrives.
    static let fallbackRetryInterval: TimeInterval = 60

    static func blockers(_ context: AppUpdateInstallContext,
                         lastInteraction: Date?,
                         now: Date) -> [AppUpdateInstallBlocker] {
        var blockers: [AppUpdateInstallBlocker] = []
        if context.mainWindowPresented { blockers.append(.windowOpen) }
        if context.menuBarPopoverVisible { blockers.append(.menuOpen) }
        if context.keepAwakePaused { blockers.append(.keepAwakePaused) }
        if blockers.isEmpty, let lastInteraction,
           now.timeIntervalSince(lastInteraction) < quietInterval {
            blockers.append(.recentlyUsed)
        }
        return blockers
    }

    static func retryDelay(for blockers: [AppUpdateInstallBlocker],
                           lastInteraction: Date?,
                           now: Date) -> TimeInterval {
        guard blockers == [.recentlyUsed], let lastInteraction else { return fallbackRetryInterval }
        let remaining = quietInterval - now.timeIntervalSince(lastInteraction)
        return min(fallbackRetryInterval, max(1, remaining))
    }
}

// MARK: - Relaunch handoff

/// Written right before an update restarts Geraldine and read once by the next
/// launch, so a running Keep Awake session (and Stay Active within it)
/// continues instead of ending with the old process.
struct AppUpdateRelaunchHandoff: Codable, Equatable {
    static let currentFormat = 1

    var format = AppUpdateRelaunchHandoff.currentFormat
    var createdAt: Date
    /// `kern.boottime`; a reboot in between voids the handoff.
    var bootTime: Date?
    var fromVersion: String
    var fromBuild: String
    var target: AppUpdateRelease?
    var keepAwake: KeepAwakeSessionHandoff?
}

struct AppUpdateRelaunchHandoffStore {
    static let defaultsKey = "appUpdate.relaunchHandoff"
    /// A relaunch takes seconds. Anything older is not the launch that followed it.
    static let maximumAge: TimeInterval = 10 * 60
    static let bootTimeTolerance: TimeInterval = 5

    let defaults: UserDefaults

    func save(_ handoff: AppUpdateRelaunchHandoff) {
        guard let data = try? JSONEncoder().encode(handoff) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Reads and removes the record: it is used at most once, and only by a
    /// launch on the same boot shortly after it was written.
    func consume(now: Date, bootTime: Date?) -> AppUpdateRelaunchHandoff? {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            if defaults.object(forKey: Self.defaultsKey) != nil {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
            return nil
        }
        defaults.removeObject(forKey: Self.defaultsKey)
        guard let handoff = try? JSONDecoder().decode(AppUpdateRelaunchHandoff.self, from: data),
              handoff.format == AppUpdateRelaunchHandoff.currentFormat else { return nil }
        let age = now.timeIntervalSince(handoff.createdAt)
        guard age >= -Self.bootTimeTolerance, age <= Self.maximumAge else { return nil }
        guard let savedBoot = handoff.bootTime, let bootTime,
              abs(savedBoot.timeIntervalSince(bootTime)) <= Self.bootTimeTolerance else { return nil }
        return handoff
    }
}

enum SystemBoot {
    static func time() -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }
}

enum AppUpdateRelaunchOutcome: Equatable {
    case updated(AppUpdateRelease, at: Date)
    case notUpdated(target: AppUpdateRelease, runningVersion: String, at: Date)

    init?(handoff: AppUpdateRelaunchHandoff, runningVersion: String, runningBuild: String, now: Date) {
        guard let target = handoff.target else { return nil }
        if target.build == runningBuild {
            self = .updated(target, at: now)
        } else {
            self = .notUpdated(target: target, runningVersion: runningVersion, at: now)
        }
    }
}

// MARK: - Presentation

struct AppUpdateStatusText: Equatable {
    enum Tone: Equatable { case neutral, good, attention }

    let title: String
    let detail: String?
    let tone: Tone
}

enum AppUpdatePresentation {
    struct Input {
        var isEnabled: Bool
        var startupError: String?
        var activity: AppUpdateActivity
        var lastCheck: Date?
        var lastError: String?
        var automaticallyChecks: Bool
        var automaticallyInstalls: Bool
        var blockers: [AppUpdateInstallBlocker]
        var outcome: AppUpdateRelaunchOutcome?
    }

    static func status(_ input: Input, now: Date = Date(), calendar: Calendar = .current) -> AppUpdateStatusText {
        guard input.isEnabled else {
            return AppUpdateStatusText(
                title: "Updates Are Off In This Build",
                detail: "Local builds don't update themselves. Install a published Geraldine release to get updates.",
                tone: .neutral
            )
        }
        if let startupError = input.startupError {
            return AppUpdateStatusText(title: "Updates Couldn't Start", detail: startupError, tone: .attention)
        }

        switch input.activity {
        case .checking:
            return AppUpdateStatusText(title: "Checking For Updates…", detail: nil, tone: .neutral)
        case .available(let release):
            return AppUpdateStatusText(
                title: "Geraldine \(release.version) Is Available",
                detail: input.automaticallyInstalls
                    ? "It downloads in the background."
                    : "Review what's new, then install it when you're ready.",
                tone: .good
            )
        case .downloading(let release):
            return AppUpdateStatusText(title: "Downloading Geraldine \(release.version)…", detail: nil, tone: .neutral)
        case .ready(let release):
            return AppUpdateStatusText(
                title: "Geraldine \(release.version) Is Ready",
                detail: readyDetail(automaticallyInstalls: input.automaticallyInstalls, blockers: input.blockers),
                tone: .good
            )
        case .installing(let release):
            return AppUpdateStatusText(
                title: "Installing Geraldine \(release.version)…",
                detail: "Geraldine reopens in a moment.",
                tone: .neutral
            )
        case .idle:
            break
        }

        if let lastError = input.lastError {
            return AppUpdateStatusText(title: "Couldn't Check For Updates", detail: lastError, tone: .attention)
        }
        switch input.outcome {
        case .updated(let release, let at):
            return AppUpdateStatusText(
                title: "Updated To Geraldine \(release.version)",
                detail: "Geraldine restarted with the new version \(timePhrase(at, now: now, calendar: calendar)).",
                tone: .good
            )
        case .notUpdated(let target, let runningVersion, _):
            return AppUpdateStatusText(
                title: "The Update Didn't Finish",
                detail: "Geraldine \(target.version) didn't install, so this is still \(runningVersion). The next check tries again.",
                tone: .attention
            )
        case nil:
            break
        }
        guard let lastCheck = input.lastCheck else {
            return AppUpdateStatusText(
                title: "Not Checked Yet",
                detail: input.automaticallyChecks
                    ? "Geraldine checks for updates every hour."
                    : "Automatic checks are off.",
                tone: .neutral
            )
        }
        return AppUpdateStatusText(
            title: "Geraldine Is Up To Date",
            detail: "Last checked \(timePhrase(lastCheck, now: now, calendar: calendar)).",
            tone: .neutral
        )
    }

    static func readyDetail(automaticallyInstalls: Bool, blockers: [AppUpdateInstallBlocker]) -> String {
        guard automaticallyInstalls else { return "Restart Geraldine to finish updating." }
        guard let first = blockers.first else { return "Restarting to finish updating…" }
        switch first {
        case .windowOpen: return "Geraldine restarts to finish updating after you close its window."
        case .menuOpen: return "Geraldine restarts to finish updating after you close the menu bar panel."
        case .keepAwakePaused: return "Geraldine restarts to finish updating once Keep Awake resumes."
        case .recentlyUsed: return "Geraldine restarts to finish updating in a couple of minutes."
        }
    }

    static func timePhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }
}
