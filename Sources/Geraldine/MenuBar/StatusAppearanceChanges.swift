import AppKit
import Combine

/// On macOS 27.2, setting a status bar button's image re-sends
/// `effectiveAppearance` eight times, alternating DarkAqua and VibrantDark in
/// Dark Mode. Invalidating the status image on each notice redrew it nonstop and
/// held the main thread near 100% from launch. The image only depends on the
/// light or dark choice `Theme.adaptive` makes, so only a change in that choice
/// invalidates it.
enum StatusAppearanceChanges {
    /// The light or dark appearance the status image is drawn for, chosen the
    /// way `Theme.adaptive` chooses it.
    static func drawingAppearance(_ appearance: NSAppearance) -> NSAppearance.Name? {
        appearance.bestMatch(from: [.aqua, .darkAqua])
    }

    /// Drawing appearances after the current one, without repeats.
    static func distinct<Appearances: Publisher>(
        _ appearances: Appearances
    ) -> AnyPublisher<NSAppearance.Name?, Never>
    where Appearances.Output == NSAppearance, Appearances.Failure == Never {
        appearances
            .map(drawingAppearance)
            .removeDuplicates()
            .dropFirst()
            .eraseToAnyPublisher()
    }
}
