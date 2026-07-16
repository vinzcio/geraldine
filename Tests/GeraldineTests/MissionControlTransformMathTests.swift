import CoreGraphics
import XCTest
@testable import Geraldine

final class MissionControlTransformMathTests: XCTestCase {
    func testNormalWindowTransformMapsScreenPointIntoLocalBounds() {
        let screenToWindow = CGAffineTransform(translationX: -100, y: -200)

        XCTAssertTrue(MissionControlTransformMath.contains(
            screenPoint: CGPoint(x: 150, y: 250),
            windowSize: CGSize(width: 300, height: 200),
            screenToWindow: screenToWindow
        ))
        XCTAssertFalse(MissionControlTransformMath.contains(
            screenPoint: CGPoint(x: 50, y: 250),
            windowSize: CGSize(width: 300, height: 200),
            screenToWindow: screenToWindow
        ))
    }

    func testMissionControlScaleMapsThumbnailPointIntoOriginalWindow() {
        let screenToWindow = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -800, ty: -400)

        XCTAssertTrue(MissionControlTransformMath.contains(
            screenPoint: CGPoint(x: 500, y: 300),
            windowSize: CGSize(width: 400, height: 400),
            screenToWindow: screenToWindow
        ))
        XCTAssertFalse(MissionControlTransformMath.contains(
            screenPoint: CGPoint(x: 650, y: 300),
            windowSize: CGSize(width: 400, height: 400),
            screenToWindow: screenToWindow
        ))
    }

    func testTransformedAreaAccountsForMissionControlScale() {
        XCTAssertEqual(
            MissionControlTransformMath.transformedArea(
                windowSize: CGSize(width: 800, height: 600),
                screenToWindow: CGAffineTransform(scaleX: 2, y: 2)
            ),
            120_000,
            accuracy: 0.001
        )
    }
}
