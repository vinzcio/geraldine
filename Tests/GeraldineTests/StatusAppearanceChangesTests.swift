import AppKit
import Combine
import XCTest
@testable import Geraldine

final class StatusAppearanceChangesTests: XCTestCase {
    func testRepeatedNoticesForTheCurrentAppearanceNeverRedraw() {
        let appearances = PassthroughSubject<NSAppearance, Never>()
        var redraws: [NSAppearance.Name] = []
        let subscription = StatusAppearanceChanges.distinct(appearances).sink { redraws.append($0) }
        let light = NSAppearance(named: .aqua)!

        appearances.send(light)
        for _ in 0..<100 {
            appearances.send(light)
        }

        XCTAssertEqual(redraws, [])
        subscription.cancel()
    }

    func testEachRealAppearanceChangeRedrawsOnce() {
        let appearances = PassthroughSubject<NSAppearance, Never>()
        var redraws: [NSAppearance.Name] = []
        let subscription = StatusAppearanceChanges.distinct(appearances).sink { redraws.append($0) }
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        appearances.send(light)
        appearances.send(dark)
        appearances.send(dark)
        appearances.send(light)
        appearances.send(light)

        XCTAssertEqual(redraws, [.darkAqua, .aqua])
        subscription.cancel()
    }
}
