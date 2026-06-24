import SwiftUI
import AppKit

// MARK: - Pointing-hand cursor

/// Shows the macOS pointing-hand cursor while hovered — the standard "this is pokeable"
/// affordance that SwiftUI's plain buttons don't provide on their own. Pops on exit and
/// on disappear so the cursor can never get stuck if the view is removed mid-hover.
private struct PointingHandCursor: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
    }
}

extension View {
    /// Cue that the view can be poked: the cursor becomes a pointing hand on hover.
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 9, y: 3)
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardBackground(padding: padding)) }
}

// MARK: - Animated numeric text

struct AnimatedNumberText: View {
    var text: String
    var value: Double
    var animation: Animation = .easeInOut(duration: 0.24)

    @State private var previousText: String
    @State private var renderedText: String
    @State private var renderedValue: Double
    @State private var reservedRunWidths: [Int: Int]

    init(_ text: String, value: Double, animation: Animation = .easeInOut(duration: 0.24)) {
        self.text = text
        self.value = value.isFinite ? value : 0
        self.animation = animation
        _previousText = State(initialValue: text)
        _renderedText = State(initialValue: text)
        _renderedValue = State(initialValue: value.isFinite ? value : 0)
        _reservedRunWidths = State(initialValue: AnimatedNumberLayout.numberRunWidths(in: text))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(AnimatedNumberLayout.makeSegments(previous: previousText,
                                                       current: renderedText,
                                                       reservedRunWidths: reservedRunWidths)) { segment in
                switch segment.kind {
                case .literal(let text):
                    Text(text)
                case .number(let columns):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(columns) { column in
                            AnimatedNumberColumnView(column: column, value: renderedValue)
                        }
                    }
                }
            }
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(renderedText))
            .onChange(of: animationKey) { _, _ in
                reservedRunWidths = AnimatedNumberLayout.updatedRunWidths(reservedRunWidths,
                                                                          previous: renderedText,
                                                                          current: text)
                previousText = renderedText
                withAnimation(animation) {
                    renderedText = text
                    renderedValue = value.isFinite ? value : 0
                }
            }
    }

    private var animationKey: String {
        text
    }
}

private struct AnimatedNumberColumnView: View {
    let column: AnimatedNumberLayout.Column
    let value: Double

    var body: some View {
        ZStack {
            Text(column.sample)
                .hidden()
                .accessibilityHidden(true)
            if let character = column.current {
                Text(String(character))
                    .contentTransition(column.animates ? .numericText(value: value) : .identity)
            }
        }
    }
}

private enum AnimatedNumberLayout {
    struct Segment: Identifiable {
        enum Kind {
            case literal(String)
            case number([Column])
        }

        let id: Int
        let kind: Kind
    }

    struct Column: Identifiable {
        let id: Int
        let previous: Character?
        let current: Character?
        let sample: String

        var animates: Bool {
            guard previous != current,
                  let previous,
                  let current else { return false }
            return previous.isNumber && current.isNumber
        }
    }

    private struct Run {
        let isNumber: Bool
        let text: String
    }

    static func makeSegments(previous: String, current: String, reservedRunWidths: [Int: Int]) -> [Segment] {
        let previousRuns = runs(in: previous)
        let currentRuns = runs(in: current)

        guard previousRuns.count == currentRuns.count,
              zip(previousRuns, currentRuns).allSatisfy({ $0.isNumber == $1.isNumber }) else {
            return [Segment(id: 0, kind: .literal(current))]
        }

        return currentRuns.indices.map { index in
            let previousRun = previousRuns[index]
            let currentRun = currentRuns[index]
            if currentRun.isNumber {
                return Segment(id: index,
                               kind: .number(columns(previous: previousRun.text,
                                                     current: currentRun.text,
                                                     reservedWidth: reservedRunWidths[index] ?? 0)))
            }
            return Segment(id: index, kind: .literal(currentRun.text))
        }
    }

    static func numberRunWidths(in text: String) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: runs(in: text).enumerated().compactMap { index, run in
            run.isNumber ? (index, run.text.count) : nil
        })
    }

    static func updatedRunWidths(_ currentWidths: [Int: Int], previous: String, current: String) -> [Int: Int] {
        var updated = currentWidths
        for source in [previous, current] {
            for (index, width) in numberRunWidths(in: source) {
                updated[index] = max(updated[index] ?? 0, width)
            }
        }
        return updated
    }

    private static func runs(in text: String) -> [Run] {
        var result: [Run] = []
        var current = ""
        var currentIsNumber: Bool?

        for character in text {
            let isNumber = isNumberRunCharacter(character)
            if let currentIsNumber, currentIsNumber != isNumber {
                result.append(Run(isNumber: currentIsNumber, text: current))
                current = ""
            }
            current.append(character)
            currentIsNumber = isNumber
        }

        if let currentIsNumber {
            result.append(Run(isNumber: currentIsNumber, text: current))
        }

        return result
    }

    private static func columns(previous: String, current: String, reservedWidth: Int) -> [Column] {
        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        let count = max(max(previousCharacters.count, currentCharacters.count), reservedWidth)
        let previousAligned = rightAligned(previousCharacters, count: count)
        let currentAligned = rightAligned(currentCharacters, count: count)

        return (0..<count).map { index in
            Column(id: index - (count - 1),
                   previous: previousAligned[index],
                   current: currentAligned[index],
                   sample: sample(for: previousAligned[index], current: currentAligned[index]))
        }
    }

    private static func rightAligned(_ characters: [Character], count: Int) -> [Character?] {
        let padding = max(0, count - characters.count)
        return Array(repeating: nil, count: padding) + characters.map(Optional.some)
    }

    private static func sample(for previous: Character?, current: Character?) -> String {
        let character = current ?? previous ?? "8"
        if character == "." || character == "," { return String(character) }
        return "8"
    }

    private static func isNumberRunCharacter(_ character: Character) -> Bool {
        character.isNumber || character == "." || character == ","
    }
}

// MARK: - Gauge ring

struct GaugeRing: View {
    var value: Double            // 0…1
    var lineWidth: CGFloat = 10
    var tint: Color
    var center: AnyView

    init(value: Double, lineWidth: CGFloat = 10, tint: Color, @ViewBuilder center: () -> some View) {
        self.value = value
        self.lineWidth = lineWidth
        self.tint = tint
        self.center = AnyView(center())
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: value)
            center
        }
    }
}

// MARK: - Stat tile (icon + ring + caption)

struct StatTile: View {
    var icon: String
    var title: String
    var value: String
    var valueAnimationValue: Double?
    var caption: String
    var captionAnimationValue: Double?
    var fraction: Double         // 0…1 for the ring
    var tint: Color

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            GaugeRing(value: fraction, tint: tint) {
                VStack(spacing: 1) {
                    if let valueAnimationValue {
                        AnimatedNumberText(value, value: valueAnimationValue)
                            .font(.rounded(22, .semibold))
                    } else {
                        Text(value).font(.rounded(22, .semibold))
                    }
                    if let captionAnimationValue {
                        AnimatedNumberText(caption, value: captionAnimationValue)
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text(caption).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 104, height: 104)
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}

// MARK: - Linear stat bar

struct StatBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .animation(.easeInOut(duration: 0.5), value: fraction)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Primary button

struct PrimaryButton: View {
    var title: String
    var icon: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon) }
                Text(title).font(.rounded(14, .semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(Theme.brandGradient, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.rounded(15, .semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty / placeholder state

struct EmptyState: View {
    var icon: String
    var title: String
    var message: String
    var tint: Color = Theme.accent

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.12)).frame(width: 76, height: 76)
                Image(systemName: icon).font(.system(size: 30, weight: .medium)).foregroundStyle(tint)
            }
            Text(title).font(.rounded(18, .semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
