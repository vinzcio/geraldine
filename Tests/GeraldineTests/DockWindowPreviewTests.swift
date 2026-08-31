import AppKit
import ApplicationServices
import SwiftUI
import XCTest
@testable import Geraldine

private func previewWindow(title: String = "Document", frame: CGRect? = nil,
                           minimized: Bool = false) -> DockPreviewWindow {
    // A retained AX reference is sufficient for these boundary tests. No test
    // sends it an action or manipulates an actual application window.
    DockPreviewWindow(element: AXUIElementCreateApplication(getpid()), title: title,
                      frame: frame, isMinimized: minimized)
}

final class DockPreviewApplicationMatchingTests: XCTestCase {
    private let firstURL = URL(fileURLWithPath: "/Applications/Editor.app")
    private let secondURL = URL(fileURLWithPath: "/Applications/Other/Editor.app")

    func testDockURLDisambiguatesIdenticallyNamedApplications() {
        let apps = [
            DockPreviewApplicationCandidate(processIdentifier: 10, bundleURL: firstURL, name: "Editor"),
            DockPreviewApplicationCandidate(processIdentifier: 20, bundleURL: secondURL, name: "Editor")
        ]
        XCTAssertEqual(DockPreviewApplicationMatching.processIdentifier(
            itemURL: secondURL, title: "Editor", candidates: apps
        ), 20)
        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(itemURL: nil, title: "Editor", candidates: apps))
    }

    func testNonrunningURLNeverFallsBackToAnotherAppsLabel() {
        let apps = [DockPreviewApplicationCandidate(processIdentifier: 10, bundleURL: firstURL, name: "Editor")]
        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(itemURL: secondURL, title: "Editor", candidates: apps))
    }

    func testUniqueLabelIsUsableWhenDockDoesNotExposeURL() {
        let apps = [DockPreviewApplicationCandidate(processIdentifier: 10, bundleURL: firstURL, name: "Editor")]
        XCTAssertEqual(DockPreviewApplicationMatching.processIdentifier(itemURL: nil, title: " Editor ", candidates: apps), 10)
        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(itemURL: nil, title: "", candidates: apps))
    }
}

final class DockPreviewCaptureMatchingTests: XCTestCase {
    private let firstFrame = CGRect(x: 50, y: 60, width: 700, height: 500)
    private let secondFrame = CGRect(x: 300, y: 200, width: 900, height: 600)

    private func candidate(_ id: CGWindowID, title: String = "Document", frame: CGRect,
                           pid: pid_t = 10) -> DockPreviewCaptureCandidate {
        DockPreviewCaptureCandidate(windowID: id, processIdentifier: pid, title: title, frame: frame)
    }

    func testDuplicateTitlesUseTheirOwnWindowGeometry() {
        let first = previewWindow(frame: firstFrame)
        let second = previewWindow(frame: secondFrame)
        let candidates = [candidate(1, frame: firstFrame), candidate(2, frame: secondFrame)]
        XCTAssertEqual(DockPreviewCaptureMatching.windowID(for: second, processIdentifier: 10,
                                                           windows: [first, second], candidates: candidates), 2)
    }

    func testNeverUsesAnImageFromAnotherProcess() {
        let window = previewWindow(frame: firstFrame)
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: window, processIdentifier: 10, windows: [window],
                                                         candidates: [candidate(1, frame: firstFrame, pid: 20)]))
    }

    func testAmbiguousCaptureWindowsRemainTitleOnly() {
        let window = previewWindow(frame: firstFrame)
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: window, processIdentifier: 10, windows: [window],
                                                         candidates: [candidate(1, frame: firstFrame), candidate(2, frame: firstFrame)]))
    }

    func testAmbiguousAXWindowsDoNotReuseOneImage() {
        let first = previewWindow(frame: firstFrame)
        let second = previewWindow(frame: firstFrame)
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: second, processIdentifier: 10, windows: [first, second],
                                                         candidates: [candidate(1, frame: firstFrame)]))
    }

    func testMinimizedWindowCanMatchUniqueTitleWithStaleBounds() {
        let window = previewWindow(frame: firstFrame, minimized: true)
        XCTAssertEqual(DockPreviewCaptureMatching.windowID(for: window, processIdentifier: 10, windows: [window],
                                                           candidates: [candidate(1, frame: secondFrame)]), 1)
    }

    func testDuplicateTitlesWithUnknownBoundsDoNotGuess() {
        let windows = [previewWindow(), previewWindow()]
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: windows[1], processIdentifier: 10, windows: windows,
                                                         candidates: [candidate(1, frame: firstFrame)]))
    }

    func testUntitledWindowNeedsUniqueGeometry() {
        let window = previewWindow(title: "", frame: firstFrame)
        XCTAssertEqual(DockPreviewCaptureMatching.windowID(for: window, processIdentifier: 10, windows: [window],
                                                           candidates: [candidate(1, title: "", frame: firstFrame)]), 1)
        let unknown = previewWindow(title: "")
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: unknown, processIdentifier: 10, windows: [unknown],
                                                         candidates: [candidate(1, title: "", frame: firstFrame)]))
    }

    func testMatchingBoundsDoNotOverrideConflictingTitles() {
        let window = previewWindow(frame: firstFrame)
        XCTAssertNil(DockPreviewCaptureMatching.windowID(for: window, processIdentifier: 10, windows: [window],
                                                         candidates: [candidate(1, title: "Other", frame: firstFrame)]))
    }

    func testWindowServerIdentityWinsWithoutGeometryGuessing() {
        let window = DockPreviewWindow(windowID: 42, processIdentifier: 10, title: "Document",
                                       frame: firstFrame, isMinimized: false)
        let candidates = [candidate(41, frame: firstFrame), candidate(42, title: "Other", frame: secondFrame)]
        XCTAssertEqual(DockPreviewCaptureMatching.windowID(
            for: window, processIdentifier: 10, windows: [window], candidates: candidates
        ), 42)
    }

    func testResolvingWindowServerFallbackPreservesItsExactIdentity() {
        let window = DockPreviewWindow(windowID: 42, processIdentifier: getpid(), title: "Document",
                                       frame: firstFrame, isMinimized: false)
        let element = AXUIElementCreateApplication(getpid())
        let resolved = window.resolving(element: element)
        XCTAssertEqual(resolved.id, window.id)
        XCTAssertEqual(resolved.windowID, 42)
        XCTAssertTrue(CFEqual(resolved.element, element))
    }
}

final class DockPreviewWindowSnapshotMatchingTests: XCTestCase {
    func testExactWindowSnapshotsRemainEquivalentWhenAXReordersThem() {
        let first = DockPreviewWindow(windowID: 41, processIdentifier: 10, title: "First",
                                      frame: CGRect(x: 10, y: 20, width: 700, height: 500), isMinimized: false)
        let second = DockPreviewWindow(windowID: 42, processIdentifier: 10, title: "Second",
                                       frame: CGRect(x: 30, y: 40, width: 800, height: 600), isMinimized: true)
        XCTAssertTrue(DockPreviewWindowSnapshotMatching.equivalent([first, second], [second, first]))
    }

    func testChangedExactWindowIdentityRequiresAnInPlaceRefresh() {
        let cached = DockPreviewWindow(windowID: 41, processIdentifier: 10, title: "Document",
                                       frame: CGRect(x: 10, y: 20, width: 700, height: 500), isMinimized: false)
        let live = DockPreviewWindow(windowID: 42, processIdentifier: 10, title: "Document",
                                     frame: cached.frame, isMinimized: false)
        XCTAssertFalse(DockPreviewWindowSnapshotMatching.equivalent([cached], [live]))
    }

    func testChangedStateOfTheSameWindowRequiresAnInPlaceRefresh() {
        let cached = DockPreviewWindow(windowID: 41, processIdentifier: 10, title: "Document",
                                       frame: CGRect(x: 10, y: 20, width: 700, height: 500), isMinimized: false)
        let live = DockPreviewWindow(windowID: 41, processIdentifier: 10, title: "Document",
                                     frame: cached.frame, isMinimized: true)
        XCTAssertFalse(DockPreviewWindowSnapshotMatching.equivalent([cached], [live]))
    }
}

final class DockPreviewHoverMatchingTests: XCTestCase {
    private let item = CGRect(x: 600, y: 800, width: 64, height: 64)

    func testMovementWithinTheSameIconDoesNotRestartTheHover() {
        XCTAssertTrue(DockPreviewHoverMatching.accepts(queriedPoint: CGPoint(x: 610, y: 820),
                                                      currentPoint: CGPoint(x: 650, y: 840), targetFrame: item))
    }

    func testMovingToAnotherIconRejectsTheOldResult() {
        XCTAssertFalse(DockPreviewHoverMatching.accepts(queriedPoint: CGPoint(x: 610, y: 820),
                                                       currentPoint: CGPoint(x: 690, y: 820), targetFrame: item))
    }

    func testAnEmptyHitOnlyAppliesIfThePointerHasNotMoved() {
        let point = CGPoint(x: 610, y: 820)
        XCTAssertTrue(DockPreviewHoverMatching.accepts(queriedPoint: point, currentPoint: point, targetFrame: nil))
        XCTAssertFalse(DockPreviewHoverMatching.accepts(queriedPoint: point, currentPoint: .zero, targetFrame: nil))
    }

    func testSecondaryClickBlocksHoverWhileTheDockMenuIsActive() {
        var suppression = DockPreviewContextMenuSuppression()
        suppression.begin()
        XCTAssertTrue(suppression.isActive)
        XCTAssertFalse(suppression.allowsHover(afterCheckingDockMenu: true))
        XCTAssertTrue(suppression.isActive)
    }

    func testHoverResumesOnlyAfterTheDockMenuIsGone() {
        var suppression = DockPreviewContextMenuSuppression()
        suppression.begin()
        XCTAssertTrue(suppression.allowsHover(afterCheckingDockMenu: false))
        XCTAssertFalse(suppression.isActive)
        XCTAssertTrue(suppression.allowsHover(afterCheckingDockMenu: true))
    }

    func testStoppingThePreviewServiceClearsSecondaryClickSuppression() {
        var suppression = DockPreviewContextMenuSuppression()
        suppression.begin()
        suppression.reset()
        XCTAssertFalse(suppression.isActive)
    }
}

final class DockPreviewSelectionMatchingTests: XCTestCase {
    func testSelectionHitPointsStayInsideTheExactWindowBounds() {
        let frame = CGRect(x: -400, y: 30, width: 1200, height: 800)
        let points = DockPreviewSelectionMatching.hitTestPoints(in: frame)
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.first, CGPoint(x: 200, y: 430))
        XCTAssertTrue(points.allSatisfy(frame.contains))
    }

    func testInvalidWindowGeometryNeverProducesSelectionGuesses() {
        XCTAssertTrue(DockPreviewSelectionMatching.hitTestPoints(in: .zero).isEmpty)
        XCTAssertTrue(DockPreviewSelectionMatching.hitTestPoints(
            in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)
        ).isEmpty)
    }
}

final class DockPreviewLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let twoWindows = [previewWindow(), previewWindow()]

    func testCompactTrayFitsOnlyThumbnailsAndTheirSpacing() {
        let item = CGRect(x: 680, y: 10, width: 64, height: 64)
        let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: .bottom, visibleFrame: screen, windows: twoWindows)
        XCTAssertEqual(frame.width, 408)
        XCTAssertEqual(frame.height, 126)
    }

    func testSingleWindowHasNoOuterPaddingOrLetterboxing() {
        let window = previewWindow(frame: CGRect(x: 0, y: 0, width: 1600, height: 600))
        let size = DockPreviewLayout.cardSize(for: window)
        let frame = DockPreviewLayout.panelFrame(itemFrame: CGRect(x: 680, y: 10, width: 64, height: 64),
                                                edge: .bottom, visibleFrame: screen, windows: [window])
        XCTAssertEqual(size, CGSize(width: 200, height: 75))
        XCTAssertEqual(frame.size, size)
    }

    func testMixedWindowShapesKeepTheirWholeImageInsideTheExistingThumbnailBounds() {
        let wide = previewWindow(frame: CGRect(x: 0, y: 0, width: 1600, height: 600))
        let tall = previewWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        XCTAssertEqual(DockPreviewLayout.cardSize(for: wide), CGSize(width: 200, height: 75))
        XCTAssertEqual(DockPreviewLayout.cardSize(for: tall), CGSize(width: 63, height: 126))
        XCTAssertEqual(DockPreviewLayout.contentSize(windows: [wide, tall]), CGSize(width: 271, height: 126))
    }

    func testInitialCaptureBatchIncludesOnlyWindowsIntersectingTheViewport() {
        let windows = (0..<4).map { _ in previewWindow() }
        XCTAssertEqual(DockPreviewLayout.initiallyVisibleWindowIDs(windows: windows, viewportWidth: 208), [windows[0].id])
        XCTAssertEqual(DockPreviewLayout.initiallyVisibleWindowIDs(windows: windows, viewportWidth: 209),
                       [windows[0].id, windows[1].id])
        XCTAssertTrue(DockPreviewLayout.initiallyVisibleWindowIDs(windows: windows, viewportWidth: 0).isEmpty)
    }

    func testInitialCaptureBatchUsesActualWindowWidthsWithoutACountLimit() {
        let windows = (0..<20).map { _ in previewWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600)) }
        XCTAssertEqual(DockPreviewLayout.initiallyVisibleWindowIDs(windows: windows, viewportWidth: 100),
                       [windows[0].id, windows[1].id])
        XCTAssertEqual(DockPreviewLayout.initiallyVisibleWindowIDs(windows: windows, viewportWidth: 2000).count, 20)
    }

    func testMissingOrInvalidWindowGeometryUsesTheExistingThumbnailSize() {
        for geometry in [nil, CGRect.zero, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 600)] {
            XCTAssertEqual(DockPreviewLayout.cardSize(for: previewWindow(frame: geometry)), DockPreviewLayout.thumbnailSize)
        }
    }

    func testBottomDockPreviewSitsAboveItsItem() {
        let item = CGRect(x: 680, y: 10, width: 64, height: 64)
        let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: .bottom, visibleFrame: screen, windows: twoWindows)
        XCTAssertGreaterThan(frame.minY, item.maxY)
        XCTAssertEqual(frame.midX, item.midX)
        XCTAssertTrue(screen.contains(frame))
    }

    func testSideDockPreviewsSitInward() {
        let left = CGRect(x: 10, y: 400, width: 64, height: 64)
        let right = CGRect(x: 1366, y: 400, width: 64, height: 64)
        let leftFrame = DockPreviewLayout.panelFrame(itemFrame: left, edge: .left, visibleFrame: screen, windows: twoWindows)
        let rightFrame = DockPreviewLayout.panelFrame(itemFrame: right, edge: .right, visibleFrame: screen, windows: twoWindows)
        XCTAssertGreaterThan(leftFrame.minX, left.maxX)
        XCTAssertLessThan(rightFrame.maxX, right.minX)
        XCTAssertTrue(screen.contains(leftFrame))
        XCTAssertTrue(screen.contains(rightFrame))
    }

    func testDockEdgeIsInferredFromItemGeometry() {
        XCTAssertEqual(DockPreviewLayout.edge(for: CGRect(x: 680, y: 0, width: 64, height: 64), in: screen), .bottom)
        XCTAssertEqual(DockPreviewLayout.edge(for: CGRect(x: 0, y: 400, width: 64, height: 64), in: screen), .left)
        XCTAssertEqual(DockPreviewLayout.edge(for: CGRect(x: 1376, y: 400, width: 64, height: 64), in: screen), .right)
    }

    func testManyWindowsUseScrollableViewportWithoutLeavingScreen() {
        let item = CGRect(x: 680, y: 10, width: 64, height: 64)
        let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: .bottom, visibleFrame: screen,
                                                windows: (0..<100).map { _ in previewWindow() })
        XCTAssertEqual(frame.width, screen.width - DockPreviewLayout.screenMargin * 2)
        XCTAssertTrue(screen.contains(frame))
    }

    func testSecondaryScreenKeepsItsNegativeOrigin() {
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let item = CGRect(x: -600, y: -180, width: 64, height: 64)
        let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: .bottom, visibleFrame: secondary,
                                                windows: (0..<8).map { _ in previewWindow() })
        XCTAssertTrue(secondary.contains(frame))
        XCTAssertLessThan(frame.maxX, 0)
    }

    func testQuartzConversionUsesPrimaryScreenNotHoveredScreensHeight() {
        let quartz = CGRect(x: -1200, y: -300, width: 64, height: 64)
        let appKit = DockPreviewLayout.appKitFrame(fromQuartz: quartz, primaryScreenMaxY: 900)
        XCTAssertEqual(appKit, CGRect(x: -1200, y: 1136, width: 64, height: 64))
        XCTAssertEqual(DockPreviewLayout.quartzPoint(fromAppKit: CGPoint(x: -1200, y: 1200), primaryScreenMaxY: 900),
                       quartz.origin)
    }

    func testQuartzPointConversionUsesPrimaryScreenHeight() {
        XCTAssertEqual(
            DockPreviewLayout.appKitPoint(fromQuartz: CGPoint(x: -1200, y: -300), primaryScreenMaxY: 900),
            CGPoint(x: -1200, y: 1200)
        )
    }

    func testPointerCanCrossGapWithoutKeepingNeighboringDockIconsOpen() {
        let item = CGRect(x: 680, y: 10, width: 64, height: 64)
        let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: .bottom, visibleFrame: screen, windows: twoWindows)
        XCTAssertTrue(DockPreviewLayout.keepsPreviewOpen(at: CGPoint(x: item.midX, y: 78), itemFrame: item,
                                                        panelFrame: frame, edge: .bottom))
        XCTAssertTrue(DockPreviewLayout.keepsPreviewOpen(at: CGPoint(x: frame.minX + 10, y: frame.midY), itemFrame: item,
                                                        panelFrame: frame, edge: .bottom))
        XCTAssertFalse(DockPreviewLayout.keepsPreviewOpen(at: CGPoint(x: item.maxX + 20, y: item.midY), itemFrame: item,
                                                         panelFrame: frame, edge: .bottom))
        XCTAssertFalse(DockPreviewLayout.keepsPreviewOpen(at: CGPoint(x: 100, y: 700), itemFrame: item,
                                                         panelFrame: frame, edge: .bottom))
    }

    func testPointerCanCrossEitherSideDockGap() {
        for edge in [DockPreviewEdge.left, .right] {
            let item = CGRect(x: edge == .left ? 10 : 1366, y: 400, width: 64, height: 64)
            let frame = DockPreviewLayout.panelFrame(itemFrame: item, edge: edge, visibleFrame: screen, windows: twoWindows)
            let x = edge == .left ? (item.maxX + frame.minX) / 2 : (frame.maxX + item.minX) / 2
            XCTAssertTrue(DockPreviewLayout.keepsPreviewOpen(at: CGPoint(x: x, y: item.midY), itemFrame: item,
                                                            panelFrame: frame, edge: edge))
        }
    }

    func testMovementAcrossDockItemsStaysInTheTransitionBand() {
        let bottomItem = CGRect(x: 680, y: 10, width: 64, height: 64)
        XCTAssertTrue(DockPreviewLayout.isInDockItemBand(
            CGPoint(x: 1100, y: bottomItem.midY), itemFrame: bottomItem, edge: .bottom
        ))
        XCTAssertFalse(DockPreviewLayout.isInDockItemBand(
            CGPoint(x: 1100, y: 400), itemFrame: bottomItem, edge: .bottom
        ))

        let sideItem = CGRect(x: 10, y: 400, width: 64, height: 64)
        XCTAssertTrue(DockPreviewLayout.isInDockItemBand(
            CGPoint(x: sideItem.midX, y: 700), itemFrame: sideItem, edge: .left
        ))
        XCTAssertFalse(DockPreviewLayout.isInDockItemBand(
            CGPoint(x: 400, y: 700), itemFrame: sideItem, edge: .left
        ))
    }
}

final class DockPreviewActivationSelectionTests: XCTestCase {
    func testSelectedWindowIsRestoredOnceAfterItsAppActivates() {
        var selection = DockPreviewActivationSelection()
        let window = previewWindow(minimized: true)
        selection.prepare(window, processIdentifier: 10)
        XCTAssertEqual(selection.take(afterActivating: 10)?.id, window.id)
        XCTAssertNil(selection.take(afterActivating: 10))
    }

    func testSwitchingToAnotherAppCancelsPendingSelection() {
        var selection = DockPreviewActivationSelection()
        selection.prepare(previewWindow(), processIdentifier: 10)
        XCTAssertNil(selection.take(afterActivating: 20))
        XCTAssertNil(selection.take(afterActivating: 10))
    }

    func testLatestExplicitSelectionWins() {
        var selection = DockPreviewActivationSelection()
        let first = previewWindow()
        let second = previewWindow()
        selection.prepare(first, processIdentifier: 10)
        selection.prepare(second, processIdentifier: 10)
        XCTAssertEqual(selection.take(afterActivating: 10)?.id, second.id)
    }
}

@MainActor
final class DockWindowPreviewSessionTests: XCTestCase {
    private func session(windows: [DockPreviewWindow], allowed: Bool = false) -> DockWindowPreviewSession {
        DockWindowPreviewSession(appName: "Editor", appIcon: nil, processIdentifier: getpid(),
                                 windows: windows, screenRecordingAllowed: allowed)
    }

    func testSelectionUsesExactIdentityEvenWithDuplicateTitles() {
        let windows = [previewWindow(), previewWindow(minimized: true)]
        let session = session(windows: windows)
        var selected: UUID?
        XCTAssertTrue(session.select(windows[1].id) { selected = $0.id; return true })
        XCTAssertEqual(selected, windows[1].id)
        XCTAssertNil(session.selectionError)
    }

    func testUnknownSelectionDoesNotActivateAnything() {
        let session = session(windows: [previewWindow()])
        var activated = false
        XCTAssertFalse(session.select(UUID()) { _ in activated = true; return true })
        XCTAssertFalse(activated)
    }

    func testFailedSelectionReportsUnavailableWindowAndSuccessClearsIt() {
        let window = previewWindow()
        let session = session(windows: [window])
        XCTAssertFalse(session.select(window.id) { _ in false })
        XCTAssertNotNil(session.selectionError)
        XCTAssertTrue(session.select(window.id) { _ in true })
        XCTAssertNil(session.selectionError)
    }

    func testMissingScreenPermissionStillKeepsEveryWindowSelectable() {
        let windows = (0..<100).map { previewWindow(title: "Window \($0)") }
        let session = session(windows: windows)
        XCTAssertEqual(session.windows.count, 100)
        for window in windows {
            guard case .unavailable = session.thumbnails[window.id] else { XCTFail("Unexpected thumbnail work"); return }
        }
        XCTAssertTrue(session.select(windows[99].id) { $0.id == windows[99].id })
    }

    func testOnlyPendingThumbnailsDisableWindowInteraction() {
        XCTAssertTrue(DockPreviewThumbnail.loading.isLoading)
        XCTAssertFalse(DockPreviewThumbnail.loading.hasImage)
        XCTAssertFalse(DockPreviewThumbnail.unavailable.isLoading)
        XCTAssertFalse(DockPreviewThumbnail.unavailable.hasImage)
        let thumbnail = DockPreviewThumbnail.image(NSImage(size: CGSize(width: 200, height: 126)))
        XCTAssertFalse(thumbnail.isLoading)
        XCTAssertTrue(thumbnail.hasImage)
    }

    func testVisibleCapturesStartTogetherBeforeOffscreenWork() async {
        let windows = (0..<4).map { _ in previewWindow() }
        let visible = Set(windows.prefix(2).map(\.id))
        let ready = expectation(description: "Both visible captures started")
        ready.expectedFulfillmentCount = 2
        var started: [UUID] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
        let task = Task {
            await DockPreviewCaptureScheduling.load(windows: windows, initiallyVisible: visible) { window in
                started.append(window.id)
                if visible.contains(window.id) {
                    ready.fulfill()
                    await withCheckedContinuation { waiting.append($0) }
                }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        let allVisibleStarted = Set(started) == visible
        XCTAssertTrue(allVisibleStarted)
        if !allVisibleStarted { task.cancel() }
        waiting.forEach { $0.resume() }
        await task.value
        guard allVisibleStarted else { return }
        XCTAssertEqual(Array(started.dropFirst(2)), Array(windows.dropFirst(2).map(\.id)))
    }

    func testCancelledCaptureBatchDoesNotStartOffscreenWork() async {
        let windows = (0..<4).map { _ in previewWindow() }
        let visible = Set(windows.prefix(2).map(\.id))
        let ready = expectation(description: "Visible captures are in flight")
        ready.expectedFulfillmentCount = 2
        var started: [UUID] = []
        var waiting: [CheckedContinuation<Void, Never>] = []
        let task = Task {
            await DockPreviewCaptureScheduling.load(windows: windows, initiallyVisible: visible) { window in
                started.append(window.id)
                if visible.contains(window.id) {
                    ready.fulfill()
                    await withCheckedContinuation { waiting.append($0) }
                }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        task.cancel()
        waiting.forEach { $0.resume() }
        await task.value
        XCTAssertEqual(Set(started), visible)
    }

    func testPanelNeverBecomesKeyOrMainAndStartsHidden() {
        let panel = DockWindowPreviewPanelController.makePanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
    }

    func testPreparingPanelDoesNotMakeItVisible() {
        let controller = DockWindowPreviewPanelController()
        controller.prepare()
        controller.prepare()
        XCTAssertNil(controller.frame)
        XCTAssertTrue(controller.isParked)
    }

    func testDismissingPreviewReturnsItsPreparedSurfaceToTheTransparentParkingFrame() {
        let controller = DockWindowPreviewPanelController()
        let previewSession = session(windows: [previewWindow()])
        controller.show(session: previewSession, frame: CGRect(x: 100, y: 100, width: 200, height: 126)) { _ in }
        XCTAssertFalse(controller.isParked)
        controller.dismiss()
        XCTAssertNil(controller.frame)
        XCTAssertTrue(controller.isParked)
    }

    func testStoppingPreviewReleasesThePreparedSurfaceAndCanPrepareAgain() {
        let controller = DockWindowPreviewPanelController()
        controller.prepare()
        XCTAssertTrue(controller.isParked)
        controller.stop()
        XCTAssertFalse(controller.isParked)
        controller.prepare()
        XCTAssertTrue(controller.isParked)
        controller.stop()
    }

    func testReplacingPreviewKeepsOnePreparedSurfaceVisible() throws {
        let controller = DockWindowPreviewPanelController()
        let firstFrame = CGRect(x: 100, y: 100, width: 200, height: 126)
        let secondFrame = CGRect(x: 340, y: 100, width: 200, height: 126)
        controller.show(session: session(windows: [previewWindow()]), frame: firstFrame) { _ in }
        let windowNumber = try XCTUnwrap(controller.windowNumber)
        XCTAssertEqual(controller.frame, firstFrame)
        XCTAssertFalse(controller.isParked)

        controller.show(session: session(windows: [previewWindow()]), frame: secondFrame) { _ in }
        XCTAssertEqual(controller.windowNumber, windowNumber)
        XCTAssertEqual(controller.frame, secondFrame)
        XCTAssertFalse(controller.isParked)
        controller.stop()
    }

    func testPreviewPreferenceDefaultsOffIndependentlyOfClickActions() throws {
        let suite = "DockWindowPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "powerTools.dock.actionsEnabled")
        let controller = PowerToolsController(defaults: defaults)
        XCTAssertFalse(controller.dockWindowPreviewsEnabled)
        XCTAssertTrue(controller.dockActionsEnabled)
    }

    func testSavedPreviewPreferenceDoesNotEnableClickActions() throws {
        let suite = "DockWindowPreviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "powerTools.dock.windowPreviewsEnabled")
        let controller = PowerToolsController(defaults: defaults)
        XCTAssertTrue(controller.dockWindowPreviewsEnabled)
        XCTAssertFalse(controller.dockActionsEnabled)
        XCTAssertEqual(controller.activeDockClickBehavior, .system)
    }

    private enum RenderState: String, CaseIterable {
        case thumbnails, loading, unavailable, error
    }

    func testImageRevealSharpensInPlaceWithoutChangingItsBounds() throws {
        let size = CGSize(width: 200, height: 126)
        let image = NSImage(size: CGSize(width: 400, height: 252), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.black.setFill()
            for x in stride(from: 0, to: 400, by: 16) {
                CGRect(x: x, y: 0, width: 8, height: 252).fill()
            }
            return true
        }
        let output = ProcessInfo.processInfo.environment["DOCK_PREVIEW_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var contrasts: [CGFloat] = []
        for (index, progress) in [0.0, 0.25, 0.5, 0.75, 1.0].enumerated() {
            let view = Image(nsImage: image).resizable().scaledToFit()
                .modifier(DockPreviewImageReveal(progress: progress))
                .frame(width: size.width, height: size.height)
                .clipped()
            let panel = DockWindowPreviewPanelController.makePanel()
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            panel.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            // AppKit's cacheDisplay path omits composited blur filters. This
            // leaf has no lazy rows, so render its actual SwiftUI effects.
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(hosting.bounds.size, size)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            let y = Int(63 * scale)
            let colors = try (Int(24 * scale)..<Int(176 * scale)).map { x in
                try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            }
            let contrast = zip(colors, colors.dropFirst()).reduce(CGFloat.zero) {
                $0 + abs($1.0.redComponent - $1.1.redComponent)
            }
            contrasts.append(contrast)
            XCTAssertGreaterThan(colors[0].alphaComponent, 0.5, "The image must already be visible while softly blurred.")
            if let output {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("reveal-\(index).png"))
            }
            panel.contentView = nil
        }
        for (earlier, later) in zip(contrasts, contrasts.dropFirst()) {
            XCTAssertGreaterThan(later, earlier, "Each frame should resolve toward the sharp image, never pulse back to blur.")
        }
    }

    func testReducedMotionRevealsTheImageImmediatelyAtTheSameSize() throws {
        let window = previewWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 252))
        let size = DockPreviewLayout.cardSize(for: window)
        let panel = DockWindowPreviewPanelController.makePanel()
        let hosting = NSHostingView(rootView: DockWindowPreviewCard(
            window: window, thumbnail: .loading, appIcon: nil, reduceMotion: true, select: {}))
        panel.contentView = hosting
        panel.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let image = NSImage(size: CGSize(width: 400, height: 252), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            NSColor.white.setFill()
            CGRect(x: 180, y: 0, width: 40, height: 252).fill()
            return true
        }
        hosting.rootView = DockWindowPreviewCard(window: window, thumbnail: .image(image),
                                                appIcon: nil, reduceMotion: true, select: {})
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hosting.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        let settled = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: settled)
        XCTAssertEqual(first.representation(using: .png, properties: [:]), settled.representation(using: .png, properties: [:]))
        XCTAssertEqual(hosting.bounds.size, size)
        XCTAssertFalse(panel.isVisible)
        panel.contentView = nil
    }

    func testCompactPreviewStatesRenderOffscreen() throws {
        let output = ProcessInfo.processInfo.environment["DOCK_PREVIEW_RENDER_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let windows = [previewWindow(title: "Project notes — release checklist", frame: CGRect(x: 0, y: 0, width: 400, height: 252)),
                       previewWindow(title: "Planning", frame: CGRect(x: 0, y: 0, width: 300, height: 600), minimized: true)]
        let size = DockPreviewLayout.contentSize(windows: windows)
        for scheme in [ColorScheme.light, .dark] {
            for state in RenderState.allCases {
                let session = session(windows: windows, allowed: state != .unavailable)
                if state == .thumbnails || state == .error {
                    let image = NSImage(size: NSSize(width: 400, height: 252), flipped: false) { rect in
                        NSColor.windowBackgroundColor.setFill()
                        rect.fill()
                        NSColor.controlAccentColor.setFill()
                        NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 24), xRadius: 12, yRadius: 12).fill()
                        return true
                    }
                    session.thumbnails[windows[0].id] = .image(image)
                    session.thumbnails[windows[1].id] = .unavailable
                }
                if state == .error {
                    session.selectionError = "Couldn’t show this window. Hover again to refresh."
                }
                let view = DockWindowPreviewView(session: session, select: { _ in })
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, scheme)
                // ImageRenderer omits unrealized LazyHStack rows. Exercise the
                // actual hosting/window layout, without ordering a window in.
                let panel = DockWindowPreviewPanelController.makePanel()
                let hostingView = NSHostingView(rootView: view)
                panel.contentView = hostingView
                panel.setContentSize(size)
                hostingView.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                hostingView.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
                hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
                XCTAssertFalse(panel.isVisible)
                XCTAssertEqual(hostingView.bounds.size, size)
                XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
                let scale = CGFloat(bitmap.pixelsWide) / size.width
                let cardPixel = try XCTUnwrap(bitmap.colorAt(x: Int(40 * scale), y: Int(60 * scale)))
                let backgroundPixel = try XCTUnwrap(bitmap.colorAt(x: Int(204 * scale), y: Int(60 * scale)))
                XCTAssertLessThan(backgroundPixel.alphaComponent, 0.01, "There must be no tray chrome between previews.")
                let edgePixel = try XCTUnwrap(bitmap.colorAt(x: Int(2 * scale), y: Int(60 * scale)))
                if state == .loading {
                    XCTAssertGreaterThan(cardPixel.alphaComponent, 0.1, "Pending previews should retain a quiet frosted surface.")
                    XCTAssertGreaterThan(edgePixel.alphaComponent, 0.1, "The frosted surface must keep the final edge-to-edge geometry.")
                } else {
                    XCTAssertNotEqual(cardPixel.usingColorSpace(.deviceRGB), backgroundPixel.usingColorSpace(.deviceRGB),
                                      "Ready window cards must actually render.")
                    XCTAssertGreaterThan(edgePixel.alphaComponent, 0.99, "The preview must reach the panel edge without padding.")
                }
                if let output {
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let name = "\(scheme == .dark ? "dark" : "light")-\(state.rawValue).png"
                    try png.write(to: output.appendingPathComponent(name))
                }
                panel.contentView = nil
            }
        }
    }
}
