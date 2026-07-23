import Foundation
import SwiftUI

/// The Keep Awake control as a draggable, resizable tile. The eye owns the session action:
/// choosing a duration never starts one, while poking the eye starts or stops Keep Awake.
/// Lives in the same grid as the metric widgets but never
/// drives the menu-bar status item (see `menuBarKind`).
struct KeepAwakeWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.widgetCustomizationActive) private var customizationActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @Namespace private var eyeNamespace

    private var active: Bool { keepAwake.isActive }
    private var stateTint: Color { active ? Theme.Chart.red : Module.keepAwake.tint }
    private var lastError: String? { active ? nil : keepAwake.lastError }
    private var motionReduced: Bool { reduceMotion || !surfaceActive }

    var body: some View {
        Group {
            switch size {
            case .small:  stateSwitcher(idle: { smallIdle }, active: { smallActive })
            case .medium: stateSwitcher(idle: { mediumIdle }, active: { expandedActive(compact: true) })
            case .large:  KeepAwakeWatchPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(size == .large ? 0 : 10)
        .background {
            if size != .large { compactTileBackground }
        }
    }

    /// The idle/active cross-fade every size shares.
    private func stateSwitcher<Idle: View, Active: View>(
        @ViewBuilder idle: () -> Idle,
        @ViewBuilder active activeLayout: () -> Active
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if active {
                activeLayout()
                    .transition(GeraldineMotion.stateTransition(reduceMotion: motionReduced))
            } else {
                idle()
                    .transition(GeraldineMotion.stateTransition(reduceMotion: motionReduced))
            }
        }
        .animation(GeraldineMotion.animation(.standard, reduceMotion: motionReduced), value: active)
    }

    private var compactTileBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.surfaceMuted)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(stateTint.opacity(active ? 0.11 : 0)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(active ? stateTint.opacity(0.40)
                              : customizationActive ? Theme.accent.opacity(0.24) : .clear,
                              lineWidth: 1))
            .shadow(color: active ? stateTint.opacity(0.12) : .clear,
                    radius: active ? 9 : 0, y: active ? 3 : 0)
            .animation(
                GeraldineMotion.animation(.standard, reduceMotion: motionReduced),
                value: active
            )
    }

    // MARK: - Small tile

    private var smallIdle: some View {
        VStack(alignment: .leading, spacing: 5) {
            compactHeader(title: "Keep Awake")
            if let lastError {
                errorLabel(lastError, lineLimit: 2)
                Spacer(minLength: 0)
            } else {
                durationColumn(showLabel: false)
            }
            idleActivityRow(showChips: false)
        }
    }

    private var smallActive: some View {
        VStack(alignment: .leading, spacing: 5) {
            compactHeader(title: "Awake", tint: stateTint)
            remainingHeadline(size: 21)
            // Drains like the countdown halo: the bar shows time *remaining*.
            if hasEnd { StatBar(fraction: 1 - progress, tint: Theme.Chart.red, height: 4) }
            Spacer(minLength: 0)
            // Idle activity stays reachable while active because toggling it affects
            // the running session; the eye above is the stop control.
            idleActivityRow(showChips: false)
        }
    }

    // MARK: - Medium tile (2×1, shared unit height)

    private var mediumIdle: some View {
        VStack(alignment: .leading, spacing: 8) {
            compactHeader(title: "Keep Awake", hint: pokeHint)
            if let lastError {
                errorLabel(lastError, lineLimit: 1)
                Spacer(minLength: 0)
            } else {
                // Two titled zones side by side — the same split the large tile uses,
                // scaled down — so duration and idle activity read as distinct sections.
                HStack(alignment: .top, spacing: 10) {
                    durationColumn(showLabel: true)
                        .frame(width: 96)
                    idleActivitySection(.compact)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The active session layout the medium and large tiles share: countdown hero,
    /// a remaining-time bar that drains like the halo, then idle activity + extend
    /// chips. The halo eye is the stop control — no separate Stop button.
    private func expandedActive(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            activeCountdownHero
            if hasEnd { StatBar(fraction: 1 - progress, tint: Theme.Chart.red, height: compact ? 4 : 5) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                idleActivityRow(showChips: !compact)
                if hasEnd {
                    extendChip("+30m", 30 * 60)
                    extendChip("+1h", 60 * 60)
                }
            }
            .frame(height: Theme.Layout.compactHitArea)
        }
    }

    /// Compact tiles use a direct menu rather than the old repeating scroll wheel. Every
    /// visible row maps to exactly one duration, so taps cannot land one item away.
    private func durationColumn(showLabel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLabel { fieldLabel("Awake for", systemImage: "moon.zzz") }
            CompactDurationSelector(selection: durationSelection, tint: Module.keepAwake.tint)
        }
    }

    // MARK: - Pieces

    private var activeCountdownHero: some View {
        HStack(spacing: 10) {
            countdownHalo

            VStack(alignment: .leading, spacing: 1) {
                if hasEnd {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        AnimatedNumberText(remainingString, value: keepAwake.remaining ?? 0)
                            .font(.rounded(30, .bold))
                            .foregroundStyle(countdownTint)
                            .monospacedDigit()
                        Text("left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No Time Limit")
                        .font(.rounded(22, .semibold))
                        .foregroundStyle(countdownTint)
                }

                Text(countdownDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
    }

    private var countdownHalo: some View {
        Button { keepAwake.toggle() } label: {
            CountdownHalo(progress: hasEnd ? progress : nil,
                          tint: countdownTint,
                          paused: keepAwake.isPaused)
        }
        .buttonStyle(.keepAwakeEye)
        .matchedGeometryEffect(id: "keep-awake-eye", in: eyeNamespace,
                               properties: .frame, anchor: .center, isSource: false)
        .help(active ? "Poke the eyes to let your Mac sleep." : "Poke the eyes to keep your Mac awake.")
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityHint("Stops keeping your Mac awake.")
    }

    private func header(eyeSize: CGFloat, title: String, subtitle: String?,
                        tint: Color = .primary, eyeIsSource: Bool) -> some View {
        let large = eyeSize > 30
        return HStack(spacing: large ? 12 : 8) {
            eye(eyeSize, isSource: eyeIsSource)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(large ? .rounded(17, .semibold) : .caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Compact tiles keep the eye's 40pt accessibility target in chrome rather than letting
    /// that invisible target inflate the fixed row's content height. The optional hint (shown
    /// where the old Start button sat) tells first-timers the eye is the control.
    private func compactHeader(title: String, hint: String? = nil, tint: Color = .primary) -> some View {
        HStack(alignment: .center, spacing: 2) {
            Color.clear.frame(width: 36, height: 24)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 4)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(height: Theme.Layout.compactHitArea, alignment: .leading)
        .overlay(alignment: .leading) {
            eye(24, isSource: true)
                .offset(y: -4)
        }
    }

    @ViewBuilder private func remainingHeadline(size: CGFloat) -> some View {
        if hasEnd {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                AnimatedNumberText(remainingString, value: keepAwake.remaining ?? 0)
                    .font(.rounded(size, .bold))
                    .foregroundStyle(countdownTint)
                Text("left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No Time Limit")
                .font(.rounded(size * 0.62, .semibold))
                .foregroundStyle(countdownTint)
        }
    }

    /// Shares the idle row's 14pt icon column so stacked field labels align exactly.
    private func fieldLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.secondary)
    }

    private var pokeHint: String { active ? "Poke to sleep" : "Poke to start" }

    private var durationSelection: Binding<KeepAwakeDuration> {
        Binding(
            get: { keepAwake.defaultDuration },
            set: { keepAwake.selectDuration($0) }
        )
    }

    /// One row that finally *names* idle activity and, in the wider tiles, its "Active after"
    /// delay — so it never reads as a second duration. Small/active tiles show just the labeled
    /// switch; medium tiles add the delay chips.
    @ViewBuilder private func idleActivityRow(showChips: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: idleActivityIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(idleActivityTint)
                .frame(width: 14)
            if showChips {
                Text("Active after")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                idleActivityOptions(compact: true)
                    .opacity(keepAwake.simulateIdleActivity ? 1 : 0.45)
            } else {
                Text("Stay active")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if keepAwake.idleActivityNeedsAccessibility {
                Button("Grant") { keepAwake.refreshIdleActivityAccess(prompt: true) }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.quiet(Theme.warn, compact: true))
                    .help("Grant Accessibility access so Geraldine can simulate activity")
            }
            Spacer(minLength: 4)
            idleActivitySwitch
        }
        .frame(height: Theme.Layout.compactHitArea)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
    }

    /// How much the grouped idle-activity section shows. `pill` is a single labeled switch
    /// (small tile); `compact` adds the "Active after" delay row (medium); `full` adds the
    /// explanatory line and fills its column (large). All three share one container so the
    /// idle controls always read as a single, tidy module.
    private enum IdleActivityStyle { case pill, compact, full }

    @ViewBuilder private func idleActivitySection(_ style: IdleActivityStyle) -> some View {
        let enabled = keepAwake.simulateIdleActivity
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: idleActivityIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(idleActivityTint)
                    .frame(width: 14)
                Text("Stay Active")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if keepAwake.idleActivityNeedsAccessibility {
                    Button("Grant") { keepAwake.refreshIdleActivityAccess(prompt: true) }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.quiet(Theme.warn, compact: true))
                        .help("Grant Accessibility access")
                }
                idleActivitySwitch
            }
            .frame(height: Theme.Layout.compactHitArea)

            if style == .full {
                Text("Nudges input after you go idle, so chat and status apps keep seeing you as active.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if style != .pill {
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    // The narrow medium column can't spare room for the "Active after"
                    // words, so there the timer glyph alone leads the delay chips; the
                    // roomy large card keeps the full label.
                    if style == .full {
                        fieldLabel("Active after", systemImage: "timer")
                    } else {
                        Image(systemName: "timer")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 14)
                            .foregroundStyle(.secondary)
                    }
                    idleActivityOptions(compact: style == .compact)
                    Spacer(minLength: 0)
                }
                .frame(height: Theme.Layout.compactHitArea)
                .opacity(enabled ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity,
               maxHeight: style == .pill ? nil : .infinity,
               alignment: .topLeading)
        .background(Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
            .strokeBorder(idleActivityTint.opacity(enabled ? 0.24 : 0.10), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
    }

    private var idleActivitySwitch: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                keepAwake.simulateIdleActivity.toggle()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(
                        keepAwake.simulateIdleActivity
                            ? idleActivityTint.opacity(0.78)
                            : Color.primary.opacity(0.12)
                    )
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                    .padding(2)
                    .offset(x: keepAwake.simulateIdleActivity ? 8 : -8)
            }
            .frame(width: 34, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Enable Idle Activity after \(keepAwake.idleActivityDelayLabel)")
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
        .accessibilityAddTraits(keepAwake.simulateIdleActivity ? [.isSelected] : [])
    }

    @ViewBuilder private func idleActivityOptions(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 4) {
            ForEach(KeepAwakeController.idleActivityDelayOptions, id: \.self) { minutes in
                Button {
                    keepAwake.idleActivityDelayMinutes = minutes
                } label: {
                    chipLabel("\(minutes)m", compact: compact)
                }
                .buttonStyle(KeepAwakeChipStyle(tint: idleActivityTint,
                                                isSelected: keepAwake.idleActivityDelayMinutes == minutes))
                .help("Start Idle Activity after \(minutes) minute\(minutes == 1 ? "" : "s")")
                .accessibilityLabel("Idle Activity after \(minutes) minute\(minutes == 1 ? "" : "s")")
                .accessibilityAddTraits(keepAwake.idleActivityDelayMinutes == minutes ? [.isSelected] : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One shared chip metric so the delay and extend actions sit on the same 22pt line.
    private func chipLabel(_ text: String? = nil, systemImage: String? = nil,
                           compact: Bool) -> some View {
        HStack(spacing: 0) {
            if let text {
                Text(text)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
        }
        .fixedSize()
        .padding(.horizontal, compact ? 5 : 6)
        .frame(minWidth: compact ? 24 : 30, minHeight: 22)
        .contentShape(Capsule())
    }

    private func extendChip(_ label: String, _ seconds: TimeInterval) -> some View {
        Button { keepAwake.extend(by: seconds) } label: {
            chipLabel(label, compact: true)
        }
        .buttonStyle(KeepAwakeChipStyle(tint: Theme.bad, isSelected: false, outlined: true))
        .help("Add \(label) to the current session")
        .accessibilityLabel("Add \(label)")
    }

    private func errorLabel(_ message: String, lineLimit: Int) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(Theme.warn)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.8)
            .accessibilityLabel("Keep Awake error")
            .accessibilityValue(message)
    }

    private func eye(_ eyeSize: CGFloat, isSource: Bool) -> some View {
        Button { keepAwake.toggle() } label: {
            KeepAwakePokeableEye(isActive: active, size: eyeSize)
        }
        .buttonStyle(.keepAwakeEye)
        .matchedGeometryEffect(id: "keep-awake-eye", in: eyeNamespace,
                               properties: .frame, anchor: .center, isSource: isSource)
        .help(active ? "Poke the eyes to let your Mac sleep." : "Poke the eyes to keep your Mac awake.")
        .accessibilityLabel("Keep Awake")
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityHint(active ? "Stops keeping your Mac awake." : "Keeps your Mac awake for the selected duration.")
    }

    // MARK: - Derived state

    private var hasEnd: Bool { keepAwake.activeUntil != nil }
    private var progress: Double { keepAwake.progressFraction ?? 0 }

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
        case .pulsing: return stateTint
        case .needsAccessibility, .failed: return Theme.warn
        default: return .secondary
        }
    }

    private var remainingString: String {
        guard let remaining = keepAwake.remaining else { return "On" }
        return KeepAwakeController.durationString(remaining)
    }

    /// Sub-line shown while active: the pause reason if paused, otherwise the end time.
    private var countdownDetail: String {
        if keepAwake.isPaused, let reason = keepAwake.pauseReason { return "Paused · \(reason)" }
        return hasEnd ? keepAwake.endTimeLine : "Active Until You Stop It"
    }

    private var countdownTint: Color { Theme.Chart.red }
}

/// The approved ImageGen-derived Keep Awake surface shared by the main app and the
/// full-width popover widget. Keeping one owner prevents either surface drifting back
/// to the old card-and-button treatment.
struct KeepAwakeWatchPanel: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { keepAwake.isActive }
    private var hasEnd: Bool { keepAwake.activeUntil != nil }
    private var progress: Double? { hasEnd ? keepAwake.progressFraction : nil }
    private var remainingText: String? {
        guard active else { return nil }
        guard let remaining = keepAwake.remaining else { return "Until stopped" }
        return "\(KeepAwakeController.durationString(remaining)) left"
    }
    private var selectedDuration: KeepAwakeDuration? {
        active ? keepAwake.activeDurationOption : keepAwake.defaultDuration
    }

    var body: some View {
        GeometryReader { proxy in
            let eyeFieldWidth = min(max(proxy.size.width * 0.39, 214), 252)

            HStack(spacing: 12) {
                KeepAwakeTimeField(
                    isActive: active,
                    isPaused: keepAwake.isPaused,
                    progress: progress,
                    durationSeconds: active
                        ? keepAwake.activeDuration
                        : keepAwake.defaultDuration.seconds,
                    durationLabel: keepAwake.defaultDuration.label,
                    remainingText: remainingText,
                    action: { keepAwake.toggle() }
                )
                .frame(width: eyeFieldWidth)

                VStack(spacing: 7) {
                    HoneycombDurationSelector(
                        selection: selectedDuration,
                        select: { keepAwake.selectDuration($0) },
                        isSessionActive: active
                    )
                    StayActiveWatchControl(
                        isEnabled: $keepAwake.simulateIdleActivity,
                        delayMinutes: $keepAwake.idleActivityDelayMinutes,
                        phase: keepAwake.idleActivityPhase,
                        error: keepAwake.idleActivityError,
                        needsAccessibility: keepAwake.idleActivityNeedsAccessibility,
                        grantAccess: { keepAwake.refreshIdleActivityAccess(prompt: true) }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                if !active, let lastError = keepAwake.lastError {
                    Label(lastError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.warn)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.48), in: Capsule())
                        .accessibilityLabel("Keep Awake error")
                        .accessibilityValue(lastError)
                }
            }
        }
        .frame(height: 224)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.145, green: 0.155, blue: 0.185),
                            Color(red: 0.075, green: 0.082, blue: 0.102)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(
                            active ? Theme.Chart.red.opacity(0.72) : .white.opacity(0.14),
                            lineWidth: active ? 1.5 : 1
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.055), lineWidth: 1)
                        .padding(3)
                }
                .shadow(color: .black.opacity(0.38), radius: 12, y: 7)
        }
        .animation(
            GeraldineMotion.animation(.standard, reduceMotion: reduceMotion),
            value: active
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake controls")
    }
}

/// Capsule chip for the widget's inline options: one layer of chrome at a fixed 22pt
/// line, unlike the full-size button styles whose 40pt targets would inflate the
/// tile's fixed rows. Selected and outlined chips carry the tint; idle ones stay quiet.
private struct KeepAwakeChipStyle: ButtonStyle {
    let tint: Color
    var isSelected = false
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        KeepAwakeChipBody(configuration: configuration,
                          tint: tint, isSelected: isSelected, outlined: outlined)
    }
}

private struct KeepAwakeChipBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isSelected: Bool
    let outlined: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isFocused && isEnabled
                        ? Theme.focusRing
                        : (isSelected || outlined ? tint.opacity(0.30) : .clear),
                    lineWidth: isFocused && isEnabled ? 2 : 1
                )
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .focusEffectDisabled()
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: isHovered)
            .pointingHandCursor()
    }

    private var foreground: Color {
        if isSelected || outlined { return tint }
        return isHovered ? .primary : .secondary
    }

    private var background: Color {
        if configuration.isPressed { return tint.opacity(0.24) }
        if isSelected { return tint.opacity(0.16) }
        if outlined { return tint.opacity(isHovered ? 0.18 : 0.12) }
        return isHovered ? tint.opacity(0.10) : .clear
    }
}

/// Compact widgets show the current duration and open a direct grid of discrete targets,
/// avoiding the repeating-wheel recentering race in the previous selector.
private struct CompactDurationSelector: View {
    @Binding var selection: KeepAwakeDuration
    let tint: Color
    @State private var isChoosing = false

    var body: some View {
        Button {
            isChoosing.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(selection.shortLabel)
                    .font(.caption.monospacedDigit().weight(.bold))
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.34), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .frame(height: 30)
        .popover(isPresented: $isChoosing, arrowEdge: .trailing) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 4),
                      spacing: 6) {
                ForEach(KeepAwakeDuration.allCases) { duration in
                    let selected = duration == selection
                    Button {
                        selection = duration
                        isChoosing = false
                    } label: {
                        Text(duration.shortLabel)
                            .font(.caption.monospacedDigit().weight(selected ? .bold : .semibold))
                            .foregroundStyle(selected ? .white : .primary)
                            .frame(width: 48, height: 34)
                            .background(
                                selected ? tint : Color.primary.opacity(0.07),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel(duration.label)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(10)
        }
        .help("Choose how long Geraldine should keep this Mac awake")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake duration")
        .accessibilityValue(selection.label)
    }
}

/// ImageGen-inspired time field: discrete capsules follow a rounded-square perimeter.
/// Timed sessions keep remaining capsules bright while elapsed capsules become graphite.
private struct KeepAwakeTimeField: View {
    private struct Marker {
        let x: CGFloat
        let y: CGFloat
        let rotation: Double
    }

    let isActive: Bool
    let isPaused: Bool
    let progress: Double?
    let durationSeconds: TimeInterval?
    let durationLabel: String
    let remainingText: String?
    let action: () -> Void

    private static let markers: [Marker] = {
        var result: [Marker] = []
        func add(_ x: CGFloat, _ y: CGFloat, _ rotation: Double) {
            result.append(Marker(x: x / 218, y: y / 220, rotation: rotation))
        }
        [54, 76, 98, 120, 142, 164].forEach { add(CGFloat($0), 18, 0) }
        add(184, 24, 28)
        add(196, 40, 58)
        // Leave the cardinal point open for the quarter label instead of painting
        // a capsule underneath it.
        [62, 86, 134, 158].forEach { add(202, CGFloat($0), 90) }
        add(196, 180, 122)
        add(184, 196, 152)
        [164, 142, 120, 98, 76, 54].forEach { add(CGFloat($0), 202, 180) }
        add(34, 196, 208)
        add(22, 180, 238)
        [158, 134, 86, 62].forEach { add(16, CGFloat($0), 270) }
        add(22, 40, 302)
        add(34, 24, 332)
        return result
    }()

    private var remainingFraction: Double {
        guard isActive else { return 0 }
        guard let progress else { return 1 }
        return min(1, max(0, 1 - progress))
    }

    private var quarterLabels: [String]? {
        guard let seconds = durationSeconds else { return nil }
        return (0..<4).map {
            KeepAwakeTimeMarkerFormatter.string(seconds: seconds * Double($0) / 4)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let markerWidth = max(8, proxy.size.width * 0.043)
            let markerHeight = max(17, proxy.size.height * 0.09)
            let eyeSize = min(proxy.size.width * 0.56, proxy.size.height * 0.58)

            ZStack {
                ForEach(Array(Self.markers.enumerated()), id: \.offset) { index, marker in
                    let bright = isBright(index)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: bright
                                    ? [Color(red: 1.00, green: 0.57, blue: 0.43),
                                       Color(red: 1.00, green: 0.29, blue: 0.32)]
                                    : [Color(red: 0.19, green: 0.20, blue: 0.24),
                                       Color(red: 0.08, green: 0.09, blue: 0.11)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    bright ? .white.opacity(0.24) : .white.opacity(0.045),
                                    lineWidth: 0.7
                                )
                        }
                        .shadow(
                            color: bright ? Theme.Chart.red.opacity(0.52) : .black.opacity(0.48),
                            radius: bright ? 4 : 2,
                            y: 2
                        )
                        .frame(width: markerWidth, height: markerHeight)
                        .rotationEffect(.degrees(marker.rotation))
                        .position(
                            x: marker.x * proxy.size.width,
                            y: marker.y * proxy.size.height
                        )
                }

                if let quarterLabels {
                    markerLabel(quarterLabels[0])
                        .position(x: proxy.size.width * 0.50, y: proxy.size.height * 0.05)
                    markerLabel(quarterLabels[1])
                        .position(x: proxy.size.width * 0.94, y: proxy.size.height * 0.50)
                    markerLabel(quarterLabels[2])
                        .position(x: proxy.size.width * 0.50, y: proxy.size.height * 0.95)
                    markerLabel(quarterLabels[3])
                        .position(x: proxy.size.width * 0.07, y: proxy.size.height * 0.50)
                }

                Button(action: action) {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.30))
                            .frame(width: eyeSize + 16, height: eyeSize + 16)
                            .blur(radius: 5)
                        KeepAwakePokeableEye(
                            isActive: isActive && !isPaused,
                            size: eyeSize
                        )
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.keepAwakeEye)
                .help(isActive ? "Poke the eye to let your Mac sleep" : "Poke the eye to keep your Mac awake")
                .accessibilityLabel("Keep Awake")
                .accessibilityValue(
                    isActive
                        ? "\(isPaused ? "Paused" : "On")\(remainingText.map { ", \($0)" } ?? "")"
                        : "Off"
                )
                .accessibilityHint(
                    isActive
                        ? "Stops keeping this Mac awake."
                        : "Starts Keep Awake for \(durationLabel)."
                )

                if isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(.black.opacity(0.70), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                        .offset(x: eyeSize * 0.36, y: eyeSize * 0.36)
                        .accessibilityHidden(true)
                }

                if let remainingText {
                    Text(remainingText)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.58), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Theme.Chart.red.opacity(0.30), lineWidth: 0.7)
                        }
                        .position(
                            x: proxy.size.width * 0.50,
                            y: proxy.size.height * 0.155
                        )
                        .accessibilityHidden(true)
                }
            }
        }
        .animation(.linear(duration: 0.35), value: remainingFraction)
    }

    private func isBright(_ index: Int) -> Bool {
        guard isActive else { return false }
        guard progress != nil else { return true }
        let brightCount = Int((remainingFraction * Double(Self.markers.count)).rounded(.up))
        return index < brightCount
    }

    private func markerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 3.5)
            .padding(.vertical, 0.5)
            .background(.black.opacity(0.42), in: Capsule())
    }

}

enum KeepAwakeTimeMarkerFormatter {
    static func string(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }

        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let secondsRemainder = totalSeconds % 60

        if hours > 0 {
            return secondsRemainder == 0
                ? String(format: "%d:%02d", hours, minutes)
                : String(format: "%d:%02d:%02d", hours, minutes, secondsRemainder)
        }
        if secondsRemainder > 0 {
            return String(format: "%d:%02d", minutes, secondsRemainder)
        }
        return "\(minutes)m"
    }
}

/// Eight direct, non-overlapping targets in the same 2–3–3 spatial rhythm as the
/// ImageGen concept. While active, a new choice restarts the current session at
/// that duration so the selected node, exact countdown, and perimeter stay coherent.
private struct HoneycombDurationSelector: View {
    let selection: KeepAwakeDuration?
    let select: (KeepAwakeDuration) -> Void
    let isSessionActive: Bool

    private let firstRow: [KeepAwakeDuration] = [.tenMinutes, .thirtyMinutes]
    private let secondRow: [KeepAwakeDuration] = [.oneHour, .twoHours, .fourHours]
    private let thirdRow: [KeepAwakeDuration] = [.eightHours, .twelveHours, .indefinitely]

    var body: some View {
        VStack(spacing: -8) {
            durationRow(firstRow)
            durationRow(secondRow)
            durationRow(thirdRow)
        }
        .frame(maxWidth: .infinity)
        .help(isSessionActive
              ? "Choose a new duration for the current session"
              : "Choose a duration, then poke the eye")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake duration")
    }

    private func durationRow(_ durations: [KeepAwakeDuration]) -> some View {
        HStack(spacing: 7) {
            ForEach(durations) { duration in
                durationButton(duration)
            }
        }
    }

    private func durationButton(_ duration: KeepAwakeDuration) -> some View {
        let selected = duration == selection
        return Button {
            select(duration)
        } label: {
            Text(duration.shortLabel)
                .font(.rounded(16, selected ? .bold : .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.Chart.red : .white.opacity(0.82))
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: selected
                                    ? [Color(red: 0.25, green: 0.13, blue: 0.12),
                                       Color(red: 0.11, green: 0.08, blue: 0.09)]
                                    : [Color(red: 0.18, green: 0.19, blue: 0.23),
                                       Color(red: 0.075, green: 0.08, blue: 0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    selected ? Theme.Chart.red : .white.opacity(0.13),
                                    lineWidth: selected ? 2.5 : 1
                                )
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(selected ? 0.15 : 0.06), lineWidth: 1)
                                .padding(3)
                        }
                        .shadow(
                            color: selected ? Theme.Chart.red.opacity(0.34) : .black.opacity(0.58),
                            radius: selected ? 6 : 4,
                            y: 3
                        )
                }
                .contentShape(Circle())
        }
        .buttonStyle(HoneycombPressStyle())
        .accessibilityLabel(duration.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct HoneycombPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.91 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(
                GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .pointingHandCursor()
    }
}

/// The only available idle-activity delays are intentionally visible at once.
/// The label owns enable/disable; the lower segmented strip chooses 1m, 2m, or 5m.
private struct StayActiveWatchControl: View {
    @Binding var isEnabled: Bool
    @Binding var delayMinutes: Int
    let phase: IdleActivitySimulationPhase
    let error: String?
    let needsAccessibility: Bool
    let grantAccess: () -> Void

    private var hasFailure: Bool {
        isEnabled && (phase == .failed || phase == .needsAccessibility)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                Button {
                    isEnabled.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(
                                hasFailure
                                    ? Theme.warn
                                    : (isEnabled ? Theme.Chart.red : .white.opacity(0.24))
                            )
                            .frame(width: 7, height: 7)
                            .shadow(
                                color: hasFailure
                                    ? Theme.warn.opacity(0.48)
                                    : (isEnabled ? Theme.Chart.red.opacity(0.48) : .clear),
                                radius: 3
                            )
                        Text("Stay Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            }

            HStack(spacing: 0) {
                ForEach(KeepAwakeController.idleActivityDelayOptions, id: \.self) { minutes in
                    let selected = delayMinutes == minutes
                    let highlighted = isEnabled && selected
                    Button {
                        delayMinutes = minutes
                    } label: {
                        Text("\(minutes)m")
                            .font(.rounded(13, selected ? .bold : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                highlighted
                                    ? Theme.Chart.red
                                    : .white.opacity(isEnabled ? 0.72 : (selected ? 0.55 : 0.38))
                            )
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                highlighted
                                    ? Theme.Chart.red.opacity(0.14)
                                    : (selected ? .white.opacity(0.055) : Color.clear),
                                in: Capsule()
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel("Stay Active after \(minutes) minute\(minutes == 1 ? "" : "s")")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(.black.opacity(0.24), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .disabled(!isEnabled)

            if needsAccessibility {
                Button("Grant Accessibility Access", action: grantAccess)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .buttonStyle(.plain)
            } else if isEnabled, phase == .failed {
                Label(error ?? "Stay Active unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.warn)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stay Active")
        .accessibilityValue(
            hasFailure
                ? (error ?? "Unavailable")
                : (isEnabled
                    ? "On after \(delayMinutes) minute\(delayMinutes == 1 ? "" : "s")"
                    : "Off")
        )
    }
}

/// A compact, eye-centred progress display for an active Keep Awake session. Timed sessions
/// drain clockwise; indefinite sessions keep a calm full halo rather than implying a fake end.
private struct CountdownHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let progress: Double?
    let tint: Color
    let paused: Bool

    private let size: CGFloat = 62
    private let ringWidth: CGFloat = 4

    /// Keep Awake publishes elapsed progress; the visual intentionally shows time remaining.
    private var remainingFraction: Double {
        guard let progress else { return 1 }
        return min(1, max(0, 1 - progress))
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: ringWidth)

            if progress != nil {
                Circle()
                    .trim(from: 0, to: remainingFraction)
                    .stroke(AngularGradient(colors: [tint.opacity(0.45), tint], center: .center),
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .strokeBorder(tint.opacity(0.42), lineWidth: ringWidth)
            }

            KeepAwakePokeableEye(isActive: !paused, size: 44)
        }
        .frame(width: size, height: size)
        .opacity(paused ? 0.72 : 1)
        .overlay(alignment: .bottomTrailing) {
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.black.opacity(0.42), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
        .animation(GeraldineMotion.animation(.standard,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: remainingFraction)
        .animation(GeraldineMotion.animation(.quick,
                                             reduceMotion: reduceMotion || !surfaceActive),
                   value: paused)
        .accessibilityHidden(true)
    }
}
