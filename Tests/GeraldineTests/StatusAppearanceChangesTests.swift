import AppKit
import Combine
import XCTest
@testable import Geraldine

final class StatusAppearanceChangesTests: XCTestCase {
    private func appearance(_ name: NSAppearance.Name) -> NSAppearance {
        NSAppearance(named: name)!
    }

    private func redraws(for names: [NSAppearance.Name]) -> [NSAppearance.Name?] {
        let appearances = PassthroughSubject<NSAppearance, Never>()
        var redraws: [NSAppearance.Name?] = []
        let subscription = StatusAppearanceChanges.distinct(appearances).sink { redraws.append($0) }
        for name in names {
            appearances.send(appearance(name))
        }
        subscription.cancel()
        return redraws
    }

    func testDarkModeNoticesAfterEachImageNeverRedraw() {
        // macOS 27.2 sends this alternation eight times after every status image.
        let notices = [NSAppearance.Name.darkAqua] +
            Array(repeating: [NSAppearance.Name.darkAqua, .vibrantDark], count: 100).flatMap { $0 }

        XCTAssertEqual(redraws(for: notices), [])
    }

    func testLightModeVariantsNeverRedraw() {
        let notices = [NSAppearance.Name.aqua] +
            Array(repeating: [NSAppearance.Name.vibrantLight, .aqua], count: 100).flatMap { $0 }

        XCTAssertEqual(redraws(for: notices), [])
    }

    func testEachSwitchBetweenLightAndDarkRedrawsOnce() {
        XCTAssertEqual(
            redraws(for: [.aqua, .vibrantDark, .darkAqua, .vibrantLight, .aqua, .darkAqua]),
            [.darkAqua, .aqua, .darkAqua]
        )
    }

    func testDrawingAppearanceIsThemeAdaptivesLightOrDarkChoice() {
        XCTAssertEqual(StatusAppearanceChanges.drawingAppearance(appearance(.aqua)), .aqua)
        XCTAssertEqual(StatusAppearanceChanges.drawingAppearance(appearance(.vibrantLight)), .aqua)
        XCTAssertEqual(StatusAppearanceChanges.drawingAppearance(appearance(.darkAqua)), .darkAqua)
        XCTAssertEqual(StatusAppearanceChanges.drawingAppearance(appearance(.vibrantDark)), .darkAqua)
        XCTAssertEqual(
            StatusAppearanceChanges.drawingAppearance(appearance(.accessibilityHighContrastVibrantDark)),
            .darkAqua
        )
    }
}
