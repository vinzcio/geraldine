import XCTest
@testable import Geraldine

final class MenuBarStatusAnimationPolicyTests: XCTestCase {
    func testUnchangedDisplayedNumberShimmers() {
        XCTAssertTrue(MenuBarStatusAnimationPolicy.shouldShimmer(
            sameKind: true,
            oldNumber: "65",
            newNumber: "65",
            hasAnimationValues: true
        ))
    }

    func testChangedDisplayedNumberDoesNotShimmer() {
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldShimmer(
            sameKind: true,
            oldNumber: "65",
            newNumber: "66",
            hasAnimationValues: true
        ))
    }

    func testNonNumericOrDifferentMetricDoesNotShimmer() {
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldShimmer(
            sameKind: true,
            oldNumber: "",
            newNumber: "",
            hasAnimationValues: false
        ))
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldShimmer(
            sameKind: false,
            oldNumber: "65",
            newNumber: "65",
            hasAnimationValues: true
        ))
    }

    func testSparklineOnlySampleDoesNotRetargetInFlightAnimation() {
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldRetargetInFlight(
            animationInFlight: true,
            sameKind: true,
            sameSource: true,
            oldNumber: "42",
            newNumber: "42"
        ))
    }

    func testDisplayedNumberChangeRetargetsInFlightAnimation() {
        XCTAssertTrue(MenuBarStatusAnimationPolicy.shouldRetargetInFlight(
            animationInFlight: true,
            sameKind: true,
            sameSource: true,
            oldNumber: "42",
            newNumber: "43"
        ))
    }

    func testIdleStatusItemDoesNotRetarget() {
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldRetargetInFlight(
            animationInFlight: false,
            sameKind: false,
            sameSource: false,
            oldNumber: "1",
            newNumber: "2"
        ))
    }

    func testDigitRollIsRateLimited() {
        XCTAssertFalse(MenuBarStatusAnimationPolicy.shouldStartAnimation(
            elapsedSinceLast: 0.2, minimumInterval: 0.8
        ))
        XCTAssertTrue(MenuBarStatusAnimationPolicy.shouldStartAnimation(
            elapsedSinceLast: 0.8, minimumInterval: 0.8
        ))
    }
}
