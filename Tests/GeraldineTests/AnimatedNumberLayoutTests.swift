import XCTest
@testable import Geraldine

final class AnimatedNumberLayoutTests: XCTestCase {
    func testCompactUnitReplacementKeepsTheNumericRunReserved() {
        var widths = AnimatedNumberLayout.numberRunWidths(in: "999K")
        widths = AnimatedNumberLayout.updatedRunWidths(widths, previous: "999K", current: "1.00M")

        XCTAssertEqual(widths[0], 4)
        let segments = AnimatedNumberLayout.makeSegments(
            previous: "999K",
            current: "1.00M",
            reservedRunWidths: widths
        )
        XCTAssertEqual(segments.count, 2)
        guard case .literal(let previous, let current) = segments[1].kind else {
            return XCTFail("Expected a separate unit token")
        }
        XCTAssertEqual(previous, "K")
        XCTAssertEqual(current, "M")
    }

    func testDurationRolloverSeparatesDigitsFromUnitToken() {
        let segments = AnimatedNumberLayout.makeSegments(
            previous: "59m",
            current: "1h",
            reservedRunWidths: [0: 2]
        )

        XCTAssertEqual(segments.count, 2)
        guard case .literal(let previous, let current) = segments[1].kind else {
            return XCTFail("Expected a separate duration unit")
        }
        XCTAssertEqual(previous, "m")
        XCTAssertEqual(current, "h")
    }

    func testTemperatureSummaryPreservesLiteralTokens() {
        let segments = AnimatedNumberLayout.makeSegments(
            previous: "Peak 59°C",
            current: "Peak 60°C",
            reservedRunWidths: AnimatedNumberLayout.numberRunWidths(in: "Peak 59°C")
        )

        XCTAssertEqual(segments.count, 3)
        guard case .literal(let prefixBefore, let prefixAfter) = segments[0].kind,
              case .literal(let suffixBefore, let suffixAfter) = segments[2].kind else {
            return XCTFail("Expected stable prefix and temperature unit tokens")
        }
        XCTAssertEqual(prefixBefore, prefixAfter)
        XCTAssertEqual(suffixBefore, "°C")
        XCTAssertEqual(suffixAfter, "°C")
    }
}
