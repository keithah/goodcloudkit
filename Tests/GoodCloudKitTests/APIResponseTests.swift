import XCTest
@testable import GoodCloudKit

final class APIResponseTests: XCTestCase {
    struct Payload: Decodable, Sendable, Equatable { let value: Int }

    func test_unwrap_returnsInfoOnCodeZero() throws {
        let json = #"{"code":0,"msg":"Success.","info":{"value":42}}"#
        let r = try JSONDecoder().decode(APIResponse<Payload>.self, from: Data(json.utf8))
        XCTAssertEqual(try r.unwrap(), Payload(value: 42))
    }

    func test_unwrap_throwsApiErrorOnNonZeroCode() throws {
        let json = #"{"code":1007,"msg":"token invalid","info":null}"#
        let r = try JSONDecoder().decode(APIResponse<Payload>.self, from: Data(json.utf8))
        XCTAssertThrowsError(try r.unwrap()) { error in
            XCTAssertEqual(error as? GoodCloudError, .api(code: 1007, message: "token invalid"))
        }
    }

    func test_unwrap_throwsWhenInfoMissingOnSuccess() throws {
        let json = #"{"code":0,"msg":"Success.","info":null}"#
        let r = try JSONDecoder().decode(APIResponse<Payload>.self, from: Data(json.utf8))
        XCTAssertThrowsError(try r.unwrap()) { error in
            guard let gc = error as? GoodCloudError, case .decoding = gc else {
                return XCTFail("expected .decoding, got \(error)")
            }
        }
    }
}
