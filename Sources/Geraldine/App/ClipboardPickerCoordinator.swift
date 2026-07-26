import AppKit
import Carbon
import Combine
import SwiftUI

private final class ClipboardPickerPanel: NSPanel {
    var dismissAction: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        dismissAction?()
    }
}

private final class ClipboardGlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            eventHandlerRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        self.hotKeyRef = nil
        self.eventHandlerRef = nil
    }

    deinit {
        unregister()
    }

    private static let signature: OSType = 0x47434C50 // GCLP

    private static let callback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let hotKey = Unmanaged<ClipboardGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            hotKey.action()
        }
        return noErr
    }
}

@MainActor
final class ClipboardPickerCoordinator {
    private let clipboard: ClipboardHistoryController
    private var targetApplication: NSRunningApplication?
    private var hotKey: ClipboardGlobalHotKey?
    private var shortcutSink: AnyCancellable?
    private var pickerRequestSink: AnyCancellable?
    private var outsideClickMonitor: Any?
    /// Bumped on every open so the search field starts empty each time.
    private var sessionID = UUID()

    static let panelSize = NSSize(width: 900, height: 540)

    private lazy var panel: ClipboardPickerPanel = {
        let panel = ClipboardPickerPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.dismissAction = { [weak self] in self?.hide() }
        panel.contentViewController = NSHostingController(rootView: makeRootView())
        // A hosting controller sizes its window from the SwiftUI fitting size, which
        // for a list-shaped view collapses to almost nothing without this.
        panel.setContentSize(Self.panelSize)
        return panel
    }()

    init(clipboard: ClipboardHistoryController) {
        self.clipboard = clipboard
    }

    func start() {
        shortcutSink = clipboard.$shortcutEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    enabled ? self?.registerHotKey() : self?.unregisterHotKey()
                }
            }
        pickerRequestSink = clipboard.$pickerRequest
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.show() }
            }
    }

    func stop() {
        shortcutSink?.cancel()
        shortcutSink = nil
        pickerRequestSink?.cancel()
        pickerRequestSink = nil
        unregisterHotKey()
        hide()
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        }
        sessionID = UUID()
        refreshRootView()
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        beginWatchingForOutsideClicks()
    }

    func hide() {
        endWatchingForOutsideClicks()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// A click anywhere outside the panel dismisses it. Watching mouse-down in
    /// other apps is steadier than reacting to key-window changes, which a
    /// non-activating panel gives up for reasons that are not always dismissals.
    private func beginWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func endWatchingForOutsideClicks() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func registerHotKey() {
        guard hotKey == nil else { return }
        let hotKey = ClipboardGlobalHotKey { [weak self] in self?.toggle() }
        if hotKey.register() {
            self.hotKey = hotKey
        } else {
            clipboard.setNotice("Control–Option–V is already in use by another app.")
        }
    }

    private func unregisterHotKey() {
        hotKey?.unregister()
        hotKey = nil
    }

    private func select(_ entry: ClipboardHistoryEntry) {
        // Dismiss before the payload read so the panel never lingers on a click.
        hide()
        Task { @MainActor in
            guard await clipboard.restore(entry) else { return }
            guard Permissions.hasAccessibilityAccess(), let targetApplication else {
                clipboard.setNotice(ClipboardHistoryError.accessibilityRequired.localizedDescription)
                return
            }
            targetApplication.activate(options: [])
            try? await Task.sleep(nanoseconds: 120_000_000)
            KeyboardPoster.post(keyCode: Int64(kVK_ANSI_V), flags: .maskCommand)
        }
    }

    private func makeRootView() -> ClipboardPickerView {
        ClipboardPickerView(
            clipboard: clipboard,
            accessibilityAvailable: Permissions.hasAccessibilityAccess(),
            sessionID: sessionID,
            select: { [weak self] entry in self?.select(entry) },
            dismiss: { [weak self] in self?.hide() }
        )
    }

    private func refreshRootView() {
        guard let hostingController = panel.contentViewController as? NSHostingController<ClipboardPickerView> else {
            return
        }
        hostingController.rootView = makeRootView()
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2 + 40
        ))
    }
}

struct ClipboardPickerView: View {
    @ObservedObject var clipboard: ClipboardHistoryController
    let accessibilityAvailable: Bool
    let sessionID: UUID
    let select: (ClipboardHistoryEntry) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selectedID: ClipboardHistoryEntry.ID?
    @FocusState private var searchFocused: Bool

    private static let listWidth: CGFloat = 340

    private var filteredEntries: [ClipboardHistoryEntry] {
        clipboard.matchingEntries(query: query)
    }

    private var selectedEntry: ClipboardHistoryEntry? {
        guard let selectedID else { return nil }
        return filteredEntries.first(where: { $0.id == selectedID })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: filteredEntries)
            Divider()
            footer
        }
        .frame(
            width: ClipboardPickerCoordinator.panelSize.width,
            height: ClipboardPickerCoordinator.panelSize.height
        )
        .adaptiveMaterialBackground(
            .regular,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.26), radius: 28, y: 14)
        .background(commandShortcuts)
        .onAppear { beginSession() }
        .onChange(of: sessionID) { _, _ in beginSession() }
        .onChange(of: query) { _, _ in
            selectedID = filteredEntries.first?.id
        }
        .onChange(of: clipboard.entries.count) { _, _ in
            if selectedID == nil || !filteredEntries.contains(where: { $0.id == selectedID }) {
                selectedID = filteredEntries.first?.id
            }
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
    }

    /// Command chords ride on `keyboardShortcut` rather than `onKeyPress`: key
    /// equivalents are resolved before the search field's editor sees the event,
    /// which is the only way ⌘⌫ survives with the field focused.
    private var commandShortcuts: some View {
        ZStack {
            Button("Delete Selected Item") { deleteCurrent() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Pin Selected Item") { togglePinCurrent() }
                .keyboardShortcut("p", modifiers: .command)
            ForEach(1...9, id: \.self) { position in
                Button("Paste Item \(position)") { selectEntry(at: position - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Module.clipboard.tint)
            TextField("Search clipboard history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .focused($searchFocused)
                .onSubmit { selectCurrent() }
            ClearSearchButton(query: $query)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 58)
    }

    /// List on the left, contents of the selected item on the right.
    @ViewBuilder private func body(for entries: [ClipboardHistoryEntry]) -> some View {
        if entries.isEmpty {
            EmptyState(
                icon: clipboard.entries.isEmpty ? "clipboard" : "magnifyingglass",
                title: clipboard.entries.isEmpty ? "Clipboard History Is Empty" : "No Matches",
                message: clipboard.entries.isEmpty
                    ? "Copy something, then press Control–Option–V again."
                    : "Try a different search.",
                tint: Module.clipboard.tint
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                results(for: entries)
                    .frame(width: Self.listWidth)
                Divider()
                ClipboardPreviewPane(
                    clipboard: clipboard,
                    entry: selectedEntry,
                    pasteLabel: accessibilityAvailable ? "Paste" : "Copy",
                    paste: select
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surfaceBase.opacity(0.5))
            }
        }
    }

    /// ⌘1-9 badges, resolved once per render instead of materialising an
    /// enumerated copy of a list that can hold thousands of entries.
    private var shortcutIndex: [ClipboardHistoryEntry.ID: Int] {
        var map: [ClipboardHistoryEntry.ID: Int] = [:]
        for (offset, entry) in filteredEntries.prefix(9).enumerated() {
            map[entry.id] = offset + 1
        }
        return map
    }

    private func results(for entries: [ClipboardHistoryEntry]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selectedID) {
                ForEach(entries) { entry in
                    ClipboardPickerRow(entry: entry, shortcutIndex: shortcutIndex[entry.id])
                        .tag(entry.id)
                        .contentShape(Rectangle())
                        // Single click browses into the preview; double click pastes.
                        .onTapGesture(count: 2) { select(entry) }
                        .onTapGesture { selectedID = entry.id }
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .accessibilityLabel(entry.accessibilityLabel)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Keyboard navigation must drag the viewport along with it.
            .onChange(of: selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            // ⌘1–9 is deliberately absent: every row already carries its own badge.
            ClipboardShortcutHint(keys: "↑↓", label: "Navigate")
            ClipboardShortcutHint(keys: "↩", label: accessibilityAvailable ? "Paste" : "Copy")
            ClipboardShortcutHint(keys: "⌘P", label: "Pin")
            ClipboardShortcutHint(keys: "⌘⌫", label: "Delete")
            Spacer(minLength: Theme.Spacing.md)
            ClipboardShortcutHint(keys: "esc", label: "Close")
        }
        .lineLimit(1)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 42)
    }

    private func beginSession() {
        query = ""
        selectedID = filteredEntries.first?.id
        searchFocused = true
    }

    private func selectCurrent() {
        guard let entry = currentEntry() else { return }
        select(entry)
    }

    private func selectEntry(at index: Int) {
        let entries = filteredEntries
        guard entries.indices.contains(index) else { return }
        select(entries[index])
    }

    private func togglePinCurrent() {
        guard let entry = currentEntry() else { return }
        clipboard.togglePinned(entry)
        selectedID = entry.id
    }

    private func deleteCurrent() {
        guard let entry = currentEntry() else { return }
        let entries = filteredEntries
        let index = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
        clipboard.delete(entry)
        let remaining = filteredEntries
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    private func currentEntry() -> ClipboardHistoryEntry? {
        guard let selectedID else { return filteredEntries.first }
        return filteredEntries.first(where: { $0.id == selectedID })
    }

    private func moveSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), entries.count - 1)
        selectedID = entries[nextIndex].id
    }
}

private struct ClipboardPickerRow: View {
    let entry: ClipboardHistoryEntry
    let shortcutIndex: Int?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ClipboardEntryThumbnail(entry: entry, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.preview)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                ClipboardEntryMetaLine(entry: entry, style: .compact)
            }
            Spacer(minLength: Theme.Spacing.sm)
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(Module.clipboard.tint)
                    .accessibilityLabel("Pinned")
            }
            if let shortcutIndex {
                Text("⌘\(shortcutIndex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
    }
}
