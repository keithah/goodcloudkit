import XCTest
@testable import GoodCloudKit

final class RelayHTTPClientTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    private func session(relayBase: String, token: String?) -> RemoteAccessSession {
        RemoteAccessSession(baseURL: URL(string: relayBase)!, tokenDomain: ".goodcloud.xyz",
                            sessionID: "s", issuedAtMillis: 1, relayToken: token)
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

    func test_shouldFollowRedirect_onlyForGoodcloudHosts() {
        XCTAssertTrue(RelayHTTPClient.shouldFollowRedirect(toHost: "rttys-web-cloud-us.goodcloud.xyz"))
        XCTAssertTrue(RelayHTTPClient.shouldFollowRedirect(toHost: "goodcloud.xyz"))
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: "192.168.8.1"))   // target LAN redirect
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: "notgoodcloud.xyz"))  // suffix spoof
        XCTAssertFalse(RelayHTTPClient.shouldFollowRedirect(toHost: nil))
    }
}
