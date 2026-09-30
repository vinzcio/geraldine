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

    func testCodingUsageDisclosureStaysLocalAndNamesProviders() {
        let disclosure = AIUsageDisclosure.current
        XCTAssertEqual(
            disclosure.destinations,
            ["Antigravity", "Claude", "Codex", "Grok", "Cursor"]
        )
        XCTAssertEqual(
            disclosure.text,
            "For Antigravity, Claude, Codex, Grok, and Cursor, runs each official CLI with the local sign-in already on this Mac; the CLI asks its provider for remaining usage. No separate Geraldine sign-in or Keychain access. Show or hide usage tiles below."
        )
    }
}
