import AppKit
import Combine
import os
import Sparkle

/// `log stream --predicate 'subsystem == "com.vincent.geraldine" AND category == "updates"'`
private let updateLog = Logger(subsystem: "com.vincent.geraldine", category: "updates")

/// Geraldine's own updates. Sparkle checks the signed feed named in Info.plist,
/// verifies the feed and each archive against the bundled public key, and
/// installs. Automatic updates download in the background and restart
/// Geraldine only when no window or menu is in use, carrying a running Keep
/// Awake session (and Stay Active within it) across the restart.
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
    @Published private(set) var activity: AppUpdateActivity = .idle
    @Published private(set) var lastCheck: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var blockers: [AppUpdateInstallBlocker] = []
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var relaunchOutcome: AppUpdateRelaunchOutcome?
    @Published private(set) var startupError: String?

    let configuration: AppUpdateConfiguration
    private let handoffStore: AppUpdateRelaunchHandoffStore
    private let build: BuildInfo
    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver?
    /// Sparkle's handler for installing a staged update and relaunching now.
    private var stagedInstall: (() -> Void)?
    private var installContext: () -> AppUpdateInstallContext = {
        AppUpdateInstallContext(mainWindowPresented: false, menuBarPopoverVisible: false, keepAwakePaused: false)
    }
    private var keepAwakeHandoff: () -> KeepAwakeSessionHandoff? = { nil }
    private var previousContext: AppUpdateInstallContext?
    private var lastInteraction: Date?
    private var retryTimer: Timer?
    private var restartConfirmation: NSAlert?
    private var observations: [NSKeyValueObservation] = []
    private var contextChanges: AnyCancellable?

    init(configuration: AppUpdateConfiguration = .current,
         handoffStore: AppUpdateRelaunchHandoffStore = AppUpdateRelaunchHandoffStore(defaults: .standard),
         build: BuildInfo = .current) {
        self.configuration = configuration
        self.handoffStore = handoffStore
        self.build = build
        super.init()
    }

    var isEnabled: Bool { configuration.isEnabled }
    var isRunning: Bool { updater != nil }

    var statusText: AppUpdateStatusText {
        AppUpdatePresentation.status(AppUpdatePresentation.Input(
            isEnabled: isEnabled,
            startupError: startupError,
            activity: activity,
            lastCheck: lastCheck,
            lastError: lastError,
            automaticallyChecks: automaticallyChecks,
            automaticallyInstalls: automaticallyInstalls,
            blockers: blockers,
            outcome: relaunchOutcome
        ))
    }

    /// Surfaces outside Settings (sidebar, menu bar panel) only speak up when
    /// there is something to act on. With automatic installs on, a found update
    /// is already on its way, so it appears once it is ready.
    var actionableRelease: AppUpdateRelease? {
        switch activity {
        case .ready(let release): return release
        case .available(let release): return automaticallyInstalls ? nil : release
        default: return nil
        }
    }

    var isReadyToRestart: Bool { stagedInstall != nil }

    /// The menu command and Settings button: a staged update answers a check
    /// with its restart offer, so it stays available while Sparkle is busy.
    var canStartUserCheck: Bool { updater != nil && (canCheckForUpdates || stagedInstall != nil) }

    // MARK: - Lifecycle

    /// Reads, once, what the previous process left before an update restarted it.
    func consumeRelaunchHandoff(now: Date = Date()) -> AppUpdateRelaunchHandoff? {
        guard let handoff = handoffStore.consume(now: now, bootTime: SystemBoot.time()) else { return nil }
        relaunchOutcome = AppUpdateRelaunchOutcome(
            handoff: handoff,
            runningVersion: build.version,
            runningBuild: build.bundleVersion,
            now: now
        )
        updateLog.notice("Relaunched after an update from build \(handoff.fromBuild, privacy: .public) as build \(self.build.bundleVersion, privacy: .public); Keep Awake session carried: \(handoff.keepAwake != nil, privacy: .public)")
        return handoff
    }

    func start(installContext: @escaping () -> AppUpdateInstallContext,
               keepAwakeHandoff: @escaping () -> KeepAwakeSessionHandoff?,
               contextChanges: AnyPublisher<Void, Never>) {
        guard updater == nil, configuration.isEnabled else { return }
        self.installContext = installContext
        self.keepAwakeHandoff = keepAwakeHandoff

        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
        } catch {
            startupError = error.localizedDescription
            updateLog.error("Updates could not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        userDriver = driver
        self.updater = updater
        startupError = nil
        observe(updater)
        syncSettings()

        previousContext = installContext()
        // @Published delivers in willSet; read the context after the change lands.
        self.contextChanges = contextChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.contextDidChange() }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        contextChanges = nil
        observations.removeAll()
    }

    // MARK: - User actions

    /// Menu, ⌘K, and Settings. Shows Sparkle's own check, or offers the
    /// restart for an update that is already downloaded.
    func checkForUpdates() {
        guard let updater else { return }
        if stagedInstall != nil {
            confirmRestart()
            return
        }
        lastError = nil
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    /// The explicit "Restart To Update" control.
    func restartToUpdate() {
        guard stagedInstall != nil else {
            checkForUpdates()
            return
        }
        installStagedUpdate()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        syncSettings()
        evaluateStagedInstall()
    }

    func setAutomaticallyInstalls(_ enabled: Bool) {
        guard let updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        syncSettings()
        evaluateStagedInstall()
    }

    // MARK: - Staged installs

    private func contextDidChange() {
        let context = installContext()
        if let previousContext,
           previousContext.mainWindowPresented != context.mainWindowPresented
            || previousContext.menuBarPopoverVisible != context.menuBarPopoverVisible {
            lastInteraction = Date()
            updateLog.info("Geraldine was used (window open: \(context.mainWindowPresented, privacy: .public), menu open: \(context.menuBarPopoverVisible, privacy: .public))")
        }
        previousContext = context
        evaluateStagedInstall()
    }

    private func evaluateStagedInstall(now: Date = Date()) {
        guard stagedInstall != nil, case .ready = activity, automaticallyInstalls,
              restartConfirmation == nil else {
            blockers = []
            cancelRetry()
            return
        }
        let found = AppUpdateInstallPolicy.blockers(installContext(), lastInteraction: lastInteraction, now: now)
        if found != blockers, !found.isEmpty {
            updateLog.info("Update waits: \(found.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
        blockers = found
        guard found.isEmpty else {
            scheduleRetry(after: AppUpdateInstallPolicy.retryDelay(for: found, lastInteraction: lastInteraction, now: now))
            return
        }
        installStagedUpdate()
    }

    private func installStagedUpdate() {
        guard let install = stagedInstall, case .ready(let release) = activity else { return }
        stagedInstall = nil
        cancelRetry()
        blockers = []
        saveHandoff(target: release)
        activity = .installing(release)
        updateLog.notice("Installing Geraldine \(release.version, privacy: .public) (\(release.build, privacy: .public)) and restarting")
        install()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateStagedInstall() }
        }
        timer.tolerance = min(10, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func confirmRestart() {
        guard restartConfirmation == nil, case .ready(let release) = activity else { return }
        let alert = NSAlert()
        alert.messageText = "Restart Geraldine To Update?"
        var detail = "Geraldine \(release.version) is downloaded and verified."
        if keepAwakeHandoff() != nil {
            detail += " Keep Awake and Stay Active continue after the restart."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Restart To Update")
        alert.addButton(withTitle: "Later")
        restartConfirmation = alert
        cancelRetry()
        NSApp.activate(ignoringOtherApps: true)

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.restartConfirmation = nil
            if response == .alertFirstButtonReturn {
                self.installStagedUpdate()
            } else {
                // "Later" counts as using Geraldine: no restart straight after it.
                self.lastInteraction = Date()
                self.evaluateStagedInstall()
            }
        }
        if let window = AppState.shared.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Only a relaunch writes the handoff. Installing on quit must not carry a
    /// Keep Awake session the person ended by quitting.
    private func saveHandoff(target: AppUpdateRelease?) {
        handoffStore.save(AppUpdateRelaunchHandoff(
            createdAt: Date(),
            bootTime: SystemBoot.time(),
            fromVersion: build.version,
            fromBuild: build.bundleVersion,
            target: target,
            keepAwake: keepAwakeHandoff()
        ))
    }

    // MARK: - Sparkle state

    private func observe(_ updater: SPUUpdater) {
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.syncSettings() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.syncSettings() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.syncSettings() }
            }
        ]
    }

    private func syncSettings() {
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyInstalls = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        lastCheck = updater.lastUpdateCheckDate
    }

    private static func release(_ item: SUAppcastItem) -> AppUpdateRelease {
        AppUpdateRelease(version: item.displayVersionString, build: item.versionString)
    }

    private static func isNoUpdate(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SUSparkleErrorDomain && error.code == Int(SUError.installationCanceledError.rawValue)
    }
}

extension AppUpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if activity == .idle { activity = .checking }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        lastError = nil
        switch activity {
        case .downloading, .ready, .installing: break
        default: activity = .available(Self.release(item))
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        lastError = nil
        switch activity {
        case .checking, .available: activity = .idle
        default: break
        }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        activity = .downloading(Self.release(item))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        lastError = (error as NSError).localizedDescription
        activity = .available(Self.release(item))
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        if case .downloading(let release) = activity { activity = .available(release) }
    }

    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        stagedInstall = immediateInstallHandler
        lastError = nil
        activity = .ready(Self.release(item))
        updateLog.notice("Geraldine \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public)) is downloaded and verified")
        DispatchQueue.main.async { [weak self] in self?.evaluateStagedInstall() }
        // Geraldine owns the reminder and the restart; Sparkle still installs
        // on quit if that comes first.
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        activity = .installing(Self.release(item))
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        saveHandoff(target: activity.release)
    }

    func updater(_ updater: SPUUpdater,
                 userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip, case .available = activity { activity = .idle }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        guard !Self.isNoUpdate(error), !Self.isCancellation(error) else { return }
        lastError = (error as NSError).localizedDescription
        updateLog.error("Update failed: \(error.localizedDescription, privacy: .public)")
        switch activity {
        case .checking: activity = .idle
        case .downloading(let release), .installing(let release): activity = .available(release)
        default: break
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if activity == .checking { activity = .idle }
        syncSettings()
    }
}

extension AppUpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    /// Geraldine runs in the background. A scheduled check never opens a
    /// window over someone's work; the sidebar, menu bar panel, and Settings
    /// show the update until it is opened from there.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        activity = .available(Self.release(update))
    }
}
