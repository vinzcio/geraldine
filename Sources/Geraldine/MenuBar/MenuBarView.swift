import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @EnvironmentObject private var devices: DeviceMonitor
    let onContentHeightChange: (CGFloat) -> Void
    @State private var freeingMemory = false
    @State private var contentHeight: CGFloat = 520

    init(onContentHeightChange: @escaping (CGFloat) -> Void = { _ in }) {
        self.onContentHeightChange = onContentHeightChange
    }

    /// Leave a small breathing edge around the right-side panel on shorter displays.
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 860) - MenuBarPanelPlacement.edgeInset * 2
    }

    private var health: (label: String, color: Color) {
        if hasAttentionRecommendation { return ("Needs Attention", Theme.warn) }
        if (monitor.batteryLevel ?? 1) < 0.15 && !monitor.batteryCharging { return ("Battery Low", Theme.warn) }
        return ("Looking Good", Theme.good)
    }

    /// Derived from the recommendation itself so the "Needs Attention" label can never
    /// disagree with whether a recommendation card actually renders.
    private var hasAttentionRecommendation: Bool {
        attentionRecommendation() != nil
    }

    private var shouldShowDevices: Bool {
        // Preserve the card while its inventory is loading, but do not leave an
        // empty completed scan competing with the dashboard's primary signals.
        devices.scanning || !devices.devices.isEmpty
    }

    private var hasSupportingContent: Bool {
        hasAttentionRecommendation || shouldShowDevices
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MenuHeightKey.self, value: proxy.size.height)
                })
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: MenuBarPanelPlacement.preferredWidth,
               height: min(contentHeight, maxHeight))
        .adaptiveMaterialBackground(
            .regular,
            in: RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.raised, style: .continuous))
        .onPreferenceChange(MenuHeightKey.self) { height in
            contentHeight = height
            onContentHeightChange(min(height, maxHeight))
        }
        .geraldineSurfaceActive(state.menuBarPopoverVisible)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            PopoverRevealGroup(index: 0, isVisible: state.menuBarPopoverVisible) {
                header
            }
            PopoverRevealGroup(index: 1, isVisible: state.menuBarPopoverVisible) {
                WidgetGrid()
            }
            if hasSupportingContent {
                PopoverRevealGroup(index: 2, isVisible: state.menuBarPopoverVisible) {
                    supportingContent
                }
            }
            PopoverRevealGroup(index: hasSupportingContent ? 3 : 2, isVisible: state.menuBarPopoverVisible) {
                footer
            }
        }
        .padding(16)
        .frame(width: MenuBarPanelPlacement.preferredWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            GeraldineMark(size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Geraldine").font(.rounded(14, .bold))
                HStack(spacing: 4) {
                    Text(health.label).font(.caption2).foregroundStyle(health.color)
                    if monitor.thermal.available {
                        AnimatedNumberText("· \(Int(monitor.thermal.cpu.rounded()))°C", value: monitor.thermal.cpu)
                            .font(.caption2)
                            .foregroundStyle(Thermal.color(monitor.thermal.cpu))
                    }
                }
            }
            Spacer()
            Button { state.open(.dashboard) } label: {
                Label("Open", systemImage: "macwindow")
            }
            .buttonStyle(.soft(Theme.accent))
            .help("Open the full Geraldine app")
        }
    }

    // MARK: Supporting status

    @ViewBuilder private var supportingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasAttentionRecommendation {
                recommendation
            }
            if shouldShowDevices {
                DevicesCard()
            }
        }
    }

    @ViewBuilder private var recommendation: some View {
        if let rec = attentionRecommendation() {
            let busy = rec.freesMemory && freeingMemory
            Button(action: rec.action) {
                HStack(spacing: 10) {
                    Group {
                        if busy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: rec.icon).foregroundStyle(rec.tint)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                        Text(busy ? "Freeing Up Memory…" : rec.subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rec.actionable { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                }
                .geraldineAnimation(.standard, value: freeingMemory)
            }
            .buttonStyle(.actionableCard(padding: 10,
                                         tier: .tinted(rec.tint),
                                         cornerRadius: Theme.Radius.control))
            .disabled(busy)
        }
    }

    private struct Rec { var title: String; var subtitle: String; var icon: String; var tint: Color; var actionable: Bool; var freesMemory: Bool = false; var action: () -> Void }

    private func attentionRecommendation() -> Rec? {
        if monitor.diskFraction > 0.88 {
            return Rec(title: "You're Low On Disk Space", subtitle: "Run Cleanup To Free Some Up",
                       icon: "internaldrive.fill", tint: Theme.warn, actionable: true) { state.open(.cleanup) }
        }
        if monitor.memoryFraction > 0.85 {
            return Rec(title: "Memory Is Running High", subtitle: "Free Up Inactive Memory",
                       icon: "memorychip", tint: Theme.warn, actionable: true, freesMemory: true, action: freeMemory)
        }
        return nil
    }

    private func freeMemory() {
        guard !freeingMemory else { return }
        freeingMemory = true
        Task {
            _ = await MemoryActions.freeUpRAM()
            monitor.refresh()
            freeingMemory = false
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                menuRow("Run Smart Care", "checkmark.seal.fill") { state.open(.smartCare) }
                menuRow("Settings", "gearshape") { state.open(.settings) }
                Spacer(minLength: 4)
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power").font(.callout)
                }
                .buttonStyle(.quiet(Theme.bad))
            }
        }
    }

    private func menuRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.quiet(Theme.accent))
    }
}

private struct PopoverRevealGroup<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let isVisible: Bool
    @ViewBuilder let content: Content

    init(index: Int, isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.index = index
        self.isVisible = isVisible
        self.content = content()
    }

    @State private var revealed = false

    var body: some View {
        content
            .opacity(isVisible && revealed ? 1 : 0)
            .offset(y: reduceMotion || revealed ? 0 : 7)
            .blur(radius: reduceMotion || revealed ? 0 : 3)
            .accessibilityHidden(!isVisible || !revealed)
            .task(id: isVisible) {
                guard isVisible else {
                    revealed = false
                    return
                }
                guard !reduceMotion,
                      let animation = GeraldineMotion.animation(.standard, reduceMotion: false) else {
                    revealed = true
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(index * 55))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                withAnimation(animation) { revealed = true }
            }
            .onChange(of: reduceMotion) { _, newValue in
                if newValue { revealed = true }
            }
    }
}

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
