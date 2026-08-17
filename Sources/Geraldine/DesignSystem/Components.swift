import SwiftUI
import AppKit

// MARK: - Pointing-hand cursor

/// Shows the macOS pointing-hand cursor while hovered — the standard "this is pokeable"
/// affordance that SwiftUI's plain buttons don't provide on their own. Pops on exit and
/// on disappear so the cursor can never get stuck if the view is removed mid-hover.
private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard isEnabled else {
                    if hovering { NSCursor.pop(); hovering = false }
                    return
                }
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled, hovering { NSCursor.pop(); hovering = false }
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

enum CardTier {
    case base
    case raised
    case floating
    case tinted(Color)
    /// Calm content surface: solid fill, no border, no shadow. The default for
    /// secondary dashboard content so only the page's hero carries elevation.
    case quiet
    /// The one strong surface per page: material fill, a tinted light wash
    /// falling in from the leading edge, gradient edge lighting, and a
    /// tint-colored floating shadow.
    case hero(Color)
}

enum AdaptiveMaterialTier {
    case ultraThin
    case thin
    case regular
}

private struct AdaptiveMaterialBackground<ShapeType: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let tier: AdaptiveMaterialTier
    let shape: ShapeType

    func body(content: Content) -> some View {
        content.background {
            shape.fill(backgroundStyle)
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if reduceTransparency || colorSchemeContrast == .increased {
            switch tier {
            case .ultraThin: return AnyShapeStyle(Theme.surfaceBase)
            case .thin: return AnyShapeStyle(Theme.surfaceRaised)
            case .regular: return AnyShapeStyle(Theme.surfaceFloating)
            }
        }
        switch tier {
        case .ultraThin: return AnyShapeStyle(.ultraThinMaterial)
        case .thin: return AnyShapeStyle(.thinMaterial)
        case .regular: return AnyShapeStyle(.regularMaterial)
        }
    }
}

/// Behind-window vibrancy for the app shell. SwiftUI materials only blur
/// content *within* the window; a real translucent sidebar needs AppKit's
/// behind-window blending so the desktop shows through like native Mac apps.
struct VibrantSidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        if reduceTransparency || colorSchemeContrast == .increased {
            Theme.sidebar
        } else {
            BehindWindowMaterial(material: .sidebar)
                .overlay(Theme.sidebar.opacity(0.45))
        }
    }
}

private struct BehindWindowMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    var padding: CGFloat = 18
    var tier: CardTier = .raised
    var interactive = false
    var cornerRadius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background {
                shape
                    .fill(backgroundStyle)
                    .overlay { shape.fill(tintOverlay) }
            }
            .overlay {
                shape.strokeBorder(outlineStyle,
                                   lineWidth: hoverActive ? 1.2 : 1)
            }
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                y: shadowY
            )
            .offset(y: hoverActive && !reduceMotion ? -1 : 0)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
            .onHover { inside in
                guard interactive else { return }
                isHovered = isEnabled && inside
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
    }

    private var hoverActive: Bool { interactive && isEnabled && isHovered }

    private var backgroundStyle: AnyShapeStyle {
        if reduceTransparency || colorSchemeContrast == .increased {
            switch tier {
            case .quiet: return AnyShapeStyle(Theme.surfaceBase)
            case .base: return AnyShapeStyle(Theme.surfaceBase)
            case .raised, .tinted(_): return AnyShapeStyle(Theme.surfaceRaised)
            case .floating, .hero(_): return AnyShapeStyle(Theme.surfaceFloating)
            }
        }

        switch tier {
        case .quiet:
            return AnyShapeStyle(hoverActive ? Theme.surfaceRaised : Theme.surfaceBase)
        case .base:
            return AnyShapeStyle(.ultraThinMaterial)
        case .raised, .tinted(_):
            return AnyShapeStyle(.thinMaterial)
        case .floating, .hero(_):
            return AnyShapeStyle(.regularMaterial)
        }
    }

    private var tintOverlay: AnyShapeStyle {
        switch tier {
        case .tinted(let tint):
            return AnyShapeStyle(
                Theme.decorativeFill(tint, strength: colorScheme == .dark ? .standard : .subtle)
            )
        case .hero(let tint):
            return AnyShapeStyle(
                RadialGradient(
                    colors: [tint.opacity(colorScheme == .dark ? 0.20 : 0.13), .clear],
                    center: UnitPoint(x: 0.10, y: 0.42),
                    startRadius: 0,
                    endRadius: 460
                )
            )
        default:
            return AnyShapeStyle(Color.clear)
        }
    }

    private var outlineStyle: AnyShapeStyle {
        if colorSchemeContrast == .increased {
            return AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.34) : Color.black.opacity(0.24))
        }
        switch tier {
        case .quiet:
            return AnyShapeStyle(hoverActive ? Theme.separator : Color.clear)
        case .hero(let tint):
            return AnyShapeStyle(
                LinearGradient(
                    colors: [tint.opacity(colorScheme == .dark ? 0.55 : 0.40),
                             tint.opacity(0.07)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        default:
            if colorScheme == .dark {
                return AnyShapeStyle(Color.white.opacity(hoverActive ? 0.15 : 0.09))
            }
            return AnyShapeStyle(Color.black.opacity(hoverActive ? 0.10 : 0.06))
        }
    }

    private var shadowColor: Color {
        if case .hero(let tint) = tier {
            return tint.opacity(colorScheme == .dark ? 0.30 : 0.18)
        }
        return .black.opacity(shadowOpacity)
    }

    private var shadowOpacity: Double {
        let boost = hoverActive ? 0.04 : 0
        switch tier {
        case .quiet:
            return hoverActive ? (colorScheme == .dark ? Theme.Shadow.darkBaseOpacity : Theme.Shadow.lightBaseOpacity) : 0
        case .base:
            return (colorScheme == .dark ? Theme.Shadow.darkBaseOpacity : Theme.Shadow.lightBaseOpacity) + boost
        case .raised, .tinted(_):
            return (colorScheme == .dark ? Theme.Shadow.darkRaisedOpacity : Theme.Shadow.lightRaisedOpacity) + boost
        case .floating, .hero(_):
            return (colorScheme == .dark ? Theme.Shadow.darkFloatingOpacity : Theme.Shadow.lightFloatingOpacity) + boost
        }
    }

    private var shadowRadius: CGFloat {
        switch tier {
        case .quiet: hoverActive ? Theme.Shadow.baseRadius : 0
        case .base: Theme.Shadow.baseRadius
        case .raised, .tinted(_): hoverActive ? 12 : Theme.Shadow.raisedRadius
        case .floating, .hero(_): hoverActive ? 20 : Theme.Shadow.floatingRadius
        }
    }

    private var shadowY: CGFloat {
        switch tier {
        case .quiet: hoverActive ? Theme.Shadow.baseY : 0
        case .base: Theme.Shadow.baseY
        case .raised, .tinted(_): hoverActive ? 4 : Theme.Shadow.raisedY
        case .floating, .hero(_): hoverActive ? 8 : Theme.Shadow.floatingY
        }
    }
}

/// Card chrome remains a passive layout surface. Only a real `Button` should
/// own press, focus, disabled, and keyboard semantics; this style supplies
/// those states without turning cards that contain controls into dead focus stops.
struct ActionableCardButtonStyle: ButtonStyle {
    var padding: CGFloat = 18
    var tier: CardTier = .raised
    var cornerRadius: CGFloat = Theme.Radius.card

    func makeBody(configuration: Configuration) -> some View {
        ActionableCardButtonBody(configuration: configuration,
                                 padding: padding,
                                 tier: tier,
                                 cornerRadius: cornerRadius)
    }
}

private struct ActionableCardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let padding: CGFloat
    let tier: CardTier
    let cornerRadius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .interactiveCard(padding: padding, tier: tier, cornerRadius: cornerRadius)
            .overlay {
                shape.strokeBorder(isFocused && isEnabled ? Theme.focusRing : .clear,
                                   lineWidth: 2)
            }
            .scaleEffect(configuration.isPressed && isEnabled && !reduceMotion
                         ? GeraldineMotion.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.50)
            .contentShape(shape)
            .focusEffectDisabled()
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion),
                       value: isFocused)
            .pointingHandCursor()
    }
}

extension View {
    func adaptiveMaterialBackground<S: Shape>(
        _ tier: AdaptiveMaterialTier,
        in shape: S
    ) -> some View {
        modifier(AdaptiveMaterialBackground(tier: tier, shape: shape))
    }

    func card(
        padding: CGFloat = 18,
        tier: CardTier = .raised,
        cornerRadius: CGFloat = Theme.Radius.card
    ) -> some View {
        modifier(CardBackground(padding: padding, tier: tier, cornerRadius: cornerRadius))
    }

    func interactiveCard(
        padding: CGFloat = 18,
        tier: CardTier = .raised,
        cornerRadius: CGFloat = Theme.Radius.card
    ) -> some View {
        modifier(CardBackground(
            padding: padding,
            tier: tier,
            interactive: true,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Animated numeric text

struct AnimatedNumberText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    var text: String
    var value: Double
    var animation: Animation?

    @State private var previousText: String
    @State private var renderedText: String
    @State private var renderedValue: Double
    @State private var reservedRunWidths: [Int: Int]
    @State private var lastAnimatedAt: TimeInterval = 0

    init(_ text: String, value: Double, animation: Animation? = nil) {
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
                case .literal(let previous, let current):
                    ZStack(alignment: .leading) {
                        Text(previous).hidden().accessibilityHidden(true)
                        Text(current).hidden().accessibilityHidden(true)
                        Text(current)
                            .contentTransition(previous == current || reduceMotion || !surfaceActive
                                               ? .identity : .opacity)
                    }
                case .number(let columns):
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        ForEach(columns) { column in
                            AnimatedNumberColumnView(column: column, value: renderedValue)
                        }
                    }
                }
            }
        }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(renderedText))
            .onChange(of: animationKey) { _, _ in
                reservedRunWidths = AnimatedNumberLayout.updatedRunWidths(reservedRunWidths,
                                                                          previous: renderedText,
                                                                          current: text)
                previousText = renderedText
                let update = {
                    renderedText = text
                    renderedValue = value.isFinite ? value : 0
                }
                // The cadence gate (not the roll's duration) is what keeps live
                // metrics cheap: rolls play at most once per interval and the
                // samples in between apply instantly.
                let now = ProcessInfo.processInfo.systemUptime
                let cadenceAllows = now - lastAnimatedAt >= GeraldineMotion.liveMetricAnimationInterval
                if cadenceAllows,
                   let animation = reduceMotion || !surfaceActive
                    ? nil
                    : (animation ?? GeraldineMotion.animation(.standard, reduceMotion: false)) {
                    lastAnimatedAt = now
                    withAnimation(animation, update)
                } else {
                    update()
                }
            }
    }

    private var animationKey: String {
        text
    }
}

private struct AnimatedNumberColumnView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    let column: AnimatedNumberLayout.Column
    let value: Double

    var body: some View {
        ZStack {
            Text(column.sample)
                .hidden()
                .accessibilityHidden(true)
            if let character = column.current {
                Text(String(character))
                    .contentTransition(column.animates && !reduceMotion && surfaceActive
                                       ? .numericText(value: -value) : .identity)
            }
        }
    }
}

enum AnimatedNumberLayout {
    struct Segment: Identifiable {
        enum Kind {
            case literal(previous: String, current: String)
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
            return [Segment(id: 0, kind: .literal(previous: previous, current: current))]
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
            return Segment(id: index,
                           kind: .literal(previous: previousRun.text, current: currentRun.text))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive
    @State private var revealed = false
    @State private var displayedValue: Double
    @State private var lastAnimatedAt: TimeInterval = 0

    var value: Double            // 0…1
    var lineWidth: CGFloat = 10
    var tint: Color
    var center: AnyView

    init(value: Double, lineWidth: CGFloat = 10, tint: Color, @ViewBuilder center: () -> some View) {
        self.value = value
        self.lineWidth = lineWidth
        self.tint = tint
        self.center = AnyView(center())
        _displayedValue = State(initialValue: value)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.06), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: revealed ? max(0.001, min(1, displayedValue)) : 0.001)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .onChange(of: value) { _, newValue in
            // Live metrics move every second; animating each wiggle kept a
            // window-wide render wave in flight ~continuously. Roll the ring
            // on the shared cadence, apply the in-between samples instantly.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAnimatedAt >= GeraldineMotion.liveMetricAnimationInterval,
               surfaceActive, !reduceMotion,
               let animation = GeraldineMotion.animation(.standard, reduceMotion: false) {
                lastAnimatedAt = now
                withAnimation(animation) { displayedValue = newValue }
            } else {
                displayedValue = newValue
            }
        }
        .onAppear {
            // Draw-in on first appearance; live updates animate via onChange.
            guard surfaceActive,
                  let animation = GeraldineMotion.animation(.emphasis, reduceMotion: reduceMotion) else {
                revealed = true
                return
            }
            withAnimation(animation) { revealed = true }
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
    var valueTint: Color = .primary

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            GaugeRing(value: fraction, lineWidth: 8, tint: tint) {
                VStack(spacing: 1) {
                    if let valueAnimationValue {
                        AnimatedNumberText(value, value: valueAnimationValue)
                            .font(.rounded(22, .semibold))
                            .foregroundStyle(valueTint)
                    } else {
                        Text(value).font(.rounded(22, .semibold)).foregroundStyle(valueTint)
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
        .card(tier: .quiet)
    }
}

// MARK: - Linear stat bar

struct StatBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    @State private var displayedFraction: Double?
    @State private var lastAnimatedAt: TimeInterval = 0

    var fraction: Double
    var tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(0, min(1, displayedFraction ?? fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .onChange(of: fraction) { _, newValue in
            // Same live-metric cadence as GaugeRing: the width is a layout
            // attribute, so animating every sample forced continuous re-layout.
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAnimatedAt >= GeraldineMotion.liveMetricAnimationInterval,
               surfaceActive, !reduceMotion,
               let animation = GeraldineMotion.animation(.standard, reduceMotion: false) {
                lastAnimatedAt = now
                withAnimation(animation) { displayedFraction = newValue }
            } else {
                displayedFraction = newValue
            }
        }
    }
}

// MARK: - Icon badge

/// Soft, gradient-lit circular icon badge — the shared hero mark for empty,
/// idle, error, and done states, so they read as Geraldine rather than a stock
/// grey circle. Purely decorative.
struct IconBadge: View {
    var icon: String
    var tint: Color
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.22), tint.opacity(0.05)],
                                     center: UnitPoint(x: 0.38, y: 0.30),
                                     startRadius: size * 0.06, endRadius: size * 0.78))
            Circle()
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundStyle(tint.gradient)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Brand spinner

/// Geraldine's activity indicator: a rotating brand-tinted arc around a gently
/// breathing icon. Replaces the stock spinner on scanning states; only alive
/// while a scan screen is on-screen.
struct BrandSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.geraldineSurfaceActive) private var surfaceActive

    var tint: Color
    var icon: String = "sparkles"
    var size: CGFloat = 72

    @State private var spinning = false
    @State private var breathing = false

    private var lineWidth: CGFloat { max(4, size * 0.07) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.34)
                .stroke(AngularGradient(colors: [tint.opacity(0), tint],
                                        center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? GeraldineMotion.spinner(reduceMotion: reduceMotion) : nil,
                           value: spinning)
            Image(systemName: icon)
                .font(.system(size: size * 0.30, weight: .semibold))
                .foregroundStyle(tint.gradient)
                .scaleEffect(reduceMotion ? 1 : (breathing ? 1.04 : 0.94))
                .animation(breathing ? GeraldineMotion.breathing(reduceMotion: reduceMotion) : nil,
                           value: breathing)
        }
        .frame(width: size, height: size)
        .onAppear { updateActivity() }
        .onDisappear { spinning = false; breathing = false }
        .onChange(of: reduceMotion) { _, _ in updateActivity() }
        .onChange(of: surfaceActive) { _, _ in updateActivity() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private func updateActivity() {
        spinning = surfaceActive && !reduceMotion
        breathing = surfaceActive && !reduceMotion
    }
}

// MARK: - Buttons

/// The brand gradient capsule: white label, violet→blue fill, soft brand
/// shadow, and a slight press. One look for every primary call to action.
struct BrandProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentButtonBody(configuration: configuration)
    }
}

private struct ProminentButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.rounded(14, .semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: Theme.Layout.minimumHitArea)
            .foregroundStyle(.white)
            .background(Theme.brandGradient, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        isFocused && isEnabled
                            ? Theme.focusRing
                            : Color.white.opacity(isHovered ? 0.24 : 0.14),
                        lineWidth: isFocused && isEnabled ? 2 : 1
                    )
            }
            .shadow(
                color: Theme.accent.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.38 : 0.28)),
                radius: configuration.isPressed ? 3 : (isHovered ? 11 : 8),
                y: configuration.isPressed ? 1 : (isHovered ? 4 : 3)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .offset(y: isHovered && !configuration.isPressed && !reduceMotion ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.46)
            .contentShape(Capsule())
            .focusEffectDisabled()
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
            .pointingHandCursor()
    }
}

/// Quiet tinted capsule for secondary actions (Scan Again, Cancel Scan, …) so
/// they match the brand language instead of the stock bordered push button.
struct SoftCapsuleButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(configuration: configuration, tint: tint, compact: compact)
    }
}

private struct SoftButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    var compact = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.rounded(compact ? 11 : 13, .semibold))
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minWidth: Theme.Layout.minimumHitArea, minHeight: Theme.Layout.minimumHitArea)
            .foregroundStyle(isEnabled ? tint : Theme.disabledForeground(tint))
            .background(
                tint.opacity(configuration.isPressed ? 0.22 : (isHovered ? 0.16 : 0.10)),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(isFocused && isEnabled
                                  ? Theme.focusRing
                                  : tint.opacity(isHovered ? 0.30 : 0.20),
                                  lineWidth: isFocused && isEnabled ? 2 : 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .offset(y: isHovered && !configuration.isPressed && !reduceMotion ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.82)
            .contentShape(Capsule())
            .focusEffectDisabled()
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
            .pointingHandCursor()
    }
}

struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, tint: tint, compact: compact)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    var compact = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.rounded(13, .medium))
            .padding(.horizontal, 10)
            .frame(minWidth: Theme.Layout.minimumHitArea,
                   minHeight: compact ? Theme.Layout.compactHitArea : Theme.Layout.minimumHitArea)
            .foregroundStyle(
                isEnabled
                    ? (isHovered || isFocused ? tint : Color.secondary)
                    : Theme.disabledForeground(tint)
            )
            .background(
                isEnabled && (isHovered || isFocused) ? tint.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isFocused && isEnabled ? Theme.focusRing : Color.clear, lineWidth: 2)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.82)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .focusEffectDisabled()
            .onHover { isHovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { isHovered = false }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isHovered)
            .pointingHandCursor()
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SoftButtonBody(configuration: configuration, tint: Theme.bad)
    }
}

extension ButtonStyle where Self == SoftCapsuleButtonStyle {
    /// `.buttonStyle(.soft(tint))` — the quiet brand capsule in a module's tint.
    static func soft(_ tint: Color = Theme.accent, compact: Bool = false) -> SoftCapsuleButtonStyle {
        SoftCapsuleButtonStyle(tint: tint, compact: compact)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    /// `compact` caps the control at `compactHitArea` for fixed-height widget rows.
    static func quiet(_ tint: Color = Theme.accent, compact: Bool = false) -> QuietButtonStyle {
        QuietButtonStyle(tint: tint, compact: compact)
    }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var geraldineDestructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}

extension ButtonStyle where Self == ActionableCardButtonStyle {
    static func actionableCard(
        padding: CGFloat = 18,
        tier: CardTier = .raised,
        cornerRadius: CGFloat = Theme.Radius.card
    ) -> ActionableCardButtonStyle {
        ActionableCardButtonStyle(padding: padding,
                                  tier: tier,
                                  cornerRadius: cornerRadius)
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
                Text(title)
            }
        }
        .buttonStyle(BrandProminentButtonStyle())
    }
}

// MARK: - Section header

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            // Small-caps kicker: section labels frame content quietly instead of
            // competing with card titles for attention.
            Text(title)
                .font(.rounded(11.5, .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        VStack(spacing: Theme.Spacing.md) {
            IconBadge(icon: icon, tint: tint, size: 76)
            Text(title).font(.geraldineTitle)
            Text(message)
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
