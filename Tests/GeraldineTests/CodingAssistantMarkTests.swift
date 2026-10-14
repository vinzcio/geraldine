import AppKit
import SwiftUI
import XCTest
@testable import Geraldine

@MainActor
final class CodingAssistantMarkTests: XCTestCase {
    /// Grok's mark is a white G. On the light-mode chip, which is white too,
    /// it vanished.
    func testGrokMarkStandsOutFromItsChipInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let spread = try brightnessSpread(CodingAssistantMark(provider: .grok, size: 40), scheme: scheme)
            XCTAssertGreaterThan(spread, 128, "The Grok mark blends into its chip in \(scheme) mode")
        }
    }

    /// Brightest minus darkest opaque pixel, 0–255. Only the chip and the mark
    /// drawn on it are opaque, so this is their contrast.
    private func brightnessSpread(_ mark: CodingAssistantMark, scheme: ColorScheme) throws -> Int {
        let renderer = ImageRenderer(content: mark.environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let count = image.width * image.height * 4
        let bytes = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: count)
        var levels: [Int] = []
        for offset in stride(from: 0, to: count, by: 4) where bytes[offset + 3] == 255 {
            levels.append((Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3)
        }
        return try XCTUnwrap(levels.max()) - XCTUnwrap(levels.min())
    }
}
