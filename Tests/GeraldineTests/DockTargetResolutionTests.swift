import XCTest
@testable import Geraldine

final class DockTargetResolutionTests: XCTestCase {
    private let editorURL = URL(fileURLWithPath: "/Applications/Editor.app")
    private let alternateEditorURL = URL(fileURLWithPath: "/Applications/Alternate/Editor.app")

    func testCanonicalURLSelectsTheExactApplicationAmongDuplicateNames() {
        let candidates = [
            candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor"),
            candidate(processIdentifier: 20, bundleURL: alternateEditorURL, name: "Editor")
        ]

        XCTAssertEqual(DockPreviewApplicationMatching.processIdentifier(
            itemURL: alternateEditorURL,
            title: "Editor",
            candidates: candidates
        ), 20)
    }

    func testDuplicateCanonicalURLsFailClosed() {
        let candidates = [
            candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor"),
            candidate(processIdentifier: 20, bundleURL: editorURL, name: "Editor")
        ]

        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(
            itemURL: editorURL,
            title: "Editor",
            candidates: candidates
        ))
    }

    func testStaleCanonicalURLNeverFallsBackToMatchingLabel() {
        let candidates = [candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor")]

        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(
            itemURL: alternateEditorURL,
            title: "Editor",
            candidates: candidates
        ))
    }

    func testAmbiguousNameOnlyIdentityFailsClosed() {
        let candidates = [
            candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor"),
            candidate(processIdentifier: 20, bundleURL: alternateEditorURL, name: "Editor")
        ]

        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(
            itemURL: nil,
            title: "Editor",
            candidates: candidates
        ))
    }

    func testUniqueNameOnlyIdentitySelectsItsApplication() {
        let candidates = [candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor")]

        XCTAssertEqual(DockPreviewApplicationMatching.processIdentifier(
            itemURL: nil,
            title: "Editor",
            candidates: candidates
        ), 10)
    }

    func testWhitespaceOnlyNameWithoutURLFailsClosed() {
        let candidates = [candidate(processIdentifier: 10, bundleURL: editorURL, name: "Editor")]

        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(
            itemURL: nil,
            title: "  \n  ",
            candidates: candidates
        ))
    }

    func testUnsupportedCandidateSetFailsClosed() {
        let candidates = [
            candidate(
                processIdentifier: 30,
                bundleURL: URL(fileURLWithPath: "/Applications/Viewer.app"),
                name: "Viewer"
            )
        ]

        XCTAssertNil(DockPreviewApplicationMatching.processIdentifier(
            itemURL: nil,
            title: "Editor",
            candidates: candidates
        ))
    }

    private func candidate(
        processIdentifier: Int32,
        bundleURL: URL?,
        name: String
    ) -> DockPreviewApplicationCandidate {
        DockPreviewApplicationCandidate(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL,
            name: name
        )
    }
}
