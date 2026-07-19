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

    func testOverlappingCandidatesDeclineInsteadOfChoosingSmallerBackgroundWindow() {
        let point = CGPoint(x: 300, y: 250)
        let frontWindow = MissionControlWindowCandidate(
            processIdentifier: 101,
            windowID: 10,
            windowSize: CGSize(width: 800, height: 600),
            screenToWindow: CGAffineTransform(translationX: -100, y: -100)
        )
        let backgroundWindow = MissionControlWindowCandidate(
            processIdentifier: 202,
            windowID: 20,
            windowSize: CGSize(width: 300, height: 200),
            screenToWindow: CGAffineTransform(translationX: -200, y: -150)
        )

        XCTAssertNil(MissionControlWindowTargeting.candidate(
            at: point,
            in: [frontWindow, backgroundWindow]
        ))
    }

    func testSecondaryDisplayUsesGlobalPointAndWindowServerOrder() {
        let primaryWindow = MissionControlWindowCandidate(
            processIdentifier: 101,
            windowID: 10,
            windowSize: CGSize(width: 800, height: 600),
            screenToWindow: CGAffineTransform(translationX: 0, y: -100)
        )
        let secondaryWindow = MissionControlWindowCandidate(
            processIdentifier: 202,
            windowID: 20,
            windowSize: CGSize(width: 800, height: 600),
            screenToWindow: CGAffineTransform(translationX: 1_200, y: -100)
        )

        let target = MissionControlWindowTargeting.candidate(
            at: CGPoint(x: -1_000, y: 200),
            in: [primaryWindow, secondaryWindow]
        )

        XCTAssertEqual(target?.windowID, secondaryWindow.windowID)
    }
}
