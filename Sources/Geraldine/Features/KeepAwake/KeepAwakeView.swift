import SwiftUI

struct KeepAwakeView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @State private var selectedDuration: KeepAwakeDuration = .oneHour

    private var tint: Color { Module.keepAwake.tint }
    private var stateTint: Color { keepAwake.isActive ? Theme.Chart.red : tint }

    var body: some View {
        ModulePage(
            module: .keepAwake,
            headerTint: stateTint,
            headerStyle: .utility,
            widthRole: .focused
        ) {
            hero

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Spacing.md)],
                alignment: .leading,
                spacing: Theme.Spacing.md
            ) {
                durationCard
                policyCard
            }

            idleActivityCard
            automationCard
        }
        .onAppear { selectedDuration = keepAwake.defaultDuration }
    }

    private var hero: some View {
        HStack(spacing: Theme.Spacing.xl) {
            Button {
                keepAwake.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(keepAwake.isActive ? stateTint.opacity(0.14) : Theme.surfaceMuted)
                    Circle()
                        .strokeBorder(keepAwake.isActive ? stateTint.opacity(0.34) : Theme.separator, lineWidth: 1)
                    if keepAwake.isActive {
                        Circle()
                            .stroke(stateTint.opacity(0.18), lineWidth: 8)
                            .blur(radius: 7)
                            .padding(7)
                    }
                    KeepAwakePokeableEye(isActive: keepAwake.isActive, size: 104)
                }
                .frame(width: 124, height: 124)
                .contentShape(Circle())
                .geraldineAnimation(.emphasis, value: keepAwake.isActive)
            }
            .buttonStyle(.keepAwakeEye)
            .help(keepAwake.isActive ? "Poke eyes to let your Mac sleep." : "Poke eyes to keep awake.")
            .accessibilityLabel("Keep Awake")
            .accessibilityValue(keepAwake.isActive ? "On" : "Off")
            .accessibilityHint(keepAwake.isActive
                               ? "Stops keeping your Mac awake."
                               : "Keeps your Mac awake for the selected duration.")

            WorkflowPhaseHost(phase: keepAwake.isActive) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(keepAwake.isActive ? "Keeping Watch" : "Sleep On Your Terms")
                        .font(.geraldineHero)
                        .foregroundStyle(keepAwake.isActive ? stateTint : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(keepAwake.statusLine)
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if keepAwake.isActive {
                        HStack(spacing: Theme.Spacing.xs) {
                            ContextualSymbol(
                                inactive: "moon.zzz",
                                active: keepAwake.isPaused ? "pause.fill" : "eye.fill",
                                isActive: true,
                                tint: keepAwake.isPaused ? Theme.warn : tint,
                                size: 12
                            )
                            if let remaining = keepAwake.remaining {
                                AnimatedNumberText(
                                    "\(KeepAwakeController.durationString(remaining)) left",
                                    value: remaining
                                )
                            } else {
                                Text(keepAwake.endTimeLine)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(keepAwake.isPaused ? Theme.warn : stateTint)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xxs)
                        .background((keepAwake.isPaused ? Theme.warn : tint).opacity(0.12), in: Capsule())
                    } else if let error = keepAwake.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.warn)
                    } else {
                        Text("Poke the eye to keep this Mac awake for the duration you choose below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
            }

            Spacer()
        }
        .card(padding: Theme.Spacing.xl, tier: .tinted(stateTint))
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Awake For", subtitle: "Poke the eye to start a session for this long. Picking a duration never starts one by itself.")

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.xs)],
                      spacing: Theme.Spacing.xs) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    Button {
                        selectedDuration = duration
                        keepAwake.defaultDuration = duration
                    } label: {
                        VStack(spacing: 3) {
                            Text(duration.shortLabel)
                                .font(.rounded(18, .bold))
                            Text(duration.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Theme.surfaceMuted,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .selectionPlate(isSelected: duration == selectedDuration, tint: tint)
                    }
                    .buttonStyle(.quiet(tint))
                    .accessibilityAddTraits(duration == selectedDuration ? [.isSelected] : [])
                }
            }
        }
        .card(tier: .base)
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

    private var idleActivityCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Stay Active", subtitle: "Nudges input after you go idle, so chat and status apps keep seeing you as active.")
                Spacer()
                Label(keepAwake.idleActivityStatusLine, systemImage: idleActivityIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(idleActivityTint)
                    .fixedSize()
            }

            Toggle(isOn: $keepAwake.simulateIdleActivity) {
                Label("Simulate Activity", systemImage: "cursorarrow")
            }

            HStack {
                Label("Active After", systemImage: "timer")
                Spacer()
                ForEach(KeepAwakeController.idleActivityDelayOptions, id: \.self) { minutes in
                    Button("\(minutes)m") {
                        keepAwake.idleActivityDelayMinutes = minutes
                    }
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .buttonStyle(.geraldineSelection(
                        tint,
                        isSelected: keepAwake.idleActivityDelayMinutes == minutes,
                        cornerRadius: Theme.Radius.badge
                    ))
                    .frame(minWidth: Theme.Layout.minimumHitArea, minHeight: Theme.Layout.minimumHitArea)
                    .accessibilityAddTraits(keepAwake.idleActivityDelayMinutes == minutes ? [.isSelected] : [])
                }
                Menu {
                    ForEach(KeepAwakeController.idleActivityExtendedDelayOptions, id: \.self) { minutes in
                        Button {
                            keepAwake.idleActivityDelayMinutes = minutes
                        } label: {
                            if keepAwake.idleActivityDelayMinutes == minutes {
                                Label("\(minutes)m", systemImage: "checkmark")
                            } else {
                                Text("\(minutes)m")
                            }
                        }
                    }
                } label: {
                    let current = keepAwake.idleActivityDelayMinutes
                    Text(KeepAwakeController.idleActivityExtendedDelayOptions.contains(current)
                         ? "\(current)m" : "More")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: Theme.Layout.minimumHitArea)
                .help("Choose a longer Idle Activity delay")
                .accessibilityLabel("More Idle Activity delays")
            }
            .disabled(!keepAwake.simulateIdleActivity)

            if keepAwake.idleActivityNeedsAccessibility {
                HStack(spacing: 8) {
                    Button("Grant Access") {
                        keepAwake.refreshIdleActivityAccess(prompt: true)
                        state.refreshAccessibility()
                    }
                    .buttonStyle(.soft(Theme.warn))

                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                        .buttonStyle(.quiet(Theme.warn))
                }
            }

            if let lastPulse = keepAwake.idleActivityLastPulse {
                LabeledContent("Last Pulse") {
                    Text(lastPulse.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .toggleStyle(.switch)
        .card(tier: .raised)
    }

    private var idleActivityIcon: String {
        switch keepAwake.idleActivityPhase {
        case .pulsing: return "keyboard"
        case .needsAccessibility, .failed: return "exclamationmark.triangle.fill"
        default: return "cursorarrow"
        }
    }

    private var idleActivityTint: Color {
        guard keepAwake.simulateIdleActivity else { return .secondary }
        switch keepAwake.idleActivityPhase {
        case .pulsing: return tint
        case .needsAccessibility, .failed: return Theme.warn
        default: return .secondary
        }
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
