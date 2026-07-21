import XCTest
@testable import GoodCloudKit

final class RemoteAccessTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func test_remoteAccess_sendsExactQueryParamsAndReturnsRelayURL() async throws {
        let captured = CapturedBox()
        let json = """
        {"code":0,"msg":"Success.","info":{"token_domain":".goodcloud.xyz",
          "url":"https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
          "content":{"goodcloud":[],"code":0,"id":"abc123","time":1700000000000}}}
        """
        StubURLProtocol.handler = { req in
            captured.set(req)
            return .init(status: 200, data: Data(json.utf8), headers: [:])
        }
        let client = SignedAPIClient(session: StubURLProtocol.session(), tokens: StaticTokenProvider("t"))
        let s = try await client.remoteAccess(deviceID: "100000001", kind: .web, protocol: .http,
                                              ip: "127.0.0.1", port: 8377)
        XCTAssertEqual(s.baseURL.absoluteString,
            "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F")
        XCTAssertEqual(s.tokenDomain, ".goodcloud.xyz")
        XCTAssertEqual(s.sessionID, "abc123")

        let req = captured.value!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/cloud-api/cloud/device/v4/100000001/rtty/run")
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["enable"], "true")
        XCTAssertEqual(dict["ip"], "127.0.0.1")
        XCTAssertEqual(dict["port"], "8377")
        XCTAssertEqual(dict["protocol"], "http")
        XCTAssertEqual(dict["rtty_type"], "web")
        XCTAssertEqual(dict["web"], "true")
        // gl-rtty-token is derived from the body's content.id (no Set-Cookie); FE_TOKEN captured too.
        XCTAssertEqual(s.relayToken, "abc123")
        XCTAssertEqual(s.feToken, "t")
    }

    func test_remoteAccess_derivesRelayTokenFromContentIdNotSetCookie() async throws {
        // The real API sends NO Set-Cookie on rtty/run; even if one appears, the relay token
        // comes from content.id. Provide a (red-herring) Set-Cookie to prove it is ignored.
        let json = """
        {"code":0,"msg":"Success.","info":{"token_domain":".goodcloud.xyz",
          "url":"https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
          "content":{"goodcloud":[],"code":0,"id":"abc123","time":1700000000000}}}
        """
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(json.utf8),
                  headers: ["Set-Cookie": "gl-rtty-token=IGNORED; Domain=.goodcloud.xyz; Path=/; HttpOnly"])
        }
        let client = SignedAPIClient(session: StubURLProtocol.session(), tokens: StaticTokenProvider("fe-123"))
        let s = try await client.remoteAccess(deviceID: "100000001", kind: .web, protocol: .http,
                                              ip: "127.0.0.1", port: 8377)
        XCTAssertEqual(s.relayToken, "abc123")   // content.id, not the Set-Cookie value
        XCTAssertEqual(s.feToken, "fe-123")
    }
}
