import XCTest
@testable import Geraldine

final class PrivacyDisclosureContractTests: XCTestCase {
    func testCurrentSpeedTestDisclosureOwnsTransferFacts() {
        let disclosure = NetworkSpeedTestDisclosure.current

        XCTAssertEqual(disclosure.destination, "Cloudflare")
        XCTAssertEqual(disclosure.downloadByteCount, 25_000_000)
        XCTAssertEqual(disclosure.uploadByteCount, 10_000_000)
        XCTAssertEqual(
            disclosure.text,
            "Runs a speed test with Cloudflare; each test transfers up to 25 MB down and 10 MB up."
        )
    }

    func testCurrentDisclosureNamesEveryMaterialTransferFact() {
        let text = NetworkSpeedTestDisclosure.current.text

        XCTAssertTrue(text.contains("Cloudflare"))
        XCTAssertTrue(text.contains("25 MB"))
        XCTAssertTrue(text.contains("10 MB"))
        XCTAssertTrue(text.contains("each test"))
    }
}
