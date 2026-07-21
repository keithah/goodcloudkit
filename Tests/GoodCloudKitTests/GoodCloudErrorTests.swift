import XCTest
@testable import GoodCloudKit

final class GoodCloudErrorTests: XCTestCase {
    func test_decoding_roundTripsContext() {
        let err = GoodCloudError.decoding("unexpected field")
        XCTAssertEqual(err, .decoding("unexpected field"))
        XCTAssertFalse(err.redactedDescription.isEmpty)
    }

    func test_transport_redactedDescription_exposesOnlyCodeNeverURLDetail() {
        let sensitiveURL = "https://secret.example.com/token=abc123"
        let err = GoodCloudError.transport(
            URLError(.badURL, userInfo: [NSURLErrorFailingURLStringErrorKey: sensitiveURL])
        )
        let description = err.redactedDescription

        XCTAssertFalse(description.isEmpty)
        XCTAssertFalse(description.contains(sensitiveURL))
        XCTAssertFalse(description.contains("secret.example.com"))
        XCTAssertFalse(description.contains("token=abc123"))
        XCTAssertTrue(description.contains("\(URLError.Code.badURL.rawValue)"))
    }

    func test_transportWrapsURLError() {
        let err = GoodCloudError.transport(URLError(.notConnectedToInternet))
        XCTAssertEqual(err, .transport(URLError(.notConnectedToInternet)))
    }

    func test_redactedDescription_isNonEmptyForAllCases() {
        let allCases: [GoodCloudError] = [
            .authFailed,
            .credentialsRejected,
            .deviceOffline,
            .deviceNotFound,
            .relayUnavailable,
            .sessionExpired,
            .transport(URLError(.badURL)),
            .decoding("some diagnostic context"),
            .signing("x"),
            .api(code: 1, message: "y"),
            .httpStatus(502),
        ]

        for errorCase in allCases {
            XCTAssertFalse(
                errorCase.redactedDescription.isEmpty,
                "redactedDescription must be non-empty (and thus loggable) for \(errorCase)"
            )
        }
    }
}
