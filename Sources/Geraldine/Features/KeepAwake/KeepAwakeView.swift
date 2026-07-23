import SwiftUI

struct KeepAwakeView: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController

    private var tint: Color { Module.keepAwake.tint }
    private var stateTint: Color { keepAwake.isActive ? Theme.Chart.red : tint }

    var body: some View {
        ModulePage(
            module: .keepAwake,
            headerTint: stateTint,
            headerStyle: .utility,
            widthRole: .focused
        ) {
            KeepAwakeWatchPanel()

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Spacing.md)],
                alignment: .leading,
                spacing: Theme.Spacing.md
            ) {
                policyCard
                automationCard
            }
        }
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Power Policy", subtitle: "Fine-tune what stays awake during the session.")

            Toggle(isOn: $keepAwake.allowDisplaySleep) {
                Label("Allow Display Sleep", systemImage: "display")
            }
            Toggle(isOn: $keepAwake.deactivateOnBattery) {
                Label("Deactivate On Battery", systemImage: "battery.25")
            }
            Toggle(isOn: $keepAwake.pauseWhenScreenLocked) {
                Label("Pause While Screen Is Locked", systemImage: "lock.display")
            }
        }
        .toggleStyle(.switch)
        .card(tier: .base)
    }

    private var automationCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Automation", subtitle: "Use URL commands from Shortcuts, launchers, or scripts.")

            VStack(alignment: .leading, spacing: 8) {
                Label("geraldine:activate?minutes=10", systemImage: "link")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    commandPill("activate")
                    commandPill("deactivate")
                    commandPill("toggle")
                    Spacer()
                }
            }
        }
        .card(tier: .tinted(tint))
    }

    private func commandPill(_ command: String) -> some View {
        Text(command)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Keep Awake eye interaction

private struct KeepAwakeEyePressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var keepAwakeEyePressed: Bool {
        get { self[KeepAwakeEyePressedKey.self] }
        set { self[KeepAwakeEyePressedKey.self] = newValue }
    }
}

/// Reads the pressed state supplied by `KeepAwakeEyeButtonStyle` so the pupil and
/// catchlight respond locally without bouncing the whole eye.
struct KeepAwakePokeableEye: View {
    @Environment(\.keepAwakeEyePressed) private var isPressed

    let isActive: Bool
    let size: CGFloat

    var body: some View {
        EyeView(isActive: isActive, size: size, isPressed: isPressed)
    }
}

struct KeepAwakeEyeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KeepAwakeEyeButtonBody(configuration: configuration)
    }
}

private struct KeepAwakeEyeButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .environment(\.keepAwakeEyePressed, configuration.isPressed)
            .frame(minWidth: Theme.Layout.minimumHitArea, minHeight: Theme.Layout.minimumHitArea)
            .contentShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(
                        isFocused && isEnabled
                            ? Theme.focusRing
                            : Theme.accent.opacity(isEnabled && isHovered ? 0.18 : 0),
                        lineWidth: isFocused && isEnabled ? 2 : 1
                    )
            }
            .opacity(isEnabled ? 1 : 0.45)
            .focusEffectDisabled()
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isFocused)
            .pointingHandCursor()
    }
}

extension ButtonStyle where Self == KeepAwakeEyeButtonStyle {
    static var keepAwakeEye: KeepAwakeEyeButtonStyle { KeepAwakeEyeButtonStyle() }
}
