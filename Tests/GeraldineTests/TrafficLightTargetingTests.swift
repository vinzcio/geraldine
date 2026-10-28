import CoreGraphics
import Foundation
import XCTest
@testable import Geraldine

final class TrafficLightTargetingTests: XCTestCase {
    private func window(pid: pid_t, bounds: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha)
        ]
    }

    func testFrontmostStandardWindowOwnsThePoint() {
        let front = CGRect(x: 100, y: 100, width: 800, height: 600)
        let back = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windows = [window(pid: 10, bounds: front), window(pid: 20, bounds: back)]

        XCTAssertEqual(
            WindowServerHitTest.frontmostWindow(at: CGPoint(x: 130, y: 115), in: windows),
            WindowServerHitTest.Window(processIdentifier: 10, bounds: front)
        )
        XCTAssertEqual(
            WindowServerHitTest.frontmostWindow(at: CGPoint(x: 50, y: 50), in: windows)?.processIdentifier,
            20
        )
        XCTAssertNil(WindowServerHitTest.frontmostWindow(at: CGPoint(x: 2000, y: 50), in: windows))
    }

    func testMenusAndPanelsOnTopHideTheWindowBeneath() {
        let menu = CGRect(x: 90, y: 90, width: 200, height: 300)
        let standard = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertNil(WindowServerHitTest.frontmostWindow(
            at: CGPoint(x: 130, y: 115),
            in: [window(pid: 30, bounds: menu, layer: 101), window(pid: 10, bounds: standard)]
        ))
    }

    func testFullyTransparentWindowsDoNotTakeThePoint() {
        let overlay = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let standard = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertEqual(
            WindowServerHitTest.frontmostWindow(
                at: CGPoint(x: 130, y: 115),
                in: [window(pid: 40, bounds: overlay, layer: 25, alpha: 0), window(pid: 10, bounds: standard)]
            )?.processIdentifier,
            10
        )
    }

    func testOnlyTitleBarCornersCanHoldWindowButtons() {
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)

        XCTAssertTrue(TrafficLightRegion.contains(CGPoint(x: 130, y: 115), windowBounds: bounds))
        XCTAssertTrue(TrafficLightRegion.contains(CGPoint(x: 880, y: 115), windowBounds: bounds))
        XCTAssertFalse(TrafficLightRegion.contains(CGPoint(x: 500, y: 115), windowBounds: bounds))
        XCTAssertFalse(TrafficLightRegion.contains(CGPoint(x: 130, y: 400), windowBounds: bounds))
        XCTAssertFalse(TrafficLightRegion.contains(CGPoint(x: 50, y: 115), windowBounds: bounds))
    }
}
