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
}
