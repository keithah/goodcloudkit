import XCTest
@testable import GoodCloudKit

final class SecretRedactorTests: XCTestCase {
    func test_redactsRegisteredSecret() {
        let r = SecretRedactor().adding("s3cr3t-token")
        XCTAssertEqual(r.redact("token=s3cr3t-token end"), "token=••• end")
    }

    func test_ignoresEmptySecret() {
        let r = SecretRedactor().adding("")
        XCTAssertEqual(r.redact("nothing to hide"), "nothing to hide")
    }

    func test_redactsBearerEvenWhenNotRegistered() {
        let r = SecretRedactor()
        let out = r.redact("Authorization: Bearer abc.def.ghi")
        XCTAssertFalse(out.contains("abc.def.ghi"))
        XCTAssertTrue(out.contains("Authorization: Bearer •••"))
    }

    func test_longerSecretRedactedBeforeShorterSubstring() {
        let r = SecretRedactor().adding("ab").adding("abcdef")
        XCTAssertEqual(r.redact("abcdef"), "•••")
    }

    func test_overlappingNonNestedSecrets_fullyRedacted() {
        let r = SecretRedactor().adding("abcd").adding("cdef")
        XCTAssertEqual(r.redact("abcdef"), "•••")
    }

    func test_equalLengthOverlap_isDeterministic() {
        // "abcd" and "bcde" overlap in the middle ("bcd") without either containing the other.
        // Both are length 4, so Set iteration order must not affect the result.
        let r = SecretRedactor().adding("abcd").adding("bcde")
        XCTAssertEqual(r.redact("xxabcdexx"), "xx•••xx")
    }
}
