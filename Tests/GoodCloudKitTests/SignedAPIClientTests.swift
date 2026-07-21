import XCTest
@testable import GoodCloudKit

final class SignedAPIClientTests: XCTestCase {
    struct Counts: Decodable, Sendable, Equatable { let allCount: Int }

    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func test_get_sendsTokenAndSignatureHeadersAndDecodesInfo() async throws {
        let captured = CapturedBox()
        StubURLProtocol.handler = { req in
            captured.set(req)
            let body = #"{"code":0,"msg":"Success.","info":{"allCount":2}}"#
            return .init(status: 200, data: Data(body.utf8), headers: ["Content-Type": "application/json"])
        }
        let client = SignedAPIClient(
            baseURL: URL(string: "https://api.goodcloud.xyz")!,
            session: StubURLProtocol.session(),
            signer: .goodCloud(),
            tokens: StaticTokenProvider("TESTTOKEN")
        )
        let counts = try await client.get("/cloud-api/cloud/v2/orgDevice/count", query: [], as: Counts.self)
        XCTAssertEqual(counts, Counts(allCount: 2))

        let req = captured.value!
        XCTAssertEqual(req.value(forHTTPHeaderField: "token"), "TESTTOKEN")
        let sig = req.value(forHTTPHeaderField: "signature")
        XCTAssertEqual(sig.flatMap { Data(base64Encoded: $0)?.count }, 64) // real signature attached
        XCTAssertEqual(req.url?.absoluteString, "https://api.goodcloud.xyz/cloud-api/cloud/v2/orgDevice/count")
    }

    func test_get_disablesCookieHandling() async throws {
        let captured = CapturedBox()
        StubURLProtocol.handler = { req in
            captured.set(req)
            let body = #"{"code":0,"msg":"Success.","info":{"allCount":2}}"#
            return .init(status: 200, data: Data(body.utf8), headers: ["Content-Type": "application/json"])
        }
        let client = SignedAPIClient(
            baseURL: URL(string: "https://api.goodcloud.xyz")!,
            session: StubURLProtocol.session(),
            signer: .goodCloud(),
            tokens: StaticTokenProvider("TESTTOKEN")
        )
        _ = try await client.get("/cloud-api/cloud/v2/orgDevice/count", query: [], as: Counts.self)

        let req = captured.value!
        XCTAssertEqual(req.httpShouldHandleCookies, false, "cookies must never be persisted; auth is header-only (token/signature)")
    }

    func test_get_mapsNonZeroCodeToApiError() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(#"{"code":1007,"msg":"bad token","info":null}"#.utf8), headers: [:])
        }
        let client = SignedAPIClient(baseURL: URL(string: "https://api.goodcloud.xyz")!,
                                     session: StubURLProtocol.session(),
                                     signer: .goodCloud(), tokens: StaticTokenProvider("x"))
        do { _ = try await client.get("/x", query: [], as: Counts.self); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? GoodCloudError, .api(code: 1007, message: "bad token")) }
    }

    func test_get_mapsNon2xxStatusToHttpStatusError() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 502, data: Data("<html><body>Bad Gateway</body></html>".utf8), headers: [:])
        }
        let client = SignedAPIClient(baseURL: URL(string: "https://api.goodcloud.xyz")!,
                                     session: StubURLProtocol.session(),
                                     signer: .goodCloud(), tokens: StaticTokenProvider("x"))
        do { _ = try await client.get("/x", query: [], as: Counts.self); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? GoodCloudError, .httpStatus(502)) }
    }
}

/// Thread-safe one-shot box so the @Sendable handler can hand the request back to the test.
final class CapturedBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); _v = r; lock.unlock() }
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return _v }
}
