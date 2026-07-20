import CoreGraphics
import XCTest
@testable import Geraldine

final class FinderTrashShortcutTests: XCTestCase {
    func testBackspaceWithoutModifiersMatchesFinderTrashShortcut() {
        XCTAssertTrue(
            KeyboardPowerToolsService.isFinderTrashShortcut(keyCode: 51, flags: [])
        )
        XCTAssertFalse(
            KeyboardPowerToolsService.isFinderTrashShortcut(keyCode: 51, flags: .maskCommand)
        )
        XCTAssertFalse(
            KeyboardPowerToolsService.isFinderTrashShortcut(keyCode: 117, flags: [])
        )
    }

    func testNoSelectionReturnsWarning() {
        let result = FinderPowerToolsService.moveToTrash([])

        XCTAssertEqual(result.status, .warning)
        XCTAssertEqual(result.message, "No Finder selection.")
    }

    func testSuccessfulTrashMoveReportsSelectionCount() {
        let urls = [
            URL(fileURLWithPath: "/work/one"),
            URL(fileURLWithPath: "/work/two")
        ]

        let result = FinderPowerToolsService.moveToTrash(urls) { items in
            XCTAssertEqual(items.map(\.url), urls)
            return TrashService.Result(
                removed: 2,
                trashed: 2,
                permanentlyDeleted: 0,
                freed: 0,
                failures: []
            )
        }

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.message, "Moved 2 items to Trash.")
    }

    func testPartialTrashMoveReturnsWarning() {
        let urls = [
            URL(fileURLWithPath: "/work/one"),
            URL(fileURLWithPath: "/work/two")
        ]

        let result = FinderPowerToolsService.moveToTrash(urls) { _ in
            TrashService.Result(
                removed: 1,
                trashed: 1,
                permanentlyDeleted: 0,
                freed: 0,
                failures: [
                    TrashService.Failure(url: urls[1], message: "Injected failure")
                ]
            )
        }

        XCTAssertEqual(result.status, .warning)
        XCTAssertEqual(result.message, "Moved 1 of 2 items to Trash.")
    }
}
