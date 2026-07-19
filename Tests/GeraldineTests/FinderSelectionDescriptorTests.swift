import AppKit
import XCTest
@testable import Geraldine

final class FinderSelectionDescriptorTests: XCTestCase {
    func testDecodesStructuredSelectionWithoutNormalizingPaths() {
        let paths = [
            "/tmp/normal.txt",
            "/tmp/line\nbreak.txt",
            "/tmp/ leading and trailing spaces .txt ",
            "/tmp/naïve-文件.txt",
            "/tmp/adjacent-one.txt",
            "/tmp/adjacent-two.txt"
        ]
        let descriptor = makeListDescriptor(paths: paths)

        let urls = FinderPowerToolsService.decodeSelectedFileURLs(from: descriptor)

        XCTAssertEqual(urls.map(\.path), paths)
        XCTAssertEqual(urls.count, paths.count)
    }

    func testIgnoresNonStringItemsWhilePreservingStringItemPositions() {
        let descriptor = NSAppleEventDescriptor.list()
        descriptor.insert(NSAppleEventDescriptor(string: "/tmp/first"), at: 0)
        descriptor.insert(NSAppleEventDescriptor(int32: 42), at: 0)
        descriptor.insert(NSAppleEventDescriptor(boolean: true), at: 0)
        descriptor.insert(NSAppleEventDescriptor(string: "/tmp/second"), at: 0)

        let urls = FinderPowerToolsService.decodeSelectedFileURLs(from: descriptor)

        XCTAssertEqual(urls.map(\.path), ["/tmp/first", "/tmp/second"])
        XCTAssertEqual(urls.count, 2)
    }

    func testEmptyListProducesNoURLs() {
        let descriptor = NSAppleEventDescriptor.list()

        XCTAssertEqual(FinderPowerToolsService.decodeSelectedFileURLs(from: descriptor), [])
    }

    func testNonListDescriptorProducesNoURLs() {
        let descriptor = NSAppleEventDescriptor(string: "/tmp/not-a-list")

        XCTAssertEqual(FinderPowerToolsService.decodeSelectedFileURLs(from: descriptor), [])
    }

    private func makeListDescriptor(paths: [String]) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.list()
        for path in paths {
            descriptor.insert(NSAppleEventDescriptor(string: path), at: 0)
        }
        return descriptor
    }
}
