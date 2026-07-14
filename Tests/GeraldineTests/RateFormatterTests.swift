import XCTest
@testable import Geraldine

final class RateFormatterTests: XCTestCase {
    func testByteRatesUseAdaptiveByteUnits() {
        XCTAssertEqual(Fmt.compactRate(500), "500B/s")
        XCTAssertEqual(Fmt.compactRate(125_000), "125KB/s")
        XCTAssertEqual(Fmt.compactRate(1_260_000), "1.3MB/s")
        XCTAssertEqual(Fmt.compactRate(1_260_000_000), "1.3GB/s")
    }

    func testBitRatesConvertBytesAndUseAdaptiveBitUnits() {
        let unit = NetworkRateUnit.bitsPerSecond

        XCTAssertEqual(Fmt.compactRate(125, unit: unit), "1.0Kbps")
        XCTAssertEqual(Fmt.compactRate(125_000, unit: unit), "1.0Mbps")
        XCTAssertEqual(Fmt.compactRate(125_000_000, unit: unit), "1.0Gbps")
    }

    func testExpandedRatesDistinguishBytesFromBits() {
        XCTAssertEqual(Fmt.rate(1_000_000), "1.0 MB/s")
        XCTAssertEqual(Fmt.rate(1_000_000, unit: .bitsPerSecond), "8.0 Mbps")
    }

    func testInvalidRatesStaySafeInBothUnits() {
        XCTAssertEqual(Fmt.compactRate(.nan), "0B/s")
        XCTAssertEqual(Fmt.compactRate(.infinity, unit: .bitsPerSecond), "0bps")
    }
}
