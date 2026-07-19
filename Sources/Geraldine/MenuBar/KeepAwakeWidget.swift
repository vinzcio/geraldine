import SwiftUI

/// The Keep Awake control as a draggable, resizable tile. Idle and active are two distinct
/// layouts per size: idle picks a duration and starts; active leads with the countdown.
/// The eye and the Start/Stop button arm or end a session —
/// choosing a duration never starts one. Lives in the same grid as the metric widgets but never
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
            case .large:  stateSwitcher(idle: { largeIdle }, active: { expandedActive(compact: false) })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background { tileBackground }
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

    private var tileBackground: some View {
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
            .animation(GeraldineMotion.animation(.standard, reduceMotion: motionReduced), value: active)
    }

    // MARK: - Small tile

    private var smallIdle: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(eyeSize: 26, title: "Keep Awake", subtitle: nil, eyeIsSource: true)
            HStack(spacing: 6) {
                durationPill
                actionButton(compact: true)
                Spacer(minLength: 0)
            }
            if let lastError { errorLabel(lastError, lineLimit: 2) }
            Spacer(minLength: 0)
        }
    }

    private var smallActive: some View {
        VStack(alignment: .leading, spacing: 5) {
            header(eyeSize: 26, title: "Awake", subtitle: nil,
                   tint: stateTint, eyeIsSource: false)
            remainingHeadline(size: 21)
            // Drains like the countdown halo: the bar shows time *remaining*.
            if hasEnd { StatBar(fraction: 1 - progress, tint: Theme.Chart.red, height: 4) }
            Spacer(minLength: 0)
            // The idle-activity menu replaces the end-time line here (the
            // countdown headline already carries the time): the small active
            // tile has room for only two controls, and idle activity must stay
            // reachable because toggling it affects the running session.
            HStack(spacing: 6) {
                idleActivityMenuPill
                Spacer(minLength: 4)
                actionButton(compact: true)
            }
        }
    }

    // MARK: - Medium tile (2×1, shared unit height)

    private var mediumIdle: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(eyeSize: 36, title: "Keep Awake", subtitle: "Your Mac Sleeps Normally",
                   eyeIsSource: true)
            if let lastError { errorLabel(lastError, lineLimit: 1) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                durationPill
                idleActivityMenuPill
                Spacer(minLength: 4)
                actionButton(compact: false)
            }
        }
    }

    /// The active session layout the medium and large tiles share: countdown hero,
    /// a remaining-time bar that drains like the halo, then idle/extend/stop controls.
    private func expandedActive(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            activeCountdownHero
            if hasEnd { StatBar(fraction: 1 - progress, tint: Theme.Chart.red, height: compact ? 4 : 5) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                idleActivityMenuPill
                if hasEnd {
                    extendChip("+30m", 30 * 60)
                    extendChip("+1h", 60 * 60)
                }
                Spacer(minLength: 0)
                actionButton(compact: compact)
            }
        }
    }

    // MARK: - Large tile (full width)

    private var largeIdle: some View {
        VStack(alignment: .leading, spacing: 11) {
            header(eyeSize: 44, title: "Keep Awake", subtitle: "Your Mac Sleeps Normally",
                   eyeIsSource: true)
            durationGrid
            idleActivityRow
            HStack(spacing: 10) {
                actionButton(compact: false)
                Text(startHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            if let lastError { errorLabel(lastError, lineLimit: 2) }
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

    private var durationGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(KeepAwakeDuration.allCases) { durationCard($0) }
        }
    }

    private func durationCard(_ duration: KeepAwakeDuration) -> some View {
        let selected = keepAwake.defaultDuration == duration
        return Button {
            if let animation = GeraldineMotion.animation(.standard, reduceMotion: motionReduced) {
                withAnimation(animation) { keepAwake.defaultDuration = duration }
            } else {
                keepAwake.defaultDuration = duration
            }
        } label: {
            Text(duration.shortLabel)
                .font(.rounded(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Module.keepAwake.tint : .secondary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .background(Theme.surfaceBase.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        }
        .buttonStyle(.geraldineSelection(Module.keepAwake.tint,
                                         isSelected: selected,
                                         cornerRadius: Theme.Radius.badge))
        .minimumHitArea()
        .help("Set the duration to \(duration.label)")
        .accessibilityLabel(duration.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var durationPill: some View {
        Menu {
            Picker("Duration", selection: $keepAwake.defaultDuration) {
                ForEach(KeepAwakeDuration.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            idleActivityMenuItems
        } label: {
            HStack(spacing: 4) {
                Text(keepAwake.defaultDuration.shortLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surfaceBase.opacity(0.76), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitArea()
        .pointingHandCursor()
        .help("Choose duration and idle activity")
    }

    private var idleActivityRow: some View {
        HStack(spacing: 7) {
            Image(systemName: idleActivityIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(idleActivityTint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text("Idle Activity")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(keepAwake.idleActivityStatusLine)
                    .font(.caption2)
                    .foregroundStyle(idleActivityTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
            if keepAwake.idleActivityNeedsAccessibility {
                Button("Grant") { keepAwake.refreshIdleActivityAccess(prompt: true) }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.quiet(Theme.warn))
                    .help("Grant Accessibility access")
            }
            Stepper(value: $keepAwake.idleActivityDelayMinutes, in: 1...120, step: 1) {
                Text(keepAwake.idleActivityDelayLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .controlSize(.mini)
            .fixedSize()
            .help("Set how long Geraldine waits before simulating activity")
            Toggle("Idle Activity", isOn: $keepAwake.simulateIdleActivity)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
            .strokeBorder(idleActivityTint.opacity(keepAwake.simulateIdleActivity ? 0.22 : 0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
    }

    /// The idle-activity controls, shared by the small tile's duration menu and the large tile's
    /// idle pill. A Stepper is inert inside an NSMenu-backed Menu, so the delay uses a Picker.
    @ViewBuilder private var idleActivityMenuItems: some View {
        Toggle("Enable Idle Activity", isOn: $keepAwake.simulateIdleActivity)
        Picker("Start After", selection: $keepAwake.idleActivityDelayMinutes) {
            ForEach(idleActivityDelayOptions, id: \.self) { minutes in
                Text(idleActivityDelayMenuLabel(minutes)).tag(minutes)
            }
        }
        if keepAwake.idleActivityNeedsAccessibility {
            Button("Grant Accessibility") {
                keepAwake.refreshIdleActivityAccess(prompt: true)
            }
        }
    }

    private static let idleActivityDelayPresets = [1, 2, 5, 10, 15, 30, 60, 120]

    /// Presets, plus the current value when the large tile's stepper picked an off-preset delay,
    /// so the menu always shows the active selection.
    private var idleActivityDelayOptions: [Int] {
        let current = keepAwake.idleActivityDelayMinutes
        guard !Self.idleActivityDelayPresets.contains(current) else { return Self.idleActivityDelayPresets }
        return (Self.idleActivityDelayPresets + [current]).sorted()
    }

    private func idleActivityDelayMenuLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1:   return "1 Minute"
        case 60:  return "1 Hour"
        case 120: return "2 Hours"
        default:  return "\(minutes) Minutes"
        }
    }

    private var idleActivityMenuPill: some View {
        Menu {
            idleActivityMenuItems
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 9, weight: .semibold))
                Text("Idle \(keepAwake.idleActivityDelayLabel)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(idleActivityTint)
            .background(Theme.surfaceBase.opacity(0.76), in: Capsule())
            .overlay(Capsule().strokeBorder(idleActivityTint.opacity(keepAwake.simulateIdleActivity ? 0.22 : 0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .minimumHitArea()
        .pointingHandCursor()
        .help("Set how long Geraldine waits before simulating activity")
        .accessibilityLabel("Idle Activity timer")
        .accessibilityValue(keepAwake.idleActivityDelayLabel)
    }

    @ViewBuilder private func actionButton(compact: Bool) -> some View {
        let button = Button { keepAwake.toggle() } label: {
            HStack(spacing: 5) {
                ContextualSymbol(
                    inactive: "play.fill",
                    active: "stop.fill",
                    isActive: active,
                    tint: stateTint,
                    size: compact ? 9 : 11
                )
                Text(active ? "Stop" : "Start")
                    .lineLimit(1)
            }
        }

        if compact {
            button
                .buttonStyle(.soft(stateTint, compact: true))
                .help(active ? "Stop Keep Awake." : "Start Keep Awake for the selected duration.")
                .accessibilityLabel(active ? "Stop Keep Awake" : "Start Keep Awake")
        } else {
            button
                .buttonStyle(.soft(stateTint))
                .help(active ? "Stop Keep Awake." : "Start Keep Awake for the selected duration.")
                .accessibilityLabel(active ? "Stop Keep Awake" : "Start Keep Awake")
        }
    }

    private func extendChip(_ label: String, _ seconds: TimeInterval) -> some View {
        Button { keepAwake.extend(by: seconds) } label: {
            Text(label)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(Theme.bad)
                .background(Theme.bad.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.bad.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.quiet(Theme.bad))
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

    private var startHint: String {
        keepAwake.defaultDuration == .indefinitely ? "No Time Limit" : "For \(keepAwake.defaultDuration.label)"
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
