import XCTest
import Security
@testable import Geraldine

final class AIUsageCredentialStoreTests: XCTestCase {
    func testEveryKeychainReadDisallowsPromptsAndDoesNotRetryDenial() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecItemNotFound] {
            for service in ["Claude Code-credentials", "cursor-access-token", "Cursor", "gemini", "antigravity", "agy"] {
                var calls = 0
                let token = AIUsageCredentialStore.keychainToken(service: service) { query, _ in
                    calls += 1
                    let values = query as NSDictionary
                    XCTAssertEqual(values[kSecUseAuthenticationUI] as? String, kSecUseAuthenticationUIFail as String)
                    XCTAssertEqual(values[kSecAttrService] as? String, service)
                    return status
                }
                XCTAssertNil(token)
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testSilentlyAccessibleTokenStillWorks() {
        let token = AIUsageCredentialStore.keychainToken(service: "gemini", account: "antigravity") { query, result in
            XCTAssertEqual((query as NSDictionary)[kSecAttrAccount] as? String, "antigravity")
            result?.pointee = Data("test-token".utf8) as CFData
            return errSecSuccess
        }
        XCTAssertEqual(token, AIUsageToken(value: "test-token"))
    }
}
