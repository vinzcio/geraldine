import AppKit
import Testing
@testable import Geraldine

struct MenuBarPanelPlacementTests {
    @Test func panelPinsToTopRightWithInset() {
        let visibleFrame = NSRect(x: 40, y: 80, width: 1440, height: 900)
        let frame = MenuBarPanelPlacement.frame(in: visibleFrame, contentHeight: 620)

        #expect(frame.width == MenuBarPanelPlacement.preferredWidth)
        #expect(frame.height == 620)
        #expect(frame.maxX == visibleFrame.maxX - MenuBarPanelPlacement.edgeInset)
        #expect(frame.maxY == visibleFrame.maxY - MenuBarPanelPlacement.edgeInset)
    }

    @Test func panelClampsToSmallVisibleFrame() {
        let visibleFrame = NSRect(x: -900, y: 30, width: 500, height: 420)
        let frame = MenuBarPanelPlacement.frame(in: visibleFrame, contentHeight: 900)

        #expect(frame.minX == visibleFrame.minX + MenuBarPanelPlacement.edgeInset)
        #expect(frame.minY == visibleFrame.minY + MenuBarPanelPlacement.edgeInset)
        #expect(frame.maxX == visibleFrame.maxX - MenuBarPanelPlacement.edgeInset)
        #expect(frame.maxY == visibleFrame.maxY - MenuBarPanelPlacement.edgeInset)
    }
}
