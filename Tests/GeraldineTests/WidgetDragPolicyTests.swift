import XCTest
@testable import Geraldine

/// Pure-geometry coverage for the drag subsystem: grid packing, reorder decisions
/// (including the hysteresis fixed points), and the autoscroll ramp.
@MainActor
final class WidgetDragPolicyTests: XCTestCase {
    // Width 600 → four 144pt tracks with 8pt gutters.
    private let wideWidth: CGFloat = 600

    private func slot(_ slots: [WidgetGridMetrics.Slot], _ id: String) -> CGRect? {
        slots.first { $0.id == id }?.frame
    }

    // MARK: Packing

    func testWidePackingRowsAndSpans() {
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.memory, .small),
            WidgetItem(.network, .medium),
            WidgetItem(.keepAwake, .large)
        ]
        let slots = WidgetReorderPolicy.settledSlots(items: items,
                                                     heights: ["keepAwake": 240],
                                                     width: wideWidth)

        XCTAssertEqual(slot(slots, "cpu"), CGRect(x: 0, y: 0, width: 144, height: 132))
        XCTAssertEqual(slot(slots, "memory"), CGRect(x: 152, y: 0, width: 144, height: 132))
        XCTAssertEqual(slot(slots, "network"), CGRect(x: 304, y: 0, width: 296, height: 132))
        // Full-width tiles take their natural height on their own row.
        XCTAssertEqual(slot(slots, "keepAwake"), CGRect(x: 0, y: 140, width: 600, height: 240))
        XCTAssertEqual(WidgetGridMetrics.height(of: slots), 380)
    }

    func testCompactPackingFallsBackToTwoColumns() {
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.memory, .small),
            WidgetItem(.network, .medium)
        ]
        let slots = WidgetReorderPolicy.settledSlots(items: items, heights: [:], width: 400)

        XCTAssertEqual(slot(slots, "cpu"), CGRect(x: 0, y: 0, width: 196, height: 132))
        XCTAssertEqual(slot(slots, "memory"), CGRect(x: 204, y: 0, width: 196, height: 132))
        // Medium spans the full compact row.
        XCTAssertEqual(slot(slots, "network"), CGRect(x: 0, y: 140, width: 400, height: 132))
    }

    func testPartialRowFlushesBeforeFullWidthTile() {
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.keepAwake, .large),
            WidgetItem(.memory, .small)
        ]
        let slots = WidgetReorderPolicy.settledSlots(items: items,
                                                     heights: ["keepAwake": 240],
                                                     width: wideWidth)

        XCTAssertEqual(slot(slots, "cpu"), CGRect(x: 0, y: 0, width: 144, height: 132))
        XCTAssertEqual(slot(slots, "keepAwake"), CGRect(x: 0, y: 140, width: 600, height: 240))
        XCTAssertEqual(slot(slots, "memory"), CGRect(x: 0, y: 388, width: 144, height: 132))
    }

    // MARK: Reorder decisions

    private var standardItems: [WidgetItem] {
        [
            WidgetItem(.cpu, .small),
            WidgetItem(.memory, .small),
            WidgetItem(.network, .medium),
            WidgetItem(.keepAwake, .large)
        ]
    }

    private func decide(_ center: CGPoint, dragged: String,
                        items: [WidgetItem]? = nil) -> WidgetReorderPolicy.Decision {
        WidgetReorderPolicy.decision(center: center,
                                     draggedID: dragged,
                                     items: items ?? standardItems,
                                     heights: ["keepAwake": 240],
                                     width: wideWidth)
    }

    func testSwapIntoNeighborSlotConverges() {
        XCTAssertEqual(decide(CGPoint(x: 220, y: 66), dragged: "cpu"),
                       .move(targetID: "memory"))
    }

    func testNonConvergingHoverDoesNotReorder() {
        // Hovering the left edge of the medium network tile would land the small cpu
        // tile at x 456–600 — the cursor wouldn't rest inside it, so no move yet.
        XCTAssertEqual(decide(CGPoint(x: 320, y: 66), dragged: "cpu"), .none)
        // Deeper into the same tile, the swap becomes a fixed point and commits.
        XCTAssertEqual(decide(CGPoint(x: 500, y: 66), dragged: "cpu"),
                       .move(targetID: "network"))
    }

    func testHoveringOwnSlotIsStable() {
        XCTAssertEqual(decide(CGPoint(x: 70, y: 66), dragged: "cpu"), .none)
    }

    func testBelowGridMovesToEnd() {
        XCTAssertEqual(decide(CGPoint(x: 300, y: 420), dragged: "cpu"), .moveToEnd)
    }

    func testAboveGridMovesToFront() {
        XCTAssertEqual(decide(CGPoint(x: 300, y: -20), dragged: "network"),
                       .move(targetID: "cpu"))
        // Already first: stays put even above the grid.
        XCTAssertEqual(decide(CGPoint(x: 300, y: -20), dragged: "cpu"), .none)
    }

    func testHorizontalOverflowClampsIntoTheGrid() {
        // Far right of the grid, level with the first row: clamps to x = width and
        // lands after the row (network is the row's last tile, dragged from later).
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.keepAwake, .large),
            WidgetItem(.memory, .small)
        ]
        XCTAssertEqual(decide(CGPoint(x: 900, y: 66), dragged: "memory", items: items),
                       .move(targetID: "keepAwake"))
    }

    func testTrailingGapDropFromLaterLandsAfterRow() {
        // Row 1 is [cpu | gap]; memory (later in order) dropped deep into the gap
        // should slot in right after cpu — i.e. take keepAwake's spot from later.
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.keepAwake, .large),
            WidgetItem(.memory, .small)
        ]
        XCTAssertEqual(decide(CGPoint(x: 400, y: 66), dragged: "memory", items: items),
                       .move(targetID: "keepAwake"))
    }

    func testTrailingGapDropFromEarlierLandsAfterRowLast() {
        // Row 1 is [cpu, memory | gap]; cpu dropped into the gap lands after memory.
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.memory, .small),
            WidgetItem(.keepAwake, .large)
        ]
        XCTAssertEqual(decide(CGPoint(x: 400, y: 66), dragged: "cpu", items: items),
                       .move(targetID: "memory"))
    }

    func testGapDropIsAFixedPoint() {
        // After the gap drop commits, re-running the decision at the same cursor
        // position must be quiet — this is the anti-ping-pong guarantee.
        let items = [
            WidgetItem(.cpu, .small),
            WidgetItem(.keepAwake, .large),
            WidgetItem(.memory, .small)
        ]
        let after = WidgetReorderPolicy.moved(items, draggedID: "memory", toIndexOf: "keepAwake")
        XCTAssertEqual(after.map(\.kind.id), ["cpu", "memory", "keepAwake"])
        XCTAssertEqual(decide(CGPoint(x: 400, y: 66), dragged: "memory", items: after), .none)
    }

    // MARK: Autoscroll

    func testAutoScrollIsQuietAwayFromEdges() {
        let visible = CGRect(x: 0, y: 100, width: 600, height: 400)
        let tile = CGRect(x: 0, y: 250, width: 144, height: 132)
        XCTAssertEqual(WidgetAutoScrollPolicy.velocity(tileRect: tile, visible: visible), 0)
    }

    func testAutoScrollRampsTowardTheTop() {
        let visible = CGRect(x: 0, y: 100, width: 600, height: 400)
        let shallow = WidgetAutoScrollPolicy.velocity(
            tileRect: CGRect(x: 0, y: 120, width: 144, height: 132), visible: visible)
        let deep = WidgetAutoScrollPolicy.velocity(
            tileRect: CGRect(x: 0, y: 100, width: 144, height: 132), visible: visible)
        XCTAssertLessThan(shallow, 0)
        XCTAssertLessThan(deep, shallow)
        XCTAssertEqual(deep, -WidgetAutoScrollPolicy.maxSpeed)
    }

    func testAutoScrollRampsTowardTheBottom() {
        let visible = CGRect(x: 0, y: 100, width: 600, height: 400)
        let velocity = WidgetAutoScrollPolicy.velocity(
            tileRect: CGRect(x: 0, y: 380, width: 144, height: 132), visible: visible)
        XCTAssertGreaterThan(velocity, 0)
    }

    func testAutoScrollDeadZoneIgnoresGrazing() {
        let visible = CGRect(x: 0, y: 100, width: 600, height: 400)
        // Tile top pokes 2pt into the band — inside the dead zone.
        let tile = CGRect(x: 0, y: 142, width: 144, height: 132)
        XCTAssertEqual(WidgetAutoScrollPolicy.velocity(tileRect: tile, visible: visible), 0)
    }
}

/// Store-level behavior the drag controller relies on: staged moves stay uncommitted
/// until a drop, and Escape's revert restores the committed order.
@MainActor
final class WidgetLayoutStoreDragTests: XCTestCase {
    private func makeStore() throws -> (WidgetLayoutStore, UserDefaults, String) {
        let suiteName = "WidgetLayoutStoreDragTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (WidgetLayoutStore(defaults: defaults), defaults, suiteName)
    }

    func testRevertStagedChangesRestoresCommittedOrder() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = store.items.map(\.kind)

        store.stageMove(.metric(.cpu), toIndexOf: .metric(.temperature))
        XCTAssertNotEqual(store.items.map(\.kind), original)
        // Staging must not leak into the committed order the status item reads.
        XCTAssertEqual(store.menuBarKind(hasBattery: true), .temperature)

        store.revertStagedChanges()
        XCTAssertEqual(store.items.map(\.kind), original)
    }

    func testPersistNowCommitsStagedOrderAndRevertBecomesNoOp() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.stageMove(.metric(.cpu), toIndexOf: .metric(.temperature))
        let staged = store.items.map(\.kind)
        store.persistNow()
        XCTAssertEqual(store.menuBarKind(hasBattery: true), .cpu)

        store.revertStagedChanges()
        XCTAssertEqual(store.items.map(\.kind), staged)

        // A fresh store sees the committed order.
        let reloaded = WidgetLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.kind), staged)
    }

    func testSetSizeAppliesOnlyToResizableKinds() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.setSize(.metric(.cpu), .large)
        XCTAssertEqual(store.items.first { $0.kind == .metric(.cpu) }?.size, .large)

        store.setSize(.calendar, .small)
        XCTAssertEqual(store.items.first { $0.kind == .calendar }?.size, .large,
                       "The calendar is pinned to full width")
    }

    func testMoveToFrontDrivesTheMenuBar() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.moveToFront(.metric(.network))
        XCTAssertEqual(store.items.first?.kind, .metric(.network))
        XCTAssertEqual(store.menuBarKind(hasBattery: true), .network)
    }
}
