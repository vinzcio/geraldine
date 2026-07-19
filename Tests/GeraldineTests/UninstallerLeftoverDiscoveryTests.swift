import Foundation
import XCTest
@testable import Geraldine

final class UninstallerLeftoverDiscoveryTests: XCTestCase {
    private let directRoots = [
        "Application Support", "Caches", "Containers", "HTTPStorages", "Logs",
        "Preferences", "Saved Application State", "WebKit", "Group Containers"
    ]

    func testNormalBundleIDYieldsContainedExactCandidates() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }

        let id = "com.example.Product"
        let candidates = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: id, displayName: ""),
            libraryRoot: library,
            launchAgents: []
        )

        let expected = Set(directRoots.map { root in
            let isFile = root == "Preferences" || root == "Saved Application State"
            var url = library.appendingPathComponent(root, isDirectory: true)
                .appendingPathComponent(id, isDirectory: !isFile)
            if root == "Preferences" { url.appendPathExtension("plist") }
            if root == "Saved Application State" { url.appendPathExtension("savedState") }
            return url
        })
        XCTAssertEqual(Set(candidates.map(\.url)), expected)
        XCTAssertTrue(candidates.allSatisfy { $0.confidence == .bundleIdentifier })
        XCTAssertTrue(candidates.allSatisfy { $0.url.path.hasPrefix(library.path + "/") })
    }

    func testMalformedBundleIdentifiersYieldNoBundleCandidates() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }

        for id in ["com/example.Product", "com..example", "com.example.", ".com.example",
                   "example", "com/../../outside", "com.example+Product"] {
            let candidates = LeftoversModel.locateLeftovers(
                identity: UninstallerAppIdentity(bundleID: id, displayName: ""),
                libraryRoot: library,
                launchAgents: []
            )
            XCTAssertTrue(candidates.isEmpty, "Expected no candidates for \(id)")
        }
    }

    func testInvalidDisplayNamesYieldNoNameCandidates() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }

        for name in ["", ".", "..", "Acme/Tools", "Acme:Tools", "Acme\0Tools"] {
            let candidates = LeftoversModel.locateLeftovers(
                identity: UninstallerAppIdentity(bundleID: "", displayName: name),
                libraryRoot: library,
                launchAgents: []
            )
            XCTAssertTrue(candidates.isEmpty, "Expected no candidates for \(name.debugDescription)")
        }
    }

    func testUnicodeAndWhitespaceDisplayNamesRemainExactLeaves() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }

        let name = "  Café · Tools  "
        let candidates = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: "", displayName: name),
            libraryRoot: library,
            launchAgents: []
        )

        XCTAssertEqual(candidates.count, directRoots.count)
        XCTAssertTrue(candidates.allSatisfy { $0.confidence == .displayName })
        XCTAssertTrue(candidates.allSatisfy { $0.url.lastPathComponent == name ||
            $0.url.deletingPathExtension().lastPathComponent == name })
    }

    func testCraftedIdentifierAndSymlinkCannotEscapeAnySuppliedRoot() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let fm = FileManager.default
        let outside = library.deletingLastPathComponent()
            .appendingPathComponent("Geraldine-Uninstaller-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }

        let malformed = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: "com.example/../../outside", displayName: ""),
            libraryRoot: library,
            launchAgents: []
        )
        XCTAssertTrue(malformed.isEmpty)

        let id = "com.example.Product"
        for rootName in directRoots {
            let root = library.appendingPathComponent(rootName, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let target = outside.appendingPathComponent("\(UUID().uuidString).plist")
            fm.createFile(atPath: target.path, contents: Data())
            let isFile = rootName == "Preferences" || rootName == "Saved Application State"
            var candidate = root.appendingPathComponent(id, isDirectory: !isFile)
            if rootName == "Preferences" { candidate.appendPathExtension("plist") }
            if rootName == "Saved Application State" { candidate.appendPathExtension("savedState") }
            try fm.createSymbolicLink(at: candidate, withDestinationURL: target)
        }

        let candidates = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: id, displayName: ""),
            libraryRoot: library,
            launchAgents: []
        )

        XCTAssertTrue(candidates.isEmpty)
    }

    func testBroadDisplayNameDoesNotMatchUnrelatedLaunchAgents() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let launchRoot = library.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: launchRoot, withIntermediateDirectories: true)

        let entries = [
            LaunchAgentEntry(url: launchRoot.appendingPathComponent("com.example.Product-helper.plist"),
                             label: nil),
            LaunchAgentEntry(url: launchRoot.appendingPathComponent("helper.plist"), label: "Helper")
        ]
        let candidates = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: "com.example.Product", displayName: "Helper"),
            libraryRoot: library,
            launchAgents: entries
        )

        XCTAssertTrue(candidates.filter { $0.url.deletingLastPathComponent().lastPathComponent == "LaunchAgents" }.isEmpty)
    }

    func testExactLaunchAgentBasenameAndLabelMatchesAreAccepted() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let launchRoot = library.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: launchRoot, withIntermediateDirectories: true)
        let id = "com.example.Product"
        let entries = [
            LaunchAgentEntry(url: launchRoot.appendingPathComponent("\(id).plist"), label: nil),
            LaunchAgentEntry(url: launchRoot.appendingPathComponent("vendor.plist"), label: id),
            LaunchAgentEntry(url: launchRoot.appendingPathComponent("unrelated.plist"), label: "com.example.Other")
        ]

        let launchMatches = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: id, displayName: "Product"),
            libraryRoot: library,
            launchAgents: entries
        ).filter { $0.url.deletingLastPathComponent().lastPathComponent == "LaunchAgents" }

        XCTAssertEqual(Set(launchMatches.map(\.url)), Set(entries.prefix(2).map(\.url)))
        XCTAssertTrue(launchMatches.allSatisfy { $0.confidence == .bundleIdentifier })
    }

    func testLaunchAgentMatchesOutsideCanonicalRootAreRejected() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let fm = FileManager.default
        let launchRoot = library.appendingPathComponent("LaunchAgents")
        let outside = library.deletingLastPathComponent().appendingPathComponent("Geraldine-Uninstaller-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: launchRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }

        let id = "com.example.Product"
        let outsideTarget = outside.appendingPathComponent("outside.plist")
        fm.createFile(atPath: outsideTarget.path, contents: Data())
        let insideSymlink = launchRoot.appendingPathComponent("\(id).plist")
        try fm.createSymbolicLink(at: insideSymlink, withDestinationURL: outsideTarget)

        let insideTarget = launchRoot.appendingPathComponent("inside.plist")
        fm.createFile(atPath: insideTarget.path, contents: Data())
        let outsideSymlink = outside.appendingPathComponent("\(id)-outside.plist")
        try fm.createSymbolicLink(at: outsideSymlink, withDestinationURL: insideTarget)

        let entries = [
            LaunchAgentEntry(url: insideSymlink, label: nil),
            LaunchAgentEntry(url: outsideSymlink, label: id)
        ]
        let launchMatches = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: id, displayName: ""),
            libraryRoot: library,
            launchAgents: entries
        ).filter { $0.url.path.contains("LaunchAgents") || $0.url.path.contains("outside") }

        XCTAssertTrue(launchMatches.isEmpty)
    }

    func testLaunchAgentReaderRejectsSymlinksAndOversizedFiles() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let fm = FileManager.default
        let launchRoot = library.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: launchRoot, withIntermediateDirectories: true)

        let valid = launchRoot.appendingPathComponent("valid.plist")
        let validData = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.Product"],
            format: .xml,
            options: 0
        )
        try validData.write(to: valid)
        XCTAssertEqual(
            LeftoversModel.launchAgentEntry(at: valid, within: launchRoot)?.label,
            "com.example.Product"
        )

        let symlink = launchRoot.appendingPathComponent("symlink.plist")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: valid)
        XCTAssertNil(LeftoversModel.launchAgentEntry(at: symlink, within: launchRoot))

        let oversized = launchRoot.appendingPathComponent("oversized.plist")
        try Data(repeating: 0, count: 1_048_577).write(to: oversized)
        XCTAssertNil(LeftoversModel.launchAgentEntry(at: oversized, within: launchRoot))
    }

    func testDisplayNameOnlyCandidatesAreReviewOnlyAndUnselected() throws {
        let application = ScanItem(url: URL(fileURLWithPath: "/Applications/Helper.app"), size: 10)
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/Library/Caches/Helper"), size: 5)
        let groups = LeftoversModel.buildGroups(
            application: application,
            leftovers: [MeasuredLeftover(item: item, confidence: .displayName)]
        )

        XCTAssertEqual(groups.map(\.title), ["Application", "Possible Leftovers"])
        XCTAssertFalse(groups[1].safeByDefault)
        XCTAssertEqual(groups.defaultSelection, Set([application.id]))
    }

    func testApplicationAndExactBundleIDLeftoversAreSelectedByDefault() throws {
        let application = ScanItem(url: URL(fileURLWithPath: "/Applications/Product.app"), size: 10)
        let item = ScanItem(url: URL(fileURLWithPath: "/tmp/Library/Caches/com.example.Product"), size: 5)
        let groups = LeftoversModel.buildGroups(
            application: application,
            leftovers: [MeasuredLeftover(item: item, confidence: .bundleIdentifier)]
        )

        XCTAssertEqual(groups.map(\.title), ["Application", "Leftover Files"])
        XCTAssertEqual(groups.defaultSelection, Set([application.id, item.id]))
    }

    func testPathMatchedTwiceIsEmittedOnceWithStrongerConfidence() throws {
        let library = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: library) }
        let id = "com.example.Product"
        let candidates = LeftoversModel.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: id, displayName: id),
            libraryRoot: library,
            launchAgents: []
        )

        XCTAssertEqual(candidates.count, directRoots.count)
        XCTAssertTrue(candidates.allSatisfy { $0.confidence == .bundleIdentifier })
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Geraldine-Uninstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
