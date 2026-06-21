import SwiftUI

enum Theme {
    // Brand
    static let accent  = Color(red: 0.46, green: 0.40, blue: 0.95)   // violet
    static let accent2 = Color(red: 0.36, green: 0.66, blue: 0.98)   // blue

    // Status
    static let good = Color(red: 0.24, green: 0.79, blue: 0.55)
    static let warn = Color(red: 0.98, green: 0.71, blue: 0.27)
    static let bad  = Color(red: 0.96, green: 0.39, blue: 0.42)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [accent2, accent],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Green → amber → red based on a 0…1 "usage" value.
    static func status(for usage: Double) -> Color {
        switch usage {
        case ..<0.6:  return good
        case ..<0.85: return warn
        default:      return bad
        }
    }

    static let corner: CGFloat = 16
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
