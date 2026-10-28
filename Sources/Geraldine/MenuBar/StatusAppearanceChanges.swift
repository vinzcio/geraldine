import AppKit
import Combine

/// AppKit re-sends `effectiveAppearance` for an appearance that has not changed.
/// Only a different appearance may invalidate the status image: invalidating on
/// every notice redrew the icon nonstop on macOS 27.2, where each redraw drew
/// another notice, and held the main thread near 100%.
enum StatusAppearanceChanges {
    /// Appearance names after the current one, without repeats.
    static func distinct<Appearances: Publisher>(
        _ appearances: Appearances
    ) -> AnyPublisher<NSAppearance.Name, Never>
    where Appearances.Output == NSAppearance, Appearances.Failure == Never {
        appearances
            .map(\.name)
            .removeDuplicates()
            .dropFirst()
            .eraseToAnyPublisher()
    }
}
