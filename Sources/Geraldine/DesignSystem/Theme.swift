import AppKit
import SwiftUI

/// Geraldine's semantic visual vocabulary.
///
/// Views should reach for these roles instead of inventing local opacity,
/// spacing, radius, or shadow values. The palette is intentionally restrained:
/// violet-blue is the identity, module colors are wayfinding, and surfaces stay
/// graphite/pearl so live data remains the loudest thing on screen.
enum Theme {
    // MARK: Brand

    static let accent = adaptive(
        "GeraldineAccent",
        light: ns(0.39, 0.32, 0.90),
        dark: ns(0.55, 0.49, 1.00)
    )
    static let accent2 = adaptive(
        "GeraldineAccentBlue",
        light: ns(0.08, 0.38, 0.76),
        dark: ns(0.38, 0.68, 1.00)
    )

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent2, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Semantic foregrounds and surfaces

    static let canvas = adaptive(
        "GeraldineCanvas",
        light: ns(0.965, 0.970, 0.985),
        dark: ns(0.045, 0.052, 0.072)
    )
    static let sidebar = adaptive(
        "GeraldineSidebar",
        light: ns(0.935, 0.942, 0.970),
        dark: ns(0.060, 0.068, 0.092)
    )
    static let surfaceBase = adaptive(
        "GeraldineSurfaceBase",
        light: ns(0.988, 0.990, 0.998),
        dark: ns(0.075, 0.084, 0.112)
    )
    static let surfaceRaised = adaptive(
        "GeraldineSurfaceRaised",
        light: ns(1.000, 1.000, 1.000),
        dark: ns(0.095, 0.106, 0.140)
    )
    static let surfaceFloating = adaptive(
        "GeraldineSurfaceFloating",
        light: ns(1.000, 1.000, 1.000),
        dark: ns(0.120, 0.132, 0.170)
    )
    static let surfaceMuted = adaptive(
        "GeraldineSurfaceMuted",
        light: ns(0.920, 0.930, 0.955),
        dark: ns(0.105, 0.116, 0.148)
    )
    static let separator = adaptive(
        "GeraldineSeparator",
        light: ns(0.08, 0.10, 0.16, 0.10),
        dark: ns(1.00, 1.00, 1.00, 0.10)
    )
    static let focusRing = adaptive(
        "GeraldineFocusRing",
        light: ns(0.34, 0.27, 0.88, 0.82),
        dark: ns(0.62, 0.57, 1.00, 0.92)
    )

    // MARK: Status and module palette

    static let good = adaptive(
        "GeraldineGood",
        light: ns(0.02, 0.43, 0.27),
        dark: ns(0.28, 0.84, 0.58)
    )
    static let warn = adaptive(
        "GeraldineWarn",
        light: ns(0.60, 0.31, 0.00),
        dark: ns(1.00, 0.72, 0.28)
    )
    static let bad = adaptive(
        "GeraldineBad",
        light: ns(0.68, 0.10, 0.18),
        dark: ns(1.00, 0.40, 0.45)
    )

    static let aqua = adaptive("GeraldineAqua", light: ns(0.00, 0.42, 0.43), dark: ns(0.30, 0.82, 0.82))
    static let mint = adaptive("GeraldineMint", light: ns(0.00, 0.43, 0.33), dark: ns(0.28, 0.82, 0.65))
    static let green = adaptive("GeraldineGreen", light: ns(0.06, 0.43, 0.20), dark: ns(0.34, 0.82, 0.48))
    static let orange = adaptive("GeraldineOrange", light: ns(0.66, 0.29, 0.00), dark: ns(1.00, 0.61, 0.28))
    static let rose = adaptive("GeraldineRose", light: ns(0.66, 0.14, 0.27), dark: ns(1.00, 0.48, 0.57))
    static let plum = adaptive("GeraldinePlum", light: ns(0.54, 0.15, 0.58), dark: ns(0.89, 0.48, 0.91))
    static let indigo = adaptive("GeraldineIndigo", light: ns(0.23, 0.29, 0.70), dark: ns(0.50, 0.59, 1.00))
    static let slate = adaptive("GeraldineSlate", light: ns(0.36, 0.39, 0.48), dark: ns(0.68, 0.71, 0.80))
    static let silver = adaptive("GeraldineSilver", light: ns(0.58, 0.61, 0.68), dark: ns(0.46, 0.49, 0.57))

    /// Luminous visualization colors kept separate from semantic foregrounds.
    /// Thin strokes and small data points need more saturation than body text.
    enum Chart {
        static let blue = adaptive("GeraldineChartBlue", light: ns(0.00, 0.48, 0.96), dark: ns(0.38, 0.72, 1.00))
        static let purple = adaptive("GeraldineChartPurple", light: ns(0.52, 0.34, 0.96), dark: ns(0.70, 0.58, 1.00))
        static let green = adaptive("GeraldineChartGreen", light: ns(0.05, 0.66, 0.36), dark: ns(0.32, 0.88, 0.58))
        static let amber = adaptive("GeraldineChartAmber", light: ns(0.96, 0.56, 0.04), dark: ns(1.00, 0.76, 0.34))
        static let red = adaptive("GeraldineChartRed", light: ns(0.92, 0.22, 0.28), dark: ns(1.00, 0.45, 0.50))
        static let orange = adaptive("GeraldineChartOrange", light: ns(1.00, 0.39, 0.10), dark: ns(1.00, 0.64, 0.32))
        static let mint = adaptive("GeraldineChartMint", light: ns(0.00, 0.64, 0.48), dark: ns(0.32, 0.88, 0.70))
        static let plum = adaptive("GeraldineChartPlum", light: ns(0.73, 0.28, 0.78), dark: ns(0.93, 0.53, 0.95))
        static let silver = adaptive("GeraldineChartSilver", light: ns(0.62, 0.66, 0.74), dark: ns(0.72, 0.76, 0.84))

        static func status(for usage: Double) -> Color {
            switch usage {
            case ..<0.6: green
            case ..<0.85: amber
            default: red
            }
        }

        static func health(for score: Int) -> Color {
            switch score {
            case 85...: green
            case 60..<85: amber
            default: red
            }
        }

        static func batteryLevel(_ level: Double?) -> Color {
            (level ?? 1) < 0.2 ? red : green
        }

        static func batteryHealth(_ health: Double?) -> Color {
            guard let health else { return green }
            if health >= 0.8 { return green }
            return health >= 0.6 ? amber : red
        }
    }

    enum DecorativeStrength {
        case subtle
        case standard
        case strong

        var opacity: Double {
            switch self {
            case .subtle: 0.07
            case .standard: 0.12
            case .strong: 0.20
            }
        }
    }

    /// Semantic role split: strong adaptive hues stay readable as foregrounds;
    /// washes and disabled treatments are explicitly decorative roles.
    static func decorativeFill(_ foreground: Color,
                               strength: DecorativeStrength = .standard) -> Color {
        foreground.opacity(strength.opacity)
    }

    static func disabledForeground(_ foreground: Color) -> Color {
        foreground.opacity(0.46)
    }

    /// Green → amber → red based on a 0…1 usage value.
    static func status(for usage: Double) -> Color {
        switch usage {
        case ..<0.6: good
        case ..<0.85: warn
        default: bad
        }
    }

    // MARK: Layout tokens

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let hero: CGFloat = 40
    }

    enum Radius {
        static let badge: CGFloat = 8
        static let control: CGFloat = 11
        static let card: CGFloat = 18
        static let raised: CGFloat = 22
        static let hero: CGFloat = 28
        static let pill: CGFloat = 999
    }

    enum Layout {
        static let pagePadding: CGFloat = 28
        static let pageSpacing: CGFloat = 24
        static let contentMaxWidth: CGFloat = 1180
        static let readingMaxWidth: CGFloat = 760
        static let minimumHitArea: CGFloat = 40
        static let sidebarMinWidth: CGFloat = 224
        static let sidebarIdealWidth: CGFloat = 248
        static let sidebarMaxWidth: CGFloat = 292
    }

    enum Shadow {
        static let baseRadius: CGFloat = 4
        static let raisedRadius: CGFloat = 9
        static let floatingRadius: CGFloat = 16
        static let baseY: CGFloat = 1
        static let raisedY: CGFloat = 3
        static let floatingY: CGFloat = 6
        static let lightBaseOpacity = 0.05
        static let lightRaisedOpacity = 0.09
        static let lightFloatingOpacity = 0.14
        static let darkBaseOpacity = 0.14
        static let darkRaisedOpacity = 0.24
        static let darkFloatingOpacity = 0.34
    }

    /// Kept for compatibility while existing call sites migrate to the radius scale.
    static let corner = Radius.card

    // MARK: Private adaptive-color construction

    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func ns(_ red: CGFloat,
                           _ green: CGFloat,
                           _ blue: CGFloat,
                           _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let geraldineHero = Font.rounded(30, .bold)
    static let geraldineTitle = Font.rounded(22, .bold)
    static let geraldineSection = Font.rounded(16, .semibold)
    static let geraldineMetric = Font.rounded(26, .semibold).monospacedDigit()
    static let geraldineBody = Font.system(size: 14, weight: .regular, design: .default)
    static let geraldineLabel = Font.rounded(12, .semibold)
}
