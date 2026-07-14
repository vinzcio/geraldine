import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    static let keyboardTransportHUDPreview = Notification.Name("keyboardTransportHUDPreview")
}

private let keyboardTransportHUDLog = Logger(
    subsystem: "com.vincent.geraldine",
    category: "KeyboardTransport"
)

@MainActor
final class KeyboardTransportHUDCoordinator {
    private let defaults: UserDefaults
    private let monitor = KeyboardTransportMonitor()
    private let presenter = KeyboardTransportHUDPresenter()
    private var defaultsObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?
    private var appliedPreference: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPreference()
            }
        }
        previewObserver = NotificationCenter.default.addObserver(
            forName: .keyboardTransportHUDPreview,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                keyboardTransportHUDLog.notice("Preview requested")
                self?.presenter.show(.wireless24GHz)
            }
        }
        applyPreference()
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let previewObserver {
            NotificationCenter.default.removeObserver(previewObserver)
        }
        defaultsObserver = nil
        previewObserver = nil
        appliedPreference = nil
        monitor.stop()
        presenter.hide()
    }

    private func applyPreference() {
        let isEnabled = defaults.bool(forKey: KeyboardTransportHUDPreferences.enabledKey)
        guard appliedPreference != isEnabled else { return }
        appliedPreference = isEnabled
        keyboardTransportHUDLog.notice("Preference enabled: \(isEnabled, privacy: .public)")
        if isEnabled {
            monitor.start { [weak self] transport in
                self?.presenter.show(transport)
            }
        } else {
            monitor.stop()
            presenter.hide()
        }
    }
}

@MainActor
private final class KeyboardTransportHUDPresenter {
    private let panel: NSPanel
    private var dismissal: DispatchWorkItem?
    private var presentationGeneration: UInt = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 238, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
            .stationary
        ]
    }

    func show(_ transport: KeyboardTransport) {
        keyboardTransportHUDLog.notice("Presenting HUD: \(transport.rawValue, privacy: .public)")
        presentationGeneration &+= 1
        dismissal?.cancel()
        panel.contentView = NSHostingView(rootView: KeyboardTransportHUDView(transport: transport))
        positionOnActiveScreen()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel] in
            guard let panel else { return }
            let state = "visible=\(panel.isVisible) alpha=\(panel.alphaValue) frame=\(NSStringFromRect(panel.frame))"
            keyboardTransportHUDLog.notice("HUD window: \(state, privacy: .public)")
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func hide() {
        presentationGeneration &+= 1
        let hideGeneration = presentationGeneration
        dismissal?.cancel()
        dismissal = nil
        guard panel.isVisible else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            MainActor.assumeIsolated { [weak self] in
                guard self?.presentationGeneration == hideGeneration else { return }
                panel?.orderOut(nil)
            }
        }
    }

    private func positionOnActiveScreen() {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.maxY - frame.height - 22
        ))
    }
}

private struct KeyboardTransportHUDView: View {
    let transport: KeyboardTransport

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: transport.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("AKKO PC98B PLUS+")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(transport.label)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(width: 238, height: 72)
        .adaptiveMaterialBackground(
            .regular,
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Akko keyboard, \(transport.label)")
    }
}
