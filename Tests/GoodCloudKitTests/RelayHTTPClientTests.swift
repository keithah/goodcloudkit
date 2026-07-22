import XCTest
@testable import GoodCloudKit

final class RelayHTTPClientTests: XCTestCase {
    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    private func session(relayBase: String, token: String?) -> RemoteAccessSession {
        RemoteAccessSession(baseURL: URL(string: relayBase)!, tokenDomain: ".goodcloud.xyz",
                            sessionID: "s", issuedAtMillis: 1, feToken: token)
    }

    func test_url_forTargetPath_encodesHostPortAndPathIntoLastSegment() throws {
        let s = session(relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F", token: "T")
        let c = RelayHTTPClient(session: s)
        let u = try c.url(forTargetPath: "status")
        XCTAssertEqual(u.absoluteString,
            "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fstatus")
    }

    func test_get_installsSessionTokenAsBothCookiesForGoodcloudDomain() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:]) }
        // Verified live: gl-rtty-token AND FE_TOKEN both carry the session (FE) token.
        let s = RemoteAccessSession(
            baseURL: URL(string: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F")!,
            tokenDomain: ".goodcloud.xyz", sessionID: "s", issuedAtMillis: 1,
            relayToken: "ignored-content-id", feToken: "FE-TOK")
        let urlSession = StubURLProtocol.session()
        _ = try await RelayHTTPClient(session: s, urlSession: urlSession).get("status")
        let stored = urlSession.configuration.httpCookieStorage?.cookies ?? []
        let byName = Dictionary(uniqueKeysWithValues: stored.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["gl-rtty-token"], "FE-TOK")   // session token, not content.id
        XCTAssertEqual(byName["FE_TOKEN"], "FE-TOK")
        XCTAssertTrue(stored.allSatisfy { $0.domain.contains("goodcloud.xyz") })
    }

    func test_get_throwsWhenNoSessionToken() async {
        let s = RemoteAccessSession(baseURL: URL(string: "https://x.goodcloud.xyz/web/d/http/127.0.0.1%3A80%2F")!,
            tokenDomain: ".goodcloud.xyz", sessionID: "s", issuedAtMillis: 1, relayToken: "content-id", feToken: nil)
        let c = RelayHTTPClient(session: s, urlSession: StubURLProtocol.session())
        do { _ = try await c.get(""); XCTFail() } catch { XCTAssertEqual(error as? GoodCloudError, .relayUnavailable) }
    }

    func test_request_passesMethodHeadersAndBodyVerbatim() async throws {
        let body = Data(#"{"action":"dc_off"}"#.utf8)
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 200, data: Data(), headers: [:])
        }
        let client = RelayHTTPClient(session: session(
            relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
            token: "FE-TOK"
        ), urlSession: StubURLProtocol.session())

        _ = try await client.request(
            method: "POST",
            path: "/api/v1/device/action",
            headers: [
                "Authorization": "Bearer wattline-token",
                "Content-Type": "application/json",
            ],
            body: body
        )

        let captured = try XCTUnwrap(capture.requests.first)
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.httpBody, body)
        XCTAssertEqual(captured.url?.absoluteString,
            "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fapi%2Fv1%2Fdevice%2Faction")
    }

    func test_convenienceMethodsDelegateWithoutInventingHeadersOrBody() async throws {
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 200, data: Data(), headers: [:])
        }
        let client = RelayHTTPClient(session: session(
            relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
            token: "FE-TOK"
        ), urlSession: StubURLProtocol.session())
        _ = try await client.get("api/v1/status", headers: ["Accept": "application/json"])
        _ = try await client.post("api/v1/rules", body: Data("{}".utf8))
        _ = try await client.put("api/v1/rules/night", body: Data("{}".utf8))
        _ = try await client.delete("api/v1/rules/night")

        let requests = capture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "PUT", "DELETE"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(requests[0].httpBody)
        XCTAssertEqual(requests[1].httpBody, Data("{}".utf8))
        XCTAssertEqual(requests[2].httpBody, Data("{}".utf8))
        XCTAssertNil(requests[3].httpBody)
    }

    func test_shouldFollowRedirect_onlyForGoodcloudHosts() {
        XCTAssertTrue(RelayHTTPClient.shouldFollowRedirect(toHost: "rttys-web-cloud-us.goodcloud.xyz"))
        XCTAssertTrue(RelayHTTPClient.shouldFollowRedirect(toHost: "goodcloud.xyz"))
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: "192.168.8.1"))   // target LAN redirect
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: "notgoodcloud.xyz"))  // suffix spoof
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: nil))
    }
}
