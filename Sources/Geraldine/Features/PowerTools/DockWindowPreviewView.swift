import AppKit
import ApplicationServices
import Observation
import SwiftUI

struct DockWindowPreviewView: View {
    let session: DockWindowPreviewSession
    let select: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: DockPreviewLayout.spacing) {
                ForEach(session.windows) { window in
                    DockWindowPreviewCard(window: window,
                                          thumbnail: session.thumbnails[window.id] ?? .unavailable,
                                          appIcon: session.appIcon, reduceMotion: reduceMotion) {
                        select(window.id)
                    }
                }
            }
        }
        .frame(height: DockPreviewLayout.contentSize(windows: session.windows).height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.appName) window previews")
        .accessibilityValue(session.selectionError ?? "")
    }
}

struct DockWindowPreviewCard: View {
    let window: DockPreviewWindow
    let thumbnail: DockPreviewThumbnail
    let appIcon: NSImage?
    let reduceMotion: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        let size = DockPreviewLayout.cardSize(for: window)
        Button(action: select) {
            ZStack {
                switch thumbnail {
                case .image(let image):
                    Image(nsImage: image).resizable().scaledToFit()
                        .transition(DockPreviewImageReveal.transition(reduceMotion: reduceMotion))
                case .loading:
                    Rectangle().fill(.ultraThinMaterial)
                        .transition(.opacity)
                case .unavailable:
                    Theme.surfaceMuted
                    if let appIcon {
                        Image(nsImage: appIcon).resizable().frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "macwindow").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
            // Only the contents resolve. The card, outline, and panel never
            // scale or move as individual window captures finish.
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: thumbnail.isLoading)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .strokeBorder(isHovered ? Theme.focusRing : (colorScheme == .dark ? Color.white : Color.black).opacity(0.1),
                                  lineWidth: isHovered ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!thumbnail.isLoading)
        .onHover { isHovered = $0 }
        .accessibilityHidden(thumbnail.isLoading)
        .accessibilityLabel(window.displayTitle)
        .accessibilityValue(thumbnail.hasImage ? "Preview available" : "Preview unavailable")
        .accessibilityHint(window.isMinimized ? "Restore and show this window" : "Show this window")
    }
}

struct DockPreviewImageReveal: AnimatableModifier {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .blur(radius: 3 * (1 - progress))
            .opacity(0.6 + 0.4 * progress)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .modifier(active: Self(progress: 0), identity: Self(progress: 1)),
            removal: .identity
        )
    }
}

private final class DockPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
@Observable
private final class DockPreviewPanelContent {
    var session: DockWindowPreviewSession?
    @ObservationIgnored var select: (UUID) -> Void = { _ in }

    init(session: DockWindowPreviewSession? = nil) {
        self.session = session
    }

    func show(session: DockWindowPreviewSession, select: @escaping (UUID) -> Void) {
        self.select = select
        self.session = session
    }

    func reset() {
        session = nil
        select = { _ in }
    }
}

private struct DockPreviewPanelRootView: View {
    let content: DockPreviewPanelContent

    var body: some View {
        Group {
            if let session = content.session {
                DockWindowPreviewView(session: session, select: content.select)
            } else {
                Theme.surfaceMuted
            }
        }
    }
}

private final class DockPreviewHostingView: NSHostingView<DockPreviewPanelRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DockWindowPreviewPanelController {
    private static let parkingFrame = CGRect(
        origin: CGPoint(x: -100_000, y: -100_000),
        size: DockPreviewLayout.thumbnailSize
    )
    private let warmupSession = DockWindowPreviewSession(
        appName: "", appIcon: nil, processIdentifier: 0,
        windows: [DockPreviewWindow(
            element: AXUIElementCreateSystemWide(), title: "",
            frame: CGRect(origin: .zero, size: DockPreviewLayout.thumbnailSize), isMinimized: false
        )],
        screenRecordingAllowed: true
    )
    private var panel: NSPanel?
    private var hostingView: DockPreviewHostingView?
    private var content: DockPreviewPanelContent?
    private var isPresented = false
    var frame: CGRect? { isPresented ? panel?.frame : nil }
    var windowNumber: Int? { panel?.windowNumber }
    var isParked: Bool {
        guard let panel else { return false }
        return !isPresented && panel.alphaValue == 0 && panel.ignoresMouseEvents
            && panel.frame == Self.parkingFrame
    }

    func contains(_ point: CGPoint) -> Bool { frame?.contains(point) == true }

    func prepare() {
        guard panel == nil else { return }
        let panel = Self.makePanel()
        let content = DockPreviewPanelContent(session: warmupSession)
        let hostingView = DockPreviewHostingView(rootView: DockPreviewPanelRootView(content: content))
        panel.contentView = hostingView
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.setFrame(CGRect(origin: .zero, size: DockPreviewLayout.thumbnailSize), display: false)
        hostingView.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        // Keep the allocated WindowServer surface ordered but fully offscreen.
        // Hover only moves this same surface into place; it never pays a cold
        // order-front cost or exposes a hidden loading window on any display.
        panel.setFrame(Self.parkingFrame, display: false)
        content.reset()
        self.hostingView = hostingView
        self.content = content
        self.panel = panel
    }

    func show(session: DockWindowPreviewSession, frame: CGRect,
              select: @escaping (UUID) -> Void) {
        prepare()
        guard let panel, let content else { return }
        content.show(session: session, select: select)
        panel.setFrame(frame, display: false)
        // The prepared surface can be exposed immediately. Let SwiftUI commit
        // the replacement content on its normal compositor turn instead of
        // blocking hover delivery on a synchronous multi-card layout.
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
        panel?.setFrame(Self.parkingFrame, display: false)
        // Keep the already-built SwiftUI/AppKit shell, but replace the real
        // session so hidden previews release their captured images.
        content?.reset()
    }

    func stop() {
        dismiss()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
        content = nil
    }

    static func makePanel() -> NSPanel {
        let panel = DockPreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Dock window previews")
        return panel
    }
}
