import SwiftUI

/// Geraldine's mark: a living instrument aperture drawn as a restrained G.
/// It remains legible from the menu bar popover to the About panel and avoids
/// the generic gradient-square-plus-sparkle treatment.
struct GeraldineMark: View {
    var size: CGFloat = 40
    var tint: Color = Theme.accent
    var showsPlate = true

    var body: some View {
        ZStack {
            if showsPlate {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent2, tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .strokeBorder(.white.opacity(0.18), lineWidth: max(0.7, size * 0.025))
                    }
                    .shadow(color: tint.opacity(0.24), radius: size * 0.18, y: size * 0.08)
            }

            GeraldineApertureShape()
                .stroke(
                    showsPlate ? Color.white : tint,
                    style: StrokeStyle(
                        lineWidth: max(1.5, size * 0.075),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size * 0.54, height: size * 0.54)

            Circle()
                .fill(showsPlate ? Color.white : Theme.accent2)
                .frame(width: size * 0.095, height: size * 0.095)
                .offset(x: size * 0.20, y: -size * 0.20)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct GeraldineApertureShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.42

        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(38),
            endAngle: .degrees(334),
            clockwise: false
        )
        path.move(to: CGPoint(x: rect.midX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.91, y: rect.midY))
        return path
    }
}

struct GeraldineSelectionButtonStyle: ButtonStyle {
    let tint: Color
    let isSelected: Bool
    var cornerRadius: CGFloat = Theme.Radius.control
    var showsSelectionRail = true

    func makeBody(configuration: Configuration) -> some View {
        GeraldineSelectionButtonBody(configuration: configuration,
                                     tint: tint,
                                     isSelected: isSelected,
                                     cornerRadius: cornerRadius,
                                     showsSelectionRail: showsSelectionRail)
    }
}

private struct GeraldineSelectionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color
    let isSelected: Bool
    let cornerRadius: CGFloat
    let showsSelectionRail: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .background {
                shape.fill(backgroundFill)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: 3)
                            .padding(.vertical, 7)
                            .opacity(isSelected && showsSelectionRail ? 1 : 0)
                    }
            }
            .overlay {
                shape.strokeBorder(isFocused && isEnabled ? Theme.focusRing : .clear,
                                   lineWidth: isFocused && isEnabled ? 2 : 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? GeraldineMotion.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.46)
            .contentShape(shape)
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

    private var backgroundFill: Color {
        if configuration.isPressed { return Theme.decorativeFill(tint, strength: .strong) }
        if isSelected { return Theme.decorativeFill(tint) }
        if isHovered || isFocused { return Theme.decorativeFill(tint, strength: .subtle) }
        return .clear
    }
}

extension ButtonStyle where Self == GeraldineSelectionButtonStyle {
    static func geraldineSelection(
        _ tint: Color,
        isSelected: Bool,
        cornerRadius: CGFloat = Theme.Radius.control,
        showsSelectionRail: Bool = true
    ) -> GeraldineSelectionButtonStyle {
        GeraldineSelectionButtonStyle(tint: tint,
                                      isSelected: isSelected,
                                      cornerRadius: cornerRadius,
                                      showsSelectionRail: showsSelectionRail)
    }
}

/// A consistent module-specific glyph plate. Module color is wayfinding, while
/// the silhouette, depth, and radius remain Geraldine's everywhere.
struct ModuleGlyph: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.decorativeFill(tint, strength: .strong),
                                 Theme.decorativeFill(tint, strength: .subtle)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Letter plate for items without a resolvable app icon: the first character
/// of the display name on the standard glyph plate, so ad-hoc helpers and
/// daemons still get an identity instead of a generic symbol.
struct MonogramPlate: View {
    let text: String
    let tint: Color
    var size: CGFloat = 36

    private var monogram: String {
        text.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.decorativeFill(tint, strength: .strong),
                                 Theme.decorativeFill(tint, strength: .subtle)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                }
            Text(monogram)
                .font(.rounded(size * 0.44, .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Neutral plate for third-party app and browser icons. The outline is pure
/// black in light mode and pure white in dark mode so it never looks tinted or dirty.
struct AppIconPlate<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    var size: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.08), radius: 4, y: 2)
    }
}

/// Shared selected/focused/pressed grammar for row-like controls.
struct SelectionPlate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSelected: Bool
    let tint: Color
    var cornerRadius: CGFloat = Theme.Radius.control
    var showsAccentRail = true

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isSelected ? Theme.decorativeFill(tint) : Color.clear)
                    .overlay(alignment: .leading) {
                        if showsAccentRail {
                            Capsule()
                                .fill(tint)
                                .frame(width: 3)
                                .padding(.vertical, 7)
                                .opacity(isSelected ? 1 : 0)
                        }
                    }
            }
            .animation(GeraldineMotion.animation(.quick, reduceMotion: reduceMotion), value: isSelected)
    }
}

extension View {
    func selectionPlate(
        isSelected: Bool,
        tint: Color,
        cornerRadius: CGFloat = Theme.Radius.control,
        showsAccentRail: Bool = true
    ) -> some View {
        modifier(SelectionPlate(
            isSelected: isSelected,
            tint: tint,
            cornerRadius: cornerRadius,
            showsAccentRail: showsAccentRail
        ))
    }

    /// Keeps the visible control compact while guaranteeing an accessible target.
    func minimumHitArea(_ size: CGFloat = Theme.Layout.minimumHitArea) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}
