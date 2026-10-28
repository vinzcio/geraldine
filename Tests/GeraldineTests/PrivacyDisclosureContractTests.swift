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
            ["Antigravity", "Claude", "Codex", "Grok", "Cursor", "OpenCode", "Pi", "Muse"]
        )
        XCTAssertEqual(
            disclosure.text,
            "Antigravity, Claude, Codex, Grok, and Cursor allowances use the local sign-in already on this Mac through each official CLI. Token history also supports OpenCode, Pi, and Muse. Cursor history uses its dashboard with file credentials; public model prices come from LiteLLM. No separate Geraldine sign-in or Keychain access. Show or hide usage tiles below."
        )
    }

    func testCodingUsageDisclosureNamesEveryDirectRequest() {
        // Cursor history and public pricing are the approved direct HTTP
        // exceptions (docs/product/token-history.md); both must stay disclosed.
        let text = AIUsageDisclosure.current.text

        XCTAssertTrue(text.contains("Cursor history uses its dashboard"))
        XCTAssertTrue(text.contains("public model prices come from LiteLLM"))
        XCTAssertTrue(text.contains("No separate Geraldine sign-in or Keychain access"))
    }
}
