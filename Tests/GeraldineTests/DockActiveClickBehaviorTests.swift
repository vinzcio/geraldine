import XCTest
@testable import Geraldine

final class DockActiveClickInterceptionPolicyTests: XCTestCase {
    func testSystemBehaviorNeverIntercepts() {
        XCTAssertFalse(DockActiveClickInterceptionPolicy.shouldIntercept(
            behavior: .system,
            targetIsFrontmost: true,
            hasVisibleWindow: { true }
        ))
    }

    func testCustomBehaviorInterceptsVisibleFrontmostWindow() {
        for behavior in [
            DockActiveClickBehavior.hideApp,
            .minimizeWindows,
            .cycleWindows
        ] {
            XCTAssertTrue(DockActiveClickInterceptionPolicy.shouldIntercept(
                behavior: behavior,
                targetIsFrontmost: true,
                hasVisibleWindow: { true }
            ))
        }
    }

    func testCustomBehaviorPassesWindowlessFrontmostAppToDock() {
        for behavior in [
            DockActiveClickBehavior.hideApp,
            .minimizeWindows,
            .cycleWindows
        ] {
            XCTAssertFalse(DockActiveClickInterceptionPolicy.shouldIntercept(
                behavior: behavior,
                targetIsFrontmost: true,
                hasVisibleWindow: { false }
            ))
        }
    }

    func testCustomBehaviorPassesInactiveAppToDockWithoutReadingVisibility() {
        var visibilityWasRead = false

        XCTAssertFalse(DockActiveClickInterceptionPolicy.shouldIntercept(
            behavior: .cycleWindows,
            targetIsFrontmost: false,
            hasVisibleWindow: {
                visibilityWasRead = true
                return true
            }
        ))
        XCTAssertFalse(visibilityWasRead)
    }

    func testPassThroughSkipsVisibilityLookup() {
        var visibilityWasRead = false

        XCTAssertFalse(DockActiveClickInterceptionPolicy.shouldIntercept(
            behavior: .system,
            targetIsFrontmost: true,
            hasVisibleWindow: {
                visibilityWasRead = true
                return true
            }
        ))
        XCTAssertFalse(visibilityWasRead)
    }
}
