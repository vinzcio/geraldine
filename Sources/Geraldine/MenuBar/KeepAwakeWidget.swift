import SwiftUI

/// The Keep Awake control as a draggable, resizable tile. The eye is the toggle;
/// the duration wheel scrolls or steps to start a timed session. Lives in the same layout as
/// the metric widgets but never drives the menu-bar status item (see `menuBarKind`).
struct KeepAwakeWidget: View {
    let size: WidgetSize
    @EnvironmentObject private var keepAwake: KeepAwakeController
    @Environment(\.widgetCustomizationActive) private var customizationActive

    private var isSmall: Bool { size == .small }
    private var active: Bool { keepAwake.isActive }
    private var lastError: String? { active ? nil : keepAwake.lastError }
    private var controlsReserveWidth: CGFloat { 50 }
    private var largeWheelWidth: CGFloat { 58 }
    private var smallWheelWidth: CGFloat { 54 }

    var body: some View {
        Group { if isSmall { small } else { large } }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isSmall ? 100 : nil, alignment: .topLeading)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.bad.opacity(active ? 0.10 : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(active ? Theme.bad.opacity(0.35)
                                      : customizationActive ? Theme.accent.opacity(0.24) : .clear,
                                      lineWidth: 1))
            }
            .overlay(alignment: .topTrailing) {
                WidgetControls(kind: .keepAwake, size: size)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
            }
            .animation(.easeInOut(duration: 0.4), value: active)
            .widgetDropTarget(.keepAwake)
    }

    private var large: some View {
        ZStack(alignment: .trailing) {
            HStack(alignment: .center, spacing: 12) {
                eye(46)
                VStack(alignment: .leading, spacing: 8) {
                    titleAndStatus
                }
                Spacer(minLength: 0)
            }
            .padding(.trailing, largeWheelWidth + controlsReserveWidth + 8)

            DurationWheel(compact: false)
                .frame(width: largeWheelWidth)
                .padding(.trailing, controlsReserveWidth)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                eye(26)
                Text("Keep Awake")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.trailing, controlsReserveWidth)
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let lastError {
                        errorLabel(lastError, lineLimit: 2)
                    } else {
                        Text(keepAwake.statusLine)
                            .font(.caption2)
                            .foregroundStyle(active ? Theme.bad : .secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DurationWheel(compact: true)
                    .frame(width: smallWheelWidth)
            }
            Spacer(minLength: 0)
        }
    }

    private var titleAndStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Keep Awake").font(.caption.weight(.semibold))
            Text(keepAwake.statusLine)
                .font(.caption2)
                .foregroundStyle(active ? Theme.bad : .secondary)
                .lineLimit(1)
            if let lastError {
                errorLabel(lastError, lineLimit: 2)
            }
        }
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
        .help(active ? "Poke eyes to let your Mac sleep." : "Poke eyes to keep awake.")
    }
}

/// Slot-machine-like duration selector. It keeps the selected duration centered,
/// with wheel scrolling for browsing and chevrons for precise wraparound steps.
private struct DurationWheel: View {
    @EnvironmentObject private var keepAwake: KeepAwakeController
    var compact: Bool
    @State private var hovering = false
    @State private var centeredDuration: KeepAwakeDuration?

    private var durations: [KeepAwakeDuration] { KeepAwakeDuration.allCases }
    private var visibleRowCount: Int { compact ? 3 : 5 }
    private var rowHeight: CGFloat { compact ? 18 : 19 }
    private var wheelHeight: CGFloat { rowHeight * CGFloat(visibleRowCount) + 8 }
    private var selectedDuration: KeepAwakeDuration { centeredDuration ?? keepAwake.defaultDuration }
    private var selectedIndex: Int { durations.firstIndex(of: selectedDuration) ?? 0 }
    private var scrollPadding: CGFloat { max(0, (wheelHeight - rowHeight) / 2) }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selectionFill)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.bad.opacity(keepAwake.isActive ? 0.42 : 0.28), lineWidth: 1))
                    .frame(height: rowHeight + 5)
                    .padding(.horizontal, 6)

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(durations) { duration in
                            row(duration)
                                .id(duration)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, scrollPadding)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $centeredDuration, anchor: .center)

                slotShade(start: .top, end: .bottom)
                    .frame(height: compact ? 12 : 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                slotShade(start: .bottom, end: .top)
                    .frame(height: compact ? 12 : 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                VStack {
                    stepButton(systemName: "chevron.up", delta: -1)
                    Spacer(minLength: 0)
                    stepButton(systemName: "chevron.down", delta: 1)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: wheelHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.06), lineWidth: 1))
            .onAppear {
                centeredDuration = keepAwake.defaultDuration
                proxy.scrollTo(keepAwake.defaultDuration, anchor: .center)
            }
            .onChange(of: keepAwake.defaultDuration) { _, newValue in
                guard centeredDuration != newValue else { return }
                centeredDuration = newValue
                withAnimation(.snappy(duration: 0.24)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: centeredDuration) { _, newValue in
                guard let newValue, keepAwake.defaultDuration != newValue else { return }
                select(newValue)
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.snappy(duration: 0.24), value: keepAwake.defaultDuration)
        }
    }

    private var selectionFill: Color {
        keepAwake.isActive ? Theme.bad : Theme.bad.opacity(0.14)
    }

    private func duration(steppingBy delta: Int) -> KeepAwakeDuration {
        let count = durations.count
        let rawIndex = selectedIndex + delta
        let wrappedIndex = (rawIndex % count + count) % count
        return durations[wrappedIndex]
    }

    private func row(_ duration: KeepAwakeDuration) -> some View {
        let selected = duration == selectedDuration
        let distance = abs((durations.firstIndex(of: duration) ?? 0) - selectedIndex)
        return Button {
            select(duration)
        } label: {
            Text(duration.shortLabel)
                .font(.system(size: selected ? (compact ? 12 : 13) : (compact ? 10 : 11),
                              weight: selected ? .bold : .semibold,
                              design: .rounded))
                .monospacedDigit()
                .foregroundColor(textColor(selected: selected))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .opacity(selected ? 1 : (distance == 1 ? 0.72 : 0.45))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Keep awake for \(duration.label)")
        .accessibilityLabel(selected
                            ? "Selected duration, \(duration.label)"
                            : "Keep awake for \(duration.label)")
    }

    private func stepButton(systemName: String, delta: Int) -> some View {
        Button {
            select(duration(steppingBy: delta))
        } label: {
            Image(systemName: systemName)
                .font(.system(size: compact ? 7 : 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: compact ? 14 : 16, height: compact ? 12 : 14)
                .background(Color.primary.opacity(hovering ? 0.10 : 0.07), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(delta < 0 ? "Previous duration" : "Next duration")
        .accessibilityLabel(delta < 0 ? "Previous duration" : "Next duration")
    }

    private func select(_ duration: KeepAwakeDuration) {
        withAnimation(.snappy(duration: 0.24)) {
            centeredDuration = duration
            keepAwake.defaultDuration = duration
        }
        keepAwake.activate(option: duration)
    }

    private func textColor(selected: Bool) -> Color {
        if selected, keepAwake.isActive { return .white }
        if selected { return Theme.bad }
        return .secondary
    }

    private func slotShade(start: UnitPoint, end: UnitPoint) -> some View {
        LinearGradient(colors: [Color.primary.opacity(0.10), .clear],
                       startPoint: start,
                       endPoint: end)
            .allowsHitTesting(false)
    }
}
