import XCTest
@testable import Geraldine

final class StatusAnimationFramePolicyTests: XCTestCase {
    func testFirstFrameRendersImmediately() {
        var policy = StatusAnimationFramePolicy()
        XCTAssertTrue(policy.shouldRender(at: 10, isFinal: false))
    }

    func testFramesAreCappedAtThirtyHertz() {
        var policy = StatusAnimationFramePolicy()
        XCTAssertTrue(policy.shouldRender(at: 10.000, isFinal: false))
        XCTAssertFalse(policy.shouldRender(at: 10.010, isFinal: false))
        XCTAssertFalse(policy.shouldRender(at: 10.032, isFinal: false))
        XCTAssertTrue(policy.shouldRender(at: 10.034, isFinal: false))
    }

    func testFinalFrameAlwaysRenders() {
        var policy = StatusAnimationFramePolicy()
        XCTAssertTrue(policy.shouldRender(at: 10, isFinal: false))
        XCTAssertTrue(policy.shouldRender(at: 10.001, isFinal: true))
    }

    func testResetAllowsTheNextAnimationToStartImmediately() {
        var policy = StatusAnimationFramePolicy()
        XCTAssertTrue(policy.shouldRender(at: 10, isFinal: false))
        XCTAssertFalse(policy.shouldRender(at: 10.001, isFinal: false))
        policy.reset()
        XCTAssertTrue(policy.shouldRender(at: 10.001, isFinal: false))
    }

    func testNonFiniteTimeDoesNotDropAFrame() {
        var policy = StatusAnimationFramePolicy()
        XCTAssertTrue(policy.shouldRender(at: .nan, isFinal: false))
    }

    func testSignaturesIgnoreNothingThatPaints() {
        let base = StatusRenderSignature(
            kind: "cpu",
            label: "42%",
            widthSample: "100%",
            colorToken: "0.1,0.2,0.3,1.0",
            samples: [.init(timestamp: 1, value: 0.4)]
        )
        XCTAssertEqual(base, StatusRenderSignature(
            kind: "cpu",
            label: "42%",
            widthSample: "100%",
            colorToken: "0.1,0.2,0.3,1.0",
            samples: [.init(timestamp: 1, value: 0.4)]
        ))

        var changedLabel = base
        changedLabel.label = "43%"
        XCTAssertNotEqual(base, changedLabel)

        var changedColor = base
        changedColor.colorToken = "0.9,0.1,0.1,1.0"
        XCTAssertNotEqual(base, changedColor)

        var changedSparkline = base
        changedSparkline.samples.append(.init(timestamp: 2, value: 0.5))
        XCTAssertNotEqual(base, changedSparkline)

        var changedDevice = base
        changedDevice.sourceID = 7
        XCTAssertNotEqual(base, changedDevice)
    }
}
