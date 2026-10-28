import CoreGraphics
import XCTest
@testable import Geraldine

final class DockClickIntentTests: XCTestCase {
    private func intent(
        _ type: CGEventType,
        button: Int64 = 0,
        flags: CGEventFlags = [],
        middle: DockMiddleClickBehavior = .system,
        shiftNewWindow: Bool = false,
        active: DockActiveClickBehavior = .system
    ) -> DockClickIntent? {
        DockClickIntent.intent(
            type: type,
            buttonNumber: button,
            flags: flags,
            middleClickBehavior: middle,
            shiftClickNewWindow: shiftNewWindow,
            activeClickBehavior: active
        )
    }

    func testSystemBehaviorsLeaveEveryClickAlone() {
        XCTAssertNil(intent(.leftMouseDown))
        XCTAssertNil(intent(.leftMouseDown, flags: .maskShift))
        XCTAssertNil(intent(.otherMouseDown, button: 2))
    }

    func testMiddleClickNeedsTheMiddleButtonAndACustomBehavior() {
        XCTAssertEqual(intent(.otherMouseDown, button: 2, middle: .quitApp), .middleClick(.quitApp))
        XCTAssertNil(intent(.otherMouseDown, button: 3, middle: .quitApp))
        XCTAssertNil(intent(.leftMouseDown, middle: .quitApp))
    }

    func testShiftClickNewWindowWinsOverTheActiveClickBehavior() {
        XCTAssertEqual(
            intent(.leftMouseDown, flags: .maskShift, shiftNewWindow: true, active: .hideApp),
            .shiftClickNewWindow
        )
        XCTAssertEqual(intent(.leftMouseDown, flags: .maskShift, active: .hideApp), .activeClick(.hideApp))
        XCTAssertEqual(intent(.leftMouseDown, active: .cycleWindows), .activeClick(.cycleWindows))
    }

    func testOtherEventsNeverMatch() {
        XCTAssertNil(intent(.rightMouseDown, active: .hideApp))
        XCTAssertNil(intent(.leftMouseUp, active: .hideApp))
        XCTAssertNil(intent(.keyDown, shiftNewWindow: true, active: .hideApp))
    }
}

final class DockEdgeBandTests: XCTestCase {
    // Quartz coordinates: y grows downward from the top of the main display.
    private let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondary = CGRect(x: 1920, y: -200, width: 1440, height: 900)

    func testBottomBandCoversOnlyTheDockStrip() {
        let band = DockEdgeBand(edge: .bottom, depth: 104)

        XCTAssertTrue(band.contains(CGPoint(x: 960, y: 1079), displayBounds: main))
        XCTAssertTrue(band.contains(CGPoint(x: 5, y: 977), displayBounds: main))
        XCTAssertFalse(band.contains(CGPoint(x: 960, y: 975), displayBounds: main))
        XCTAssertFalse(band.contains(CGPoint(x: 960, y: 20), displayBounds: main))
    }

    func testBandFollowsTheDisplayUnderTheClick() {
        let band = DockEdgeBand(edge: .bottom, depth: 104)

        XCTAssertTrue(band.contains(CGPoint(x: 2600, y: 690), displayBounds: secondary))
        XCTAssertFalse(band.contains(CGPoint(x: 2600, y: 500), displayBounds: secondary))
        XCTAssertFalse(band.contains(CGPoint(x: 960, y: 1079), displayBounds: secondary))
    }

    func testSideOrientations() {
        let left = DockEdgeBand(edge: .left, depth: 104)
        XCTAssertTrue(left.contains(CGPoint(x: 40, y: 500), displayBounds: main))
        XCTAssertFalse(left.contains(CGPoint(x: 140, y: 500), displayBounds: main))

        let right = DockEdgeBand(edge: .right, depth: 104)
        XCTAssertTrue(right.contains(CGPoint(x: 1880, y: 500), displayBounds: main))
        XCTAssertFalse(right.contains(CGPoint(x: 1780, y: 500), displayBounds: main))
    }

    func testDepthFollowsTheDockPreferences() {
        XCTAssertEqual(
            DockEdgeBand(orientation: nil, tileSize: nil, magnifies: false, magnifiedSize: nil),
            DockEdgeBand(edge: .bottom, depth: 64 + 40)
        )
        XCTAssertEqual(
            DockEdgeBand(orientation: "left", tileSize: 48, magnifies: false, magnifiedSize: 128),
            DockEdgeBand(edge: .left, depth: 48 + 40)
        )
        XCTAssertEqual(
            DockEdgeBand(orientation: "right", tileSize: 48, magnifies: true, magnifiedSize: 110),
            DockEdgeBand(edge: .right, depth: 110 + 40)
        )
        XCTAssertEqual(
            DockEdgeBand(orientation: "bottom", tileSize: 48, magnifies: true, magnifiedSize: nil),
            DockEdgeBand(edge: .bottom, depth: 128 + 40)
        )
    }

    func testUnusablePreferencesFallBackToSafeValues() {
        XCTAssertEqual(
            DockEdgeBand(orientation: "top", tileSize: -5, magnifies: false, magnifiedSize: nil),
            DockEdgeBand(edge: .bottom, depth: 64 + 40)
        )
        XCTAssertEqual(
            DockEdgeBand(orientation: "bottom", tileSize: 9_000, magnifies: false, magnifiedSize: nil),
            DockEdgeBand(edge: .bottom, depth: 256 + 40)
        )
    }
}
