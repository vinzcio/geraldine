import SwiftUI

/// The Keep Awake control as a draggable, resizable tile. Idle and active are two distinct
/// layouts: idle picks a duration and starts; active leads with the time remaining, a progress
/// bar toward the end, and stop / extend. The eye and the Start/Stop button arm or end a session —
/// choosing a duration never starts one. Lives in the same grid as the metric widgets but never
/// drives the menu-bar status item (see `menuBarKind`).
struct KeepAwakeWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.widgetCustomizationActive) private var customizationActive

    private var isSmall: Bool { size == .small }
    private var active: Bool { keepAwake.isActive }
    private var lastError: String? { active ? nil : keepAwake.lastError }

    /// The top row must clear the drag/resize controls floating in the top-trailing corner.
    private let controlsReserve: CGFloat = 46

    var body: some View {
        Group { if isSmall { small } else { large } }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isSmall ? 100 : nil, alignment: .topLeading)
            .padding(10)
            .background { tileBackground }
            .overlay(alignment: .topTrailing) {
                WidgetControls(kind: .keepAwake, size: size)
                    .padding(10)
            }
            .animation(.easeInOut(duration: 0.4), value: active)
            .widgetDropTarget(.keepAwake)
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.quaternary.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.bad.opacity(active ? 0.10 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(active ? Theme.bad.opacity(0.35)
                              : customizationActive ? Theme.accent.opacity(0.24) : .clear,
                              lineWidth: 1))
    }

    // MARK: - Small tile

    @ViewBuilder private var small: some View {
        if active { smallActive } else { smallIdle }
    }

    private var smallIdle: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(eyeSize: 26, title: "Keep Awake", subtitle: nil)
            HStack(spacing: 6) {
                durationPill
                actionButton(compact: true)
                idleActivityMenuPill
                Spacer(minLength: 0)
            }
            if let lastError { errorLabel(lastError, lineLimit: 2) }
            Spacer(minLength: 0)
        }
    }

    private var smallActive: some View {
        VStack(alignment: .leading, spacing: 5) {
            header(eyeSize: 26, title: "Awake", subtitle: nil, tint: Theme.bad)
            remainingHeadline(size: 21)
            if hasEnd { StatBar(fraction: progress, tint: Theme.bad, height: 4) }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(secondaryStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                idleActivityMenuPill
                actionButton(compact: true)
            }
        }
    }

    // MARK: - Large tile

    @ViewBuilder private var large: some View {
        if active { largeActive } else { largeIdle }
    }

    private var largeIdle: some View {
        VStack(alignment: .leading, spacing: 11) {
            header(eyeSize: 44, title: "Keep Awake", subtitle: "Your Mac sleeps normally")
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

    private var largeActive: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(eyeSize: 44, title: "Awake", subtitle: secondaryStatus, tint: Theme.bad)
            remainingHeadline(size: 30)
            if hasEnd { StatBar(fraction: progress, tint: Theme.bad, height: 6) }
            idleActivityRow
            HStack(spacing: 8) {
                if hasEnd {
                    extendChip("+30m", 30 * 60)
                    extendChip("+1h", 60 * 60)
                }
                Spacer(minLength: 0)
                actionButton(compact: false)
            }
        }
    }

    // MARK: - Pieces

    private func header(eyeSize: CGFloat, title: String, subtitle: String?, tint: Color = .primary) -> some View {
        let large = eyeSize > 30
        return HStack(spacing: large ? 12 : 8) {
            eye(eyeSize)
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
        .padding(.trailing, controlsReserve)
    }

    @ViewBuilder private func remainingHeadline(size: CGFloat) -> some View {
        if hasEnd {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                AnimatedNumberText(remainingString, value: keepAwake.remaining ?? 0)
                    .font(.rounded(size, .bold))
                    .foregroundStyle(Theme.bad)
                Text("left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("No time limit")
                .font(.rounded(size * 0.62, .semibold))
                .foregroundStyle(Theme.bad)
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
            withAnimation(.snappy(duration: 0.2)) { keepAwake.defaultDuration = duration }
        } label: {
            Text(duration.shortLabel)
                .font(.rounded(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.accent : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(selected ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.55) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Set the duration to \(duration.label)")
        .accessibilityLabel(duration.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var durationPill: some View {
        Menu {
            Picker("Duration", selection: $keepAwake.defaultDuration) {
                ForEach(KeepAwakeDuration.allCases) { Text($0.label).tag($0) }
            }
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
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help("Choose how long to stay awake")
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
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warn)
                    .pointingHandCursor()
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
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(idleActivityTint.opacity(keepAwake.simulateIdleActivity ? 0.22 : 0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Idle Activity")
        .accessibilityValue(keepAwake.idleActivityStatusLine)
    }

    private var idleActivityMenuPill: some View {
        Menu {
            Toggle("Enable Idle Activity", isOn: $keepAwake.simulateIdleActivity)
            Stepper(value: $keepAwake.idleActivityDelayMinutes, in: 1...120, step: 1) {
                Text("Start After \(keepAwake.idleActivityDelayLabel)")
            }
            if keepAwake.idleActivityNeedsAccessibility {
                Button("Grant Accessibility") {
                    keepAwake.refreshIdleActivityAccess(prompt: true)
                }
            }
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
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(idleActivityTint.opacity(keepAwake.simulateIdleActivity ? 0.22 : 0.10), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help("Set how long Geraldine waits before simulating activity")
        .accessibilityLabel("Idle Activity timer")
        .accessibilityValue(keepAwake.idleActivityDelayLabel)
    }

    private func actionButton(compact: Bool) -> some View {
        Button { keepAwake.toggle() } label: {
            HStack(spacing: 5) {
                if !compact { Image(systemName: active ? "stop.fill" : "play.fill") }
                Text(active ? "Stop" : "Start")
            }
            .font(compact ? .caption2.weight(.bold) : .caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(.white)
            .background(active ? Theme.bad : Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(active ? "Stop Keep Awake." : "Start Keep Awake for the selected duration.")
        .accessibilityLabel(active ? "Stop Keep Awake" : "Start Keep Awake")
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
        .buttonStyle(.plain)
        .pointingHandCursor()
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

    private func eye(_ eyeSize: CGFloat) -> some View {
        Button { keepAwake.toggle() } label: {
            EyeView(isActive: active, size: eyeSize)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
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
        case .pulsing: return Theme.accent
        case .needsAccessibility, .failed: return Theme.warn
        default: return .secondary
        }
    }

    private var remainingString: String {
        guard let remaining = keepAwake.remaining else { return "On" }
        return KeepAwakeController.durationString(remaining)
    }

    /// Sub-line shown while active: the pause reason if paused, otherwise the end time.
    private var secondaryStatus: String {
        if keepAwake.isPaused, let reason = keepAwake.pauseReason { return "Paused · \(reason)" }
        return hasEnd ? keepAwake.endTimeLine : "No time limit"
    }

    private var startHint: String {
        keepAwake.defaultDuration == .indefinitely ? "No time limit" : "For \(keepAwake.defaultDuration.label)"
    }
}
