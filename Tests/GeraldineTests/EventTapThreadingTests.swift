import CoreFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import Geraldine

final class EventTapThreadingTests: XCTestCase {
    func testOnlyListenOnlyTapsDeliverOnTheMainRunLoop() {
        XCTAssertFalse(EventTapService.deliversOnMainRunLoop(.defaultTap))
        XCTAssertTrue(EventTapService.deliversOnMainRunLoop(.listenOnly))
    }

    func testFilteringTapThreadRunsWhileTheCallerIsBlocked() {
        // The calling thread stays blocked inside `sync` until the tap thread
        // has run the block on its own run loop.
        var ranOnMainThread = true
        var ranOnMainRunLoop = true
        EventTapThread.shared.sync {
            ranOnMainThread = Thread.isMainThread
            ranOnMainRunLoop = CFRunLoopGetCurrent() === CFRunLoopGetMain()
        }

        XCTAssertFalse(ranOnMainThread)
        XCTAssertFalse(ranOnMainRunLoop)
        XCTAssertFalse(EventTapThread.shared.runLoop === CFRunLoopGetMain())
        XCTAssertEqual(EventTapThread.shared.qualityOfService, .userInteractive)
    }

    func testSyncRunsInOrderAndInlineFromTheTapThread() {
        var order: [Int] = []
        EventTapThread.shared.sync { order.append(1) }
        EventTapThread.shared.sync {
            order.append(2)
            EventTapThread.shared.sync { order.append(3) }
            order.append(4)
        }

        XCTAssertEqual(order, [1, 2, 3, 4])
    }

    func testStoppingATapThatNeverStartedIsHarmless() {
        let service = EventTapService(mask: CGEventMask(1 << CGEventType.leftMouseDown.rawValue)) { _, _ in
            false
        }

        service.stop()
        service.stop()
    }
}
