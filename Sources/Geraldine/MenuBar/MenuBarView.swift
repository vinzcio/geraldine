import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var monitor: SystemMonitor
    @State private var freeingMemory = false
    @State private var contentHeight: CGFloat = 520

    /// Leave room above the bottom of the screen so a tall popover scrolls instead of clipping.
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 860) - 24 }

    private var health: (label: String, color: Color) {
        if monitor.diskFraction > 0.9 || monitor.memoryFraction > 0.9 { return ("Needs Attention", Theme.warn) }
        if (monitor.batteryLevel ?? 1) < 0.15 && !monitor.batteryCharging { return ("Battery Low", Theme.warn) }
        return ("Looking Good", Theme.good)
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
        .frame(width: 320, height: min(contentHeight, maxHeight))
        .onPreferenceChange(MenuHeightKey.self) { contentHeight = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            WidgetGrid()
            DevicesCard()
            recommendation

            Divider()

            menuRow("Run Smart Care", "checkmark.seal.fill") { state.open(.smartCare) }
            HStack {
                menuRow("Settings", "gearshape") { state.open(.settings) }
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit", systemImage: "power").font(.callout)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.brandGradient)
                    .frame(width: 24, height: 24)
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
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
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Open the full Geraldine app")
        }
    }

    // MARK: recommendation

    @ViewBuilder private var recommendation: some View {
        let rec = recommend()
        Button(action: rec.action) {
            HStack(spacing: 10) {
                Image(systemName: rec.icon).foregroundStyle(rec.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.title).font(.caption.weight(.semibold)).foregroundStyle(.primary)
                    Text(rec.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if rec.actionable { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(10)
            .background(rec.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private struct Rec { var title: String; var subtitle: String; var icon: String; var tint: Color; var actionable: Bool; var action: () -> Void }

    private func recommend() -> Rec {
        if monitor.diskFraction > 0.88 {
            return Rec(title: "You're Low On Disk Space", subtitle: "Run Cleanup to free some up",
                       icon: "internaldrive.fill", tint: Theme.warn, actionable: true) { state.open(.cleanup) }
        }
        if monitor.memoryFraction > 0.85 {
            return Rec(title: "Memory Is Running High", subtitle: "Free up inactive memory",
                       icon: "memorychip", tint: Theme.warn, actionable: true, action: freeMemory)
        }
        return Rec(title: "Your Mac Looks Healthy", subtitle: "Run a Smart Care check anytime",
                   icon: "checkmark.seal.fill", tint: Theme.good, actionable: true) { state.open(.smartCare) }
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

    private func menuRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
