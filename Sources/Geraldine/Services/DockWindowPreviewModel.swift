import AppKit
import ApplicationServices
import Observation

struct DockPreviewWindow: Identifiable {
    let id: UUID
    let element: AXUIElement
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect?
    let isMinimized: Bool

    init(element: AXUIElement, title: String, frame: CGRect?, isMinimized: Bool) {
        id = UUID()
        self.element = element
        windowID = AXTools.windowID(of: element)
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
    }

    init(windowID: CGWindowID, processIdentifier: pid_t, title: String,
         frame: CGRect?, isMinimized: Bool) {
        id = UUID()
        element = AXUIElementCreateApplication(processIdentifier)
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
    }

    private init(id: UUID, element: AXUIElement, windowID: CGWindowID?, title: String,
                 frame: CGRect?, isMinimized: Bool) {
        self.id = id
        self.element = element
        self.windowID = windowID
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
    }

    func resolving(element: AXUIElement) -> DockPreviewWindow {
        DockPreviewWindow(id: id, element: element, windowID: windowID, title: title,
                          frame: frame, isMinimized: AXTools.isMinimized(element))
    }

    var displayTitle: String { title.isEmpty ? "Untitled Window" : title }
}

struct DockPreviewActivationSelection {
    private var pending: (processIdentifier: pid_t, window: DockPreviewWindow)?

    mutating func prepare(_ window: DockPreviewWindow, processIdentifier: pid_t) {
        pending = (processIdentifier, window)
    }

    mutating func take(afterActivating processIdentifier: pid_t) -> DockPreviewWindow? {
        defer { pending = nil }
        guard pending?.processIdentifier == processIdentifier else { return nil }
        return pending?.window
    }
}

struct DockPreviewApplicationCandidate {
    let processIdentifier: pid_t
    let bundleURL: URL?
    let name: String
}

enum DockPreviewApplicationMatching {
    /// A Dock URL is stronger evidence than its label. Never select a different
    /// app with the same name when the URL is present but no longer running.
    static func processIdentifier(
        itemURL: URL?, title: String, candidates: [DockPreviewApplicationCandidate]
    ) -> pid_t? {
        let matches: [DockPreviewApplicationCandidate]
        if let itemURL {
            let path = itemURL.standardizedFileURL.resolvingSymlinksInPath().path
            matches = candidates.filter {
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
            }
        } else {
            let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }
            matches = candidates.filter {
                $0.name == label || $0.bundleURL?.deletingPathExtension().lastPathComponent == label
            }
        }
        return matches.count == 1 ? matches.first?.processIdentifier : nil
    }
}

struct DockPreviewCaptureCandidate {
    let windowID: CGWindowID
    let processIdentifier: pid_t
    let title: String
    let frame: CGRect
}

enum DockPreviewCaptureMatching {
    /// AX owns selection. ScreenCaptureKit only supplies images; ambiguous
    /// matches remain title-only instead of showing another window's contents.
    static func windowID(
        for window: DockPreviewWindow, processIdentifier: pid_t,
        windows: [DockPreviewWindow], candidates: [DockPreviewCaptureCandidate]
    ) -> CGWindowID? {
        if let windowID = window.windowID,
           candidates.contains(where: { $0.processIdentifier == processIdentifier && $0.windowID == windowID }) {
            return windowID
        }
        let appCandidates = candidates.filter { $0.processIdentifier == processIdentifier }
        if let frame = window.frame {
            let matches = appCandidates.filter {
                framesMatch(frame, $0.frame) &&
                    (window.title.isEmpty || $0.title.isEmpty || window.title == $0.title)
            }
            if matches.count == 1, let candidate = matches.first {
                let sourceMatches = windows.filter {
                    guard let sourceFrame = $0.frame else { return false }
                    return framesMatch(sourceFrame, candidate.frame) &&
                        ($0.title.isEmpty || candidate.title.isEmpty || $0.title == candidate.title)
                }
                if sourceMatches.count == 1 { return candidate.windowID }
            }
        }

        // Minimized windows can have stale geometry. A unique, nonempty title
        // on both sides is still an exact match within the same process.
        guard !window.title.isEmpty,
              windows.filter({ $0.title == window.title }).count == 1 else { return nil }
        let matches = appCandidates.filter { $0.title == window.title }
        return matches.count == 1 ? matches.first?.windowID : nil
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1 && abs(lhs.minY - rhs.minY) <= 1 &&
            abs(lhs.width - rhs.width) <= 1 && abs(lhs.height - rhs.height) <= 1
    }
}

enum DockPreviewSelectionMatching {
    static func hitTestPoints(in frame: CGRect) -> [CGPoint] {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return [] }
        return [
            CGPoint(x: frame.midX, y: frame.midY),
            CGPoint(x: frame.minX + frame.width * 0.15, y: frame.minY + frame.height * 0.15),
            CGPoint(x: frame.maxX - frame.width * 0.15, y: frame.minY + frame.height * 0.15),
            CGPoint(x: frame.minX + frame.width * 0.15, y: frame.maxY - frame.height * 0.15),
            CGPoint(x: frame.maxX - frame.width * 0.15, y: frame.maxY - frame.height * 0.15)
        ]
    }
}

enum DockPreviewWindowSnapshotMatching {
    static func equivalent(_ lhs: [DockPreviewWindow], _ rhs: [DockPreviewWindow]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var unmatched = rhs
        for window in lhs {
            guard let index = unmatched.firstIndex(where: { matches(window, $0) }) else { return false }
            unmatched.remove(at: index)
        }
        return unmatched.isEmpty
    }

    private static func matches(_ lhs: DockPreviewWindow, _ rhs: DockPreviewWindow) -> Bool {
        if let lhsID = lhs.windowID, let rhsID = rhs.windowID, lhsID != rhsID { return false }
        guard lhs.title == rhs.title, lhs.isMinimized == rhs.isMinimized else { return false }
        switch (lhs.frame, rhs.frame) {
        case (nil, nil):
            return true
        case let (lhsFrame?, rhsFrame?):
            return abs(lhsFrame.minX - rhsFrame.minX) <= 1
                && abs(lhsFrame.minY - rhsFrame.minY) <= 1
                && abs(lhsFrame.width - rhsFrame.width) <= 1
                && abs(lhsFrame.height - rhsFrame.height) <= 1
        default:
            return false
        }
    }
}

enum DockPreviewEdge: String, CaseIterable {
    case bottom, left, right
}

enum DockPreviewHoverMatching {
    static func accepts(queriedPoint: CGPoint, currentPoint: CGPoint, targetFrame: CGRect?) -> Bool {
        targetFrame?.contains(currentPoint) ?? (queriedPoint == currentPoint)
    }
}

struct DockPreviewContextMenuSuppression {
    private(set) var isActive = false

    mutating func begin() {
        isActive = true
    }

    mutating func allowsHover(afterCheckingDockMenu isMenuActive: Bool) -> Bool {
        guard isActive else { return true }
        guard !isMenuActive else { return false }
        isActive = false
        return true
    }

    mutating func reset() {
        isActive = false
    }
}

enum DockPreviewLayout {
    static let thumbnailSize = CGSize(width: 200, height: 126)
    static let spacing: CGFloat = 8
    static let screenMargin: CGFloat = 8

    static func cardSize(for window: DockPreviewWindow) -> CGSize {
        guard let frame = window.frame, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return thumbnailSize }
        let scale = min(thumbnailSize.width / frame.width, thumbnailSize.height / frame.height)
        return CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    static func contentSize(windows: [DockPreviewWindow]) -> CGSize {
        let sizes = windows.map { cardSize(for: $0) }
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing,
                      height: sizes.map(\.height).max() ?? thumbnailSize.height)
    }

    static func initiallyVisibleWindowIDs(windows: [DockPreviewWindow], viewportWidth: CGFloat) -> Set<UUID> {
        guard viewportWidth > 0 else { return [] }
        var x: CGFloat = 0
        var visible: Set<UUID> = []
        for window in windows {
            if x >= viewportWidth { break }
            visible.insert(window.id)
            x += cardSize(for: window).width + spacing
        }
        return visible
    }

    static func panelFrame(
        itemFrame: CGRect, edge: DockPreviewEdge, visibleFrame: CGRect, windows: [DockPreviewWindow]
    ) -> CGRect {
        let bounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let content = contentSize(windows: windows)
        let size = CGSize(width: min(content.width, max(1, bounds.width)),
                          height: min(content.height, max(1, bounds.height)))
        let origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: itemFrame.midX - size.width / 2, y: itemFrame.maxY + spacing)
        case .left:
            origin = CGPoint(x: itemFrame.maxX + spacing, y: itemFrame.midY - size.height / 2)
        case .right:
            origin = CGPoint(x: itemFrame.minX - spacing - size.width, y: itemFrame.midY - size.height / 2)
        }
        return CGRect(
            x: min(max(origin.x, bounds.minX), bounds.maxX - size.width),
            y: min(max(origin.y, bounds.minY), bounds.maxY - size.height),
            width: size.width, height: size.height
        )
    }

    static func edge(for itemFrame: CGRect, in screenFrame: CGRect) -> DockPreviewEdge {
        let distances: [(DockPreviewEdge, CGFloat)] = [
            (.bottom, abs(itemFrame.minY - screenFrame.minY)),
            (.left, abs(itemFrame.minX - screenFrame.minX)),
            (.right, abs(screenFrame.maxX - itemFrame.maxX))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenMaxY - frame.maxY, width: frame.width, height: frame.height)
    }

    static func appKitPoint(fromQuartz point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func quartzPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    static func keepsPreviewOpen(
        at point: CGPoint, itemFrame: CGRect, panelFrame: CGRect, edge: DockPreviewEdge
    ) -> Bool {
        if itemFrame.contains(point) || panelFrame.contains(point) { return true }
        // Only bridge the gap, not the entire bounding rectangle: neighboring
        // Dock icons must still be able to replace the current preview.
        let corridor: CGRect
        switch edge {
        case .bottom:
            corridor = CGRect(x: min(itemFrame.minX, panelFrame.minX), y: itemFrame.maxY,
                              width: max(itemFrame.maxX, panelFrame.maxX) - min(itemFrame.minX, panelFrame.minX),
                              height: max(0, panelFrame.minY - itemFrame.maxY))
        case .left:
            corridor = CGRect(x: itemFrame.maxX, y: min(itemFrame.minY, panelFrame.minY),
                              width: max(0, panelFrame.minX - itemFrame.maxX),
                              height: max(itemFrame.maxY, panelFrame.maxY) - min(itemFrame.minY, panelFrame.minY))
        case .right:
            corridor = CGRect(x: panelFrame.maxX, y: min(itemFrame.minY, panelFrame.minY),
                              width: max(0, itemFrame.minX - panelFrame.maxX),
                              height: max(itemFrame.maxY, panelFrame.maxY) - min(itemFrame.minY, panelFrame.minY))
        }
        return corridor.insetBy(dx: -2, dy: -2).contains(point)
    }

    static func isInDockItemBand(_ point: CGPoint, itemFrame: CGRect, edge: DockPreviewEdge) -> Bool {
        switch edge {
        case .bottom:
            return point.y >= itemFrame.minY - spacing && point.y <= itemFrame.maxY + spacing
        case .left, .right:
            return point.x >= itemFrame.minX - spacing && point.x <= itemFrame.maxX + spacing
        }
    }
}

enum DockPreviewThumbnail {
    case loading
    case image(NSImage)
    case unavailable

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var hasImage: Bool {
        if case .image = self { return true }
        return false
    }
}

@MainActor
@Observable
final class DockWindowPreviewSession {
    let appName: String
    var appIcon: NSImage?
    let processIdentifier: pid_t
    let windows: [DockPreviewWindow]
    let screenRecordingAllowed: Bool
    var thumbnails: [UUID: DockPreviewThumbnail]
    var selectionError: String?

    init(appName: String, appIcon: NSImage?, processIdentifier: pid_t,
         windows: [DockPreviewWindow], screenRecordingAllowed: Bool) {
        self.appName = appName
        self.appIcon = appIcon
        self.processIdentifier = processIdentifier
        self.windows = windows
        self.screenRecordingAllowed = screenRecordingAllowed
        thumbnails = Dictionary(uniqueKeysWithValues: windows.map {
            ($0.id, screenRecordingAllowed ? .loading : .unavailable)
        })
    }

    @discardableResult
    func select(_ id: UUID, activate: (DockPreviewWindow) -> Bool) -> Bool {
        guard let window = windows.first(where: { $0.id == id }) else { return false }
        guard activate(window) else {
            selectionError = "Couldn’t show this window. Hover again to refresh, or check Accessibility access."
            return false
        }
        selectionError = nil
        return true
    }
}
