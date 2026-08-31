import AppKit
import ApplicationServices
import ScreenCaptureKit

struct DockPreviewTarget {
    let app: NSRunningApplication
    /// Accessibility uses global, top-left-origin (Quartz) coordinates.
    let itemFrame: CGRect
}

enum DockWindowPreviewAccessibility {
    static func dockProcessIdentifier() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    static func warmHoverPath(dockProcessIdentifier: pid_t) {
        let dockElement = AXUIElementCreateApplication(dockProcessIdentifier)
        var ignored: CFTypeRef?
        AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &ignored)
        _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    }

    static func applicationCandidates() -> [DockPreviewApplicationCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated,
                  app.activationPolicy == .regular || app.bundleIdentifier == "com.apple.finder" else { return nil }
            return DockPreviewApplicationCandidate(
                processIdentifier: app.processIdentifier,
                bundleURL: app.bundleURL,
                name: app.localizedName ?? ""
            )
        }
    }

    static func applicationItemFrames(dockProcessIdentifier: pid_t) -> [CGRect] {
        var visited: [AXUIElement] = []
        return applicationItemFrames(
            in: AXUIElementCreateApplication(dockProcessIdentifier), visited: &visited
        )
    }

    private static func applicationItemFrames(
        in element: AXUIElement, visited: inout [AXUIElement]
    ) -> [CGRect] {
        guard !visited.contains(where: { CFEqual($0, element) }) else { return [] }
        visited.append(element)
        var frames: [CGRect] = []
        if AXTools.string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
           let frame = AXTools.frame(of: element), frame.width > 0, frame.height > 0 {
            frames.append(frame)
        }
        var rawChildren: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &rawChildren
        ) == .success, let children = rawChildren as? [AXUIElement] {
            for child in children {
                frames += applicationItemFrames(in: child, visited: &visited)
            }
        }
        return frames
    }

    static func isDockContextMenuActive(at point: CGPoint, dockProcessIdentifier: pid_t) -> Bool {
        let dockElement = AXUIElementCreateApplication(dockProcessIdentifier)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hit) == .success,
           let hit, hasMenuAncestor(hit) {
            return true
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockElement, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return false }
        return hasMenuAncestor(focused as! AXUIElement)
    }

    private static func hasMenuAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        var visited: [AXUIElement] = []
        while let candidate = current {
            guard !visited.contains(where: { CFEqual($0, candidate) }) else { return false }
            visited.append(candidate)
            let role = AXTools.string(candidate, kAXRoleAttribute)
            if role == kAXMenuRole || role == kAXMenuItemRole { return true }
            current = AXTools.parent(of: candidate)
        }
        return false
    }

    static func target(
        at point: CGPoint, dockProcessIdentifier: pid_t,
        candidates: [DockPreviewApplicationCandidate]
    ) -> DockPreviewTarget? {
        // Restrict hit testing to the Dock so ordinary pointer movement never
        // waits on an unrelated application's accessibility implementation.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(dockProcessIdentifier),
                                               Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }
        var hitProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &hitProcessIdentifier) == .success,
              hitProcessIdentifier == dockProcessIdentifier else { return nil }

        var current: AXUIElement? = element
        var visited: [AXUIElement] = []
        while let candidate = current {
            guard !visited.contains(where: { CFEqual($0, candidate) }) else { return nil }
            visited.append(candidate)
            if AXTools.string(candidate, kAXSubroleAttribute) == "AXApplicationDockItem" {
                return target(for: candidate, candidates: candidates)
            }
            current = AXTools.parent(of: candidate)
        }
        return nil
    }

    private static func target(
        for item: AXUIElement, candidates: [DockPreviewApplicationCandidate]
    ) -> DockPreviewTarget? {
        guard let frame = AXTools.frame(of: item), frame.width > 0, frame.height > 0 else { return nil }
        let title = AXTools.string(item, kAXTitleAttribute) ?? AXTools.string(item, kAXDescriptionAttribute) ?? ""
        guard let pid = DockPreviewApplicationMatching.processIdentifier(
            itemURL: AXTools.fileURL(of: item), title: title, candidates: candidates
        ), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
        return DockPreviewTarget(app: app, itemFrame: frame)
    }

    static func windows(of app: NSRunningApplication) -> [DockPreviewWindow] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows)
        guard result == .success, let elements = rawWindows as? [AXUIElement] else {
            return visibleWindows(processIdentifier: app.processIdentifier)
        }
        var windows: [DockPreviewWindow] = []
        for element in elements {
            guard AXTools.string(element, kAXRoleAttribute) == kAXWindowRole,
                  !windows.contains(where: { CFEqual($0.element, element) }) else { continue }
            windows.append(DockPreviewWindow(
                element: element,
                title: (AXTools.string(element, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                frame: AXTools.frame(of: element), isMinimized: AXTools.isMinimized(element)
            ))
        }
        return windows.isEmpty ? visibleWindows(processIdentifier: app.processIdentifier) : windows
    }

    static func visibleWindows(processIdentifier: pid_t) -> [DockPreviewWindow] {
        let information = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var seen: Set<CGWindowID> = []
        return information.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 0, bounds.height > 0 else { return nil }
            let windowID = number.uint32Value
            guard seen.insert(windowID).inserted else { return nil }
            let title = (entry[kCGWindowName as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isOnscreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return DockPreviewWindow(
                windowID: windowID, processIdentifier: processIdentifier, title: title,
                frame: bounds, isMinimized: !isOnscreen && alpha == 0
            )
        }
    }

    @MainActor
    static func show(_ window: DockPreviewWindow, processIdentifier: pid_t) -> Bool {
        guard Permissions.hasAccessibilityAccess(),
              let app = NSRunningApplication(processIdentifier: processIdentifier), !app.isTerminated else { return false }
        guard let element = resolvedElement(for: window, app: app) else { return false }
        let resolvedWindow = window.resolving(element: element)

        // Recheck live state: the window may have been minimized after hovering.
        if AXTools.isMinimized(element) {
            guard AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                               kCFBooleanFalse) == .success else { return false }
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        guard raised else { return false }
        // Do not activateAllWindows or synthesize Cmd-`: selection retains the
        // exact AX window even when several windows share the same title.
        let activated = WindowActionService.activate(app, selecting: resolvedWindow)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        return activated
    }

    private static func resolvedElement(for window: DockPreviewWindow,
                                        app: NSRunningApplication) -> AXUIElement? {
        let windows = AXTools.windows(of: app)
        guard let windowID = window.windowID else {
            return windows.first(where: { CFEqual($0, window.element) })
        }
        if let resolved = windows.first(where: { AXTools.windowID(of: $0) == windowID }) {
            return resolved
        }

        // Some apps intermittently expose an empty AXWindows list even though
        // their visible window tree remains hit-testable. Resolve only within
        // that app and accept only the exact WindowServer ID; never guess from
        // title, ordering, or an overlapping window.
        guard let frame = window.frame else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for point in DockPreviewSelectionMatching.hitTestPoints(in: frame) {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit) == .success,
                  let hit, let candidate = AXTools.window(containing: hit),
                  AXTools.windowID(of: candidate) == windowID else { continue }
            return candidate
        }
        return nil
    }
}

// SCWindow is a read-only ScreenCaptureKit snapshot. Only its immutable
// reference and value metadata cross from lookup to the main-actor capture UI.
struct DockPreviewCaptureSource: @unchecked Sendable {
    let window: SCWindow
    let candidate: DockPreviewCaptureCandidate
}

typealias DockPreviewContentRequest = Task<[DockPreviewCaptureSource], Error>

@MainActor
enum DockPreviewCaptureScheduling {
    static func load(windows: [DockPreviewWindow], initiallyVisible: Set<UUID>,
                     capture: @escaping @MainActor (DockPreviewWindow) async -> Void) async {
        // The viewport determines the parallel work, not the total number of
        // open windows. Offscreen thumbnails keep their previous serial path.
        await withTaskGroup(of: Void.self) { group in
            for window in windows where initiallyVisible.contains(window.id) {
                guard !Task.isCancelled else { break }
                group.addTask { @MainActor in
                    guard !Task.isCancelled else { return }
                    await capture(window)
                }
            }
        }
        for window in windows where !initiallyVisible.contains(window.id) {
            guard !Task.isCancelled else { return }
            await capture(window)
        }
    }
}

@MainActor
enum DockWindowPreviewCapture {
    nonisolated static func prepare(processIdentifier: pid_t) -> DockPreviewContentRequest {
        Task(priority: .userInitiated) {
            try Task.checkCancellation()
            guard Permissions.hasScreenRecordingAccess() else { return [] }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            try Task.checkCancellation()
            return content.windows.compactMap { window in
                guard window.owningApplication?.processID == processIdentifier, window.windowLayer == 0 else { return nil }
                return DockPreviewCaptureSource(window: window, candidate: DockPreviewCaptureCandidate(
                    windowID: window.windowID, processIdentifier: processIdentifier,
                    title: (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines), frame: window.frame
                ))
            }
        }
    }

    static func loadThumbnails(for session: DockWindowPreviewSession, scale: CGFloat,
                               viewportWidth: CGFloat, contentRequest: DockPreviewContentRequest?) async {
        guard !Task.isCancelled else { contentRequest?.cancel(); return }
        guard session.screenRecordingAllowed else {
            contentRequest?.cancel()
            for window in session.windows { session.thumbnails[window.id] = .unavailable }
            return
        }
        let request = contentRequest ?? prepare(processIdentifier: session.processIdentifier)
        defer { request.cancel() }
        do {
            let sources = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard !Task.isCancelled else { return }
            let candidates = sources.map(\.candidate)
            await DockPreviewCaptureScheduling.load(
                windows: session.windows,
                initiallyVisible: DockPreviewLayout.initiallyVisibleWindowIDs(windows: session.windows, viewportWidth: viewportWidth)
            ) { window in
                guard !Task.isCancelled else { return }
                guard let windowID = DockPreviewCaptureMatching.windowID(
                    for: window, processIdentifier: session.processIdentifier,
                    windows: session.windows, candidates: candidates
                ), let source = sources.first(where: { $0.candidate.windowID == windowID }),
                   source.candidate.frame.width > 0, source.candidate.frame.height > 0 else {
                    session.thumbnails[window.id] = .unavailable
                    return
                }
                do {
                    let image = try await captureImage(source: source, scale: scale)
                    guard !Task.isCancelled else { return }
                    session.thumbnails[window.id] = .image(NSImage(cgImage: image, size: .zero))
                } catch {
                    guard !Task.isCancelled else { return }
                    session.thumbnails[window.id] = .unavailable
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            for window in session.windows { session.thumbnails[window.id] = .unavailable }
        }
    }

    private static func captureImage(source: DockPreviewCaptureSource, scale: CGFloat) async throws -> CGImage {
        try Task.checkCancellation()
        let frame = source.candidate.frame
        let imageScale = min(DockPreviewLayout.thumbnailSize.width * scale / frame.width,
                             DockPreviewLayout.thumbnailSize.height * scale / frame.height)
        let width = max(1, Int(frame.width * imageScale))
        let height = max(1, Int(frame.height * imageScale))
        let filter = SCContentFilter(desktopIndependentWindow: source.window)
        if #available(macOS 26.0, *) {
            // Use the dedicated still-image path instead of initializing the
            // older stream-configured screenshot path on current macOS.
            let config = SCScreenshotConfiguration()
            config.width = width
            config.height = height
            config.showsCursor = false
            config.ignoreShadows = true
            config.dynamicRange = .sdr
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config)
            guard let image = output.sdrImage else { throw CaptureError.missingImage }
            return image
        }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private enum CaptureError: Error { case missingImage }
}
