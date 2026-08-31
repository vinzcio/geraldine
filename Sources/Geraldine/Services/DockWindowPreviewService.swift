import AppKit

@MainActor
final class DockWindowPreviewService {
    private struct DisplaySnapshot {
        struct Screen {
            let frame: CGRect
            let visibleFrame: CGRect
            let backingScaleFactor: CGFloat
        }

        let primaryScreenMaxY: CGFloat
        let screens: [Screen]
    }

    private struct Presentation {
        let itemFrame: CGRect
        let quartzItemFrame: CGRect
        let edge: DockPreviewEdge
        let session: DockWindowPreviewSession
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private lazy var pointerTap = EventTapService(
        mask: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
        options: .listenOnly
    ) { [weak self] type, event in
        guard type == .mouseMoved else { return false }
        self?.handlePointerMoved(fromQuartz: event.location)
        return false
    }
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var captureTask: Task<Void, Never>?
    private var presentation: Presentation?
    private let panel = DockWindowPreviewPanelController()
    private let lookupQueue = DispatchQueue(label: "com.vincent.geraldine.dock-window-lookup", qos: .userInitiated)
    private let windowSnapshotQueue = DispatchQueue(
        label: "com.vincent.geraldine.dock-window-snapshots", qos: .utility, attributes: .concurrent
    )
    private let iconQueue = DispatchQueue(label: "com.vincent.geraldine.dock-window-icon", qos: .utility)
    private var lookupInFlight = false
    private var pendingPoint: CGPoint?
    private var hoverGeneration = UUID()
    private var contextMenuSuppression = DockPreviewContextMenuSuppression()
    private var contextMenuCheckInFlight = false
    private var displaySnapshot: DisplaySnapshot?
    private var dockProcessIdentifier: pid_t?
    private var dockApplicationItemFrames: [CGRect] = []
    private var applicationCandidates: [DockPreviewApplicationCandidate] = []
    private var windowSnapshots: [pid_t: [DockPreviewWindow]] = [:]
    private var windowSnapshotGenerations: [pid_t: UUID] = [:]
    private var screenRecordingAllowed = false

    private var isRunning: Bool { localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        // Build every stable dependency before the first hover. The live path
        // only hit-tests the Dock and enumerates the selected app's windows.
        refreshDisplaySnapshot()
        refreshDockProcessIdentifier()
        refreshApplicationCandidates()
        screenRecordingAllowed = Permissions.hasScreenRecordingAccess()
        panel.prepare()
        if let dockProcessIdentifier {
            // Panel preparation allocates its WindowServer surface. Warm the
            // shared connection again afterward so the first hover does not.
            DockWindowPreviewAccessibility.warmHoverPath(dockProcessIdentifier: dockProcessIdentifier)
        }
        let pointerTapStarted = pointerTap.start()
        var events: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyDown
        ]
        if !pointerTapStarted { events.insert(.mouseMoved) }
        // NSEvent monitor callbacks run on the main thread. Both monitors only
        // observe events: Dock clicks and keyboard input are never swallowed.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.bundleIdentifier == "com.apple.dock" {
                    self.refreshDockProcessIdentifier()
                }
                self.refreshApplicationCandidates()
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier == self.presentation?.session.processIdentifier else { return }
                self.dismiss()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.bundleIdentifier == "com.apple.dock" {
                    self.refreshDockProcessIdentifier()
                }
                self.refreshApplicationCandidates()
            }
        })
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshDisplaySnapshot()
                self?.dismiss()
            }
        }
        warmWindowSnapshots(for: applicationCandidates)
    }

    func updateScreenRecordingAccess(_ allowed: Bool) {
        screenRecordingAllowed = allowed
    }

    func stop() {
        pointerTap.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        contextMenuSuppression.reset()
        contextMenuCheckInFlight = false
        windowSnapshots.removeAll()
        windowSnapshotGenerations.removeAll()
        dockApplicationItemFrames.removeAll()
        dismiss()
        panel.stop()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            handlePointerMoved(to: NSEvent.mouseLocation)
        case .rightMouseDown:
            // Give the Dock's native contextual menu exclusive ownership of
            // this interaction. Later movement checks the live AX menu before
            // normal hover work is allowed to resume.
            contextMenuSuppression.begin()
            dismiss()
        case .leftMouseDown:
            if !panel.contains(NSEvent.mouseLocation) { dismiss() }
        default:
            // Typing, secondary clicks, and dragging dismiss the hover UI but
            // continue to their original recipient unchanged.
            dismiss()
        }
    }

    private func handlePointerMoved(fromQuartz point: CGPoint) {
        guard let displaySnapshot else { return }
        handlePointerMoved(to: DockPreviewLayout.appKitPoint(
            fromQuartz: point, primaryScreenMaxY: displaySnapshot.primaryScreenMaxY
        ))
    }

    private func handlePointerMoved(to point: CGPoint) {
        if contextMenuSuppression.isActive {
            pendingPoint = point
            refreshContextMenuSuppression()
            return
        }
        guard NSEvent.pressedMouseButtons == 0 else { dismiss(); return }
        pointerMoved(to: point)
    }

    private func refreshContextMenuSuppression() {
        guard isRunning, contextMenuSuppression.isActive, !contextMenuCheckInFlight,
              let point = pendingPoint, let displaySnapshot, let dockProcessIdentifier else { return }
        let generation = hoverGeneration
        let quartzPoint = DockPreviewLayout.quartzPoint(
            fromAppKit: point, primaryScreenMaxY: displaySnapshot.primaryScreenMaxY
        )
        contextMenuCheckInFlight = true
        lookupQueue.async { [weak self] in
            let menuIsActive = DockWindowPreviewAccessibility.isDockContextMenuActive(
                at: quartzPoint, dockProcessIdentifier: dockProcessIdentifier
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.contextMenuCheckInFlight = false
                guard self.isRunning, generation == self.hoverGeneration,
                      self.contextMenuSuppression.allowsHover(afterCheckingDockMenu: menuIsActive) else { return }
                guard let latestPoint = self.pendingPoint else { return }
                self.pendingPoint = nil
                self.pointerMoved(to: latestPoint)
            }
        }
    }

    private func pointerMoved(to point: CGPoint) {
        if let presentation, let panelFrame = panel.frame,
           DockPreviewLayout.keepsPreviewOpen(at: point, itemFrame: presentation.itemFrame,
                                             panelFrame: panelFrame, edge: presentation.edge) {
            hoverGeneration = UUID()
            pendingPoint = nil
            return
        }
        if let presentation,
           !DockPreviewLayout.isInDockItemBand(point, itemFrame: presentation.itemFrame,
                                               edge: presentation.edge) {
            dismissPresentation()
        }
        pendingPoint = point
        if presentation == nil, presentCachedPreview(at: point) { return }
        // Start immediately. While AX is busy, coalesce movement into the
        // latest point instead of restarting a hover dwell or queuing work.
        resolveHover()
    }

    private func presentCachedPreview(at point: CGPoint) -> Bool {
        guard let displaySnapshot, let dockProcessIdentifier else { return false }
        let quartzPoint = DockPreviewLayout.quartzPoint(
            fromAppKit: point, primaryScreenMaxY: displaySnapshot.primaryScreenMaxY
        )
        // Keep synchronous work out of ordinary mouse movement. The Dock's
        // own AX hit-test is only used when the point is already inside one
        // of its known application-item frames.
        guard dockApplicationItemFrames.contains(where: { $0.contains(quartzPoint) }),
              let target = DockWindowPreviewAccessibility.target(
                at: quartzPoint, dockProcessIdentifier: dockProcessIdentifier,
                candidates: applicationCandidates
              ), !target.app.isTerminated else { return false }
        let processIdentifier = target.app.processIdentifier
        let cachedWindows = windowSnapshots[processIdentifier] ?? []
        let windows = cachedWindows.isEmpty
            ? DockWindowPreviewAccessibility.visibleWindows(processIdentifier: processIdentifier)
            : cachedWindows
        guard !windows.isEmpty else { return false }
        if cachedWindows.isEmpty {
            windowSnapshots[processIdentifier] = windows
            windowSnapshotGenerations[processIdentifier] = UUID()
        }
        hoverGeneration = UUID()
        pendingPoint = nil
        present(target: target, windows: windows, refreshWindows: true)
        return true
    }

    private func resolveHover() {
        guard isRunning, !lookupInFlight, let point = pendingPoint,
              let displaySnapshot, let dockProcessIdentifier else { return }
        let generation = hoverGeneration
        let primaryScreenMaxY = displaySnapshot.primaryScreenMaxY
        let candidates = applicationCandidates
        let snapshots = windowSnapshots
        let quartzPoint = DockPreviewLayout.quartzPoint(fromAppKit: point, primaryScreenMaxY: primaryScreenMaxY)
        lookupInFlight = true
        // AX messaging can wait for another app. Keep it off the UI thread,
        // with only one lookup in flight; stale results never open a panel.
        lookupQueue.async { [weak self] in
            let target = DockWindowPreviewAccessibility.target(
                at: quartzPoint, dockProcessIdentifier: dockProcessIdentifier, candidates: candidates
            )
            let cachedWindows = target.flatMap { snapshots[$0.app.processIdentifier] } ?? []
            let visibleWindows = target.map {
                cachedWindows.isEmpty
                    ? DockWindowPreviewAccessibility.visibleWindows(processIdentifier: $0.app.processIdentifier)
                    : []
            } ?? []
            let immediateWindows = cachedWindows.isEmpty ? visibleWindows : cachedWindows
            let shouldRefreshWindows = !immediateWindows.isEmpty
            let windows = shouldRefreshWindows
                ? immediateWindows
                : (target.map { DockWindowPreviewAccessibility.windows(of: $0.app) } ?? [])
            DispatchQueue.main.async {
                guard let self else { return }
                self.lookupInFlight = false
                guard self.isRunning else { return }
                guard generation == self.hoverGeneration, let latestPoint = self.pendingPoint else {
                    self.resolveHover()
                    return
                }
                let latestQuartzPoint = DockPreviewLayout.quartzPoint(
                    fromAppKit: latestPoint, primaryScreenMaxY: primaryScreenMaxY
                )
                // Movement within the same Dock item must not postpone its
                // preview. A result for an item already left is discarded.
                guard DockPreviewHoverMatching.accepts(queriedPoint: quartzPoint, currentPoint: latestQuartzPoint,
                                                       targetFrame: target?.itemFrame) else {
                    self.resolveHover()
                    return
                }
                self.pendingPoint = nil
                guard let target, !target.app.isTerminated, !windows.isEmpty else {
                    self.dismissPresentation()
                    return
                }
                if !shouldRefreshWindows {
                    self.windowSnapshots[target.app.processIdentifier] = windows
                    self.windowSnapshotGenerations[target.app.processIdentifier] = UUID()
                }
                self.present(target: target, windows: windows, refreshWindows: shouldRefreshWindows)
            }
        }
    }

    private func present(target: DockPreviewTarget, windows: [DockPreviewWindow], refreshWindows: Bool = true) {
        guard let displaySnapshot else { return }
        let itemFrame = DockPreviewLayout.appKitFrame(fromQuartz: target.itemFrame,
                                                     primaryScreenMaxY: displaySnapshot.primaryScreenMaxY)
        guard let screen = displaySnapshot.screens.first(where: {
            $0.frame.contains(CGPoint(x: itemFrame.midX, y: itemFrame.midY))
        }) else { return }
        let edge = DockPreviewLayout.edge(for: itemFrame, in: screen.frame)
        let frame = DockPreviewLayout.panelFrame(itemFrame: itemFrame, edge: edge,
                                                visibleFrame: screen.visibleFrame, windows: windows)
        let session = DockWindowPreviewSession(
            appName: target.app.localizedName ?? "Windows", appIcon: nil,
            processIdentifier: target.app.processIdentifier, windows: windows,
            screenRecordingAllowed: screenRecordingAllowed
        )
        captureTask?.cancel()
        captureTask = nil
        presentation = Presentation(itemFrame: itemFrame, quartzItemFrame: target.itemFrame,
                                    edge: edge, session: session)
        panel.show(session: session, frame: frame, select: { [weak self, weak session] id in
            guard let self, let session else { return }
            if session.select(id, activate: {
                DockWindowPreviewAccessibility.show($0, processIdentifier: session.processIdentifier)
            }) {
                self.dismiss()
            }
        })
        let processIdentifier = target.app.processIdentifier
        iconQueue.async { [weak self, weak session] in
            let icon = NSRunningApplication(processIdentifier: processIdentifier)?.icon
            DispatchQueue.main.async {
                guard let self, let session, self.presentation?.session === session else { return }
                session.appIcon = icon
            }
        }
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.presentation?.session === session else { return }
            self.captureTask = Task {
                await DockWindowPreviewCapture.loadThumbnails(for: session, scale: screen.backingScaleFactor,
                                                              viewportWidth: frame.width, contentRequest: nil)
            }
        }
        if refreshWindows { refreshWindowSnapshot(for: target) }
    }

    private func refreshDisplaySnapshot() {
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            displaySnapshot = nil
            return
        }
        displaySnapshot = DisplaySnapshot(
            primaryScreenMaxY: primaryScreen.frame.maxY,
            screens: screens.map {
                DisplaySnapshot.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame,
                                       backingScaleFactor: $0.backingScaleFactor)
            }
        )
    }

    private func refreshApplicationCandidates() {
        applicationCandidates = DockWindowPreviewAccessibility.applicationCandidates()
        let liveProcessIdentifiers = Set(applicationCandidates.map(\.processIdentifier))
        windowSnapshots = windowSnapshots.filter { liveProcessIdentifiers.contains($0.key) }
        windowSnapshotGenerations = windowSnapshotGenerations.filter { liveProcessIdentifiers.contains($0.key) }
        refreshDockApplicationItemFrames()
    }

    private func warmWindowSnapshots(for candidates: [DockPreviewApplicationCandidate]) {
        for candidate in candidates {
            guard let app = NSRunningApplication(processIdentifier: candidate.processIdentifier),
                  !app.isTerminated else { continue }
            let generation = UUID()
            windowSnapshotGenerations[app.processIdentifier] = generation
            windowSnapshotQueue.async { [weak self] in
                let windows = DockWindowPreviewAccessibility.windows(of: app)
                DispatchQueue.main.async {
                    guard let self, self.isRunning, !app.isTerminated, !windows.isEmpty,
                          self.windowSnapshotGenerations[app.processIdentifier] == generation else { return }
                    self.windowSnapshots[app.processIdentifier] = windows
                }
            }
        }
    }

    private func refreshWindowSnapshot(for target: DockPreviewTarget) {
        let processIdentifier = target.app.processIdentifier
        let generation = UUID()
        windowSnapshotGenerations[processIdentifier] = generation
        windowSnapshotQueue.async { [weak self] in
            let windows = DockWindowPreviewAccessibility.windows(of: target.app)
            DispatchQueue.main.async {
                guard let self, self.isRunning, !target.app.isTerminated,
                      self.windowSnapshotGenerations[processIdentifier] == generation else { return }
                if windows.isEmpty {
                    self.windowSnapshots.removeValue(forKey: processIdentifier)
                    return
                }
                self.windowSnapshots[processIdentifier] = windows
                guard let presentation = self.presentation,
                      presentation.session.processIdentifier == processIdentifier,
                      !DockPreviewWindowSnapshotMatching.equivalent(presentation.session.windows, windows) else {
                    return
                }
                self.present(
                    target: DockPreviewTarget(app: target.app, itemFrame: presentation.quartzItemFrame),
                    windows: windows, refreshWindows: false
                )
            }
        }
    }

    private func refreshDockProcessIdentifier() {
        dockProcessIdentifier = DockWindowPreviewAccessibility.dockProcessIdentifier()
        if let dockProcessIdentifier {
            DockWindowPreviewAccessibility.warmHoverPath(dockProcessIdentifier: dockProcessIdentifier)
        }
        refreshDockApplicationItemFrames()
    }

    private func refreshDockApplicationItemFrames() {
        guard let dockProcessIdentifier else {
            dockApplicationItemFrames = []
            return
        }
        dockApplicationItemFrames = DockWindowPreviewAccessibility.applicationItemFrames(
            dockProcessIdentifier: dockProcessIdentifier
        )
    }

    private func dismissPresentation() {
        captureTask?.cancel()
        captureTask = nil
        panel.dismiss()
        presentation = nil
    }

    private func dismiss() {
        hoverGeneration = UUID()
        pendingPoint = nil
        dismissPresentation()
    }
}
