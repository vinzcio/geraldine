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
        VStack(alignment: .leading, spacing: 7) {
            compactHeader(title: "Keep Awake")
            if let lastError {
                errorLabel(lastError, lineLimit: 2)
                Spacer(minLength: 0)
            } else {
                // The wheel takes exactly the height left between the fixed header and the
                // grouped idle section below, so it always meets the same lines as its neighbors.
                durationColumn(showLabel: false)
            }
            idleActivitySection(.pill)
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

    // MARK: - Large tile (full width)

    private var largeIdle: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(eyeSize: 46, title: "Keep Awake",
                   subtitle: "Poke the eye to stay awake — your Mac sleeps normally",
                   eyeIsSource: true)
            HStack(alignment: .top, spacing: 14) {
                durationColumn(showLabel: true)
                    .frame(width: 150)
                idleActivitySection(.full)
            }
            .frame(height: 118)
            if let lastError { errorLabel(lastError, lineLimit: 2) }
        }
    }

    /// The titled duration zone: an "Awake for" label over the scroll wheel, filling
    /// whatever height its container gives it so it lines up with the idle section.
    private func durationColumn(showLabel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showLabel { fieldLabel("Awake for", systemImage: "moon.zzz") }
            GeometryReader { proxy in
                durationWheel(height: proxy.size.height, compact: true)
            }
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

    private func durationWheel(height: CGFloat, compact: Bool) -> some View {
        DurationWheel(selection: durationSelection,
                      height: height,
                      rowHeight: compact ? 20 : 28,
                      tint: Module.keepAwake.tint)
            .help("Scroll to set how long to stay awake (now \(keepAwake.defaultDuration.label))")
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
            set: { keepAwake.defaultDuration = $0 }
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
        Toggle(isOn: $keepAwake.simulateIdleActivity) {
            Image(systemName: idleActivityIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(idleActivityTint)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .help("Enable Idle Activity after \(keepAwake.idleActivityDelayLabel)")
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
    }

    @ViewBuilder private func idleActivityOptions(compact: Bool) -> some View {
        let extendedIsCurrent = KeepAwakeController
            .idleActivityExtendedDelayOptions.contains(keepAwake.idleActivityDelayMinutes)
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
                Group {
                    if extendedIsCurrent {
                        chipLabel("\(keepAwake.idleActivityDelayMinutes)m", compact: compact)
                    } else {
                        chipLabel(systemImage: "ellipsis", compact: compact)
                    }
                }
                .foregroundStyle(extendedIsCurrent ? idleActivityTint : Color.secondary)
                .background(extendedIsCurrent ? idleActivityTint.opacity(0.14) : .clear, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a longer Idle Activity delay")
            .accessibilityLabel("More Idle Activity delays")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// One shared chip metric so the delay options, the overflow menu, and the extend
    /// actions all sit on the same 22pt line.
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

/// A compact, snap-to-row duration selector inspired by the iOS alarm wheel. The mask keeps
/// adjacent values legible while the selected row stays calm and readable in the center.
private struct DurationWheel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: KeepAwakeDuration
    let height: CGFloat
    let rowHeight: CGFloat
    let tint: Color
    @State private var scrollPosition: Int?

    /// Keep two complete cycles above and below the initial position. That preserves the
    /// familiar circular alarm-wheel affordance without an observable reset while scrolling.
    private let repetitionCount = 5

    private var durations: [KeepAwakeDuration] { KeepAwakeDuration.allCases }
    private var itemCount: Int { durations.count * repetitionCount }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceBase.opacity(0.48))

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<itemCount, id: \.self) { index in
                        let duration = duration(at: index)
                        Text(duration.shortLabel)
                            .font(.rounded(rowHeight >= 26 ? 20 : (rowHeight >= 20 ? 16 : 14), .semibold))
                            .monospacedDigit()
                            .foregroundStyle(duration == selection
                                             ? Color.primary
                                             : Color.secondary.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                selection = duration
                                scrollPosition = index
                            }
                            .accessibilityHidden(true)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, max(0, (height - rowHeight) / 2))
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollPosition)
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.16), location: 0),
                        .init(color: .black.opacity(0.82), location: 0.20),
                        .init(color: .black, location: 0.42),
                        .init(color: .black, location: 0.58),
                        .init(color: .black.opacity(0.82), location: 0.80),
                        .init(color: .black.opacity(0.16), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 1)
                }
                .frame(height: rowHeight + 4)
                .padding(.horizontal, 6)
                .shadow(color: tint.opacity(0.16), radius: 3, y: 1)
                .allowsHitTesting(false)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Duration")
        .accessibilityValue(selection.label)
        .accessibilityAdjustableAction { direction in
            let current = recenteredIndex(scrollPosition ?? initialIndex(for: selection))
            let nextIndex: Int
            switch direction {
            case .increment: nextIndex = current + 1
            case .decrement: nextIndex = current - 1
            @unknown default: return
            }
            selection = duration(at: nextIndex)
            scrollPosition = nextIndex
        }
        .onAppear {
            scrollPosition = initialIndex(for: selection)
        }
        .onChange(of: selection) { _, newValue in
            let target = nearestIndex(for: newValue, around: scrollPosition)
            guard scrollPosition != target else { return }
            if reduceMotion {
                scrollPosition = target
            } else {
                withAnimation(GeraldineMotion.animation(.standard, reduceMotion: false)) {
                    scrollPosition = target
                }
            }
        }
        .onChange(of: scrollPosition) { _, newIndex in
            guard let newIndex else { return }
            let newValue = duration(at: newIndex)
            if selection != newValue {
                selection = newValue
            }

            let recentered = recenteredIndex(newIndex)
            guard recentered != newIndex else { return }
            DispatchQueue.main.async {
                // The same duration and neighboring rows occupy both positions, so this
                // buffer reset is visually identical and never exposes a hard scroll edge.
                guard scrollPosition == newIndex else { return }
                scrollPosition = recentered
            }
        }
    }

    private func duration(at index: Int) -> KeepAwakeDuration {
        durations[index % durations.count]
    }

    private func initialIndex(for duration: KeepAwakeDuration) -> Int {
        let offset = durations.firstIndex(of: duration) ?? 0
        return (repetitionCount / 2) * durations.count + offset
    }

    private func recenteredIndex(_ index: Int) -> Int {
        let outerCycle = index < durations.count
            || index >= (repetitionCount - 1) * durations.count
        guard outerCycle else { return index }
        let wrappedOffset = (index % durations.count + durations.count) % durations.count
        return (repetitionCount / 2) * durations.count + wrappedOffset
    }

    private func nearestIndex(for duration: KeepAwakeDuration, around current: Int?) -> Int {
        let offset = durations.firstIndex(of: duration) ?? 0
        let anchor = current ?? initialIndex(for: duration)
        return (0..<repetitionCount)
            .map { $0 * durations.count + offset }
            .min { abs($0 - anchor) < abs($1 - anchor) }
            ?? initialIndex(for: duration)
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
