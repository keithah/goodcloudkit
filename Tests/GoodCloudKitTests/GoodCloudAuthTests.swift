import XCTest
@testable import GoodCloudKit

final class GoodCloudAuthTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    /// Regression test for the `+`/`/`/`=` corruption bug: `URLComponents.percentEncodedQuery`
    /// does NOT percent-encode `+`, but base64 (the RSA-encrypted password) is full of them, and
    /// `application/x-www-form-urlencoded` parsers decode `+` as a literal space — silently
    /// corrupting the ciphertext server-side. `FormURLEncoded.body` must escape every byte that
    /// isn't in the unreserved set, so a spec-correct decoder recovers the exact original value.
    func test_formURLEncoded_roundTripsBase64SpecialChars() {
        let base64Like = "aB+cd/ef=gh+="
        let withAmpersandAndSpace = "foo&bar baz+qux"

        let body = FormURLEncoded.body([
            ("password", base64Like),
            ("note", withAmpersandAndSpace),
        ])

        // Bug-catching assertions: none of the risky raw characters may survive encoding.
        XCTAssertFalse(body.contains("+"), "raw '+' must be percent-encoded (got: \(body))")
        XCTAssertTrue(body.contains("%2B"), "'+' should be encoded as %2B")
        XCTAssertTrue(body.contains("%2F"), "'/' should be encoded as %2F")
        XCTAssertTrue(body.contains("%3D"), "'=' within a value should be encoded as %3D")
        XCTAssertTrue(body.contains("%20") || !body.contains(" "), "space must be percent-encoded, not raw")
        XCTAssertFalse(body.contains("baz+qux"), "raw '+' inside a value must not survive encoding")

        // Round-trip with a spec-correct application/x-www-form-urlencoded parser:
        // split on '&', split each pair on the first '=', then removingPercentEncoding.
        func parse(_ s: String) -> [(String, String)] {
            s.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
                return (key, value)
            }
        }
        let decoded = parse(body)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].0, "password")
        XCTAssertEqual(decoded[0].1, base64Like)
        XCTAssertEqual(decoded[1].0, "note")
        XCTAssertEqual(decoded[1].1, withAmpersandAndSpace)
    }

    func test_logIn_postsFormWithEncryptedPasswordAndStoresTokenFromBody() async throws {
        let captured = CapturedBox()
        StubURLProtocol.handler = { req in
            captured.set(req)
            // token returned in the envelope body
            let body = #"{"code":0,"msg":"Success.","info":"FE-XYZ"}"#
            return .init(status: 200, data: Data(body.utf8), headers: ["Content-Type":"application/json"])
        }
        let store = InMemoryCredentialStore()
        let auth = GoodCloudAuth(session: StubURLProtocol.session(),
                                 identity: FixedDeviceIdentityStore(deviceId: "dev", singleId: "sng"),
                                 credentials: store)
        let token = try await auth.logIn(email: "a@b.com", password: "pw")
        XCTAssertEqual(token, "FE-XYZ")
        XCTAssertEqual(try store.load()?.refreshToken, "FE-XYZ")  // persisted

        let req = captured.value!
        XCTAssertEqual(req.url?.path, "/cloud-basic/cloud/v2/auth/login")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "signature"))
        let form = String(data: req.httpBodyData(), encoding: .utf8) ?? ""
        XCTAssertTrue(form.contains("name=a%40b.com") || form.contains("name=a@b.com"))
        XCTAssertTrue(form.contains("deviceId=dev"))
        XCTAssertTrue(form.contains("singleId=sng"))
        XCTAssertTrue(form.contains("password="))            // present + non-empty
        XCTAssertFalse(form.contains("password=pw"))          // never the plaintext
    }

    func test_logIn_readsTokenFromSetCookieWhenBodyLacksIt() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(#"{"code":0,"msg":"Success.","info":{}}"#.utf8),
                  headers: ["Set-Cookie": "FE_TOKEN=COOKIE-TOK; Domain=.goodcloud.xyz; Path=/"])
        }
        let auth = GoodCloudAuth(session: StubURLProtocol.session(),
                                 identity: FixedDeviceIdentityStore(deviceId: "d", singleId: "s"),
                                 credentials: InMemoryCredentialStore())
        let token = try await auth.logIn(email: "a@b.com", password: "pw")
        XCTAssertEqual(token, "COOKIE-TOK")
    }

    func test_logIn_throwsApiErrorOnBadCredentials() async {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(#"{"code":1001,"msg":"invalid credentials","info":null}"#.utf8), headers: [:])
        }
        let auth = GoodCloudAuth(session: StubURLProtocol.session(),
                                 identity: FixedDeviceIdentityStore(deviceId: "d", singleId: "s"),
                                 credentials: InMemoryCredentialStore())
        do { _ = try await auth.logIn(email: "a@b.com", password: "bad"); XCTFail() }
        catch { XCTAssertEqual(error as? GoodCloudError, .api(code: 1001, message: "invalid credentials")) }
    }
}

// small helper so the test reads the body even when URLProtocol strips httpBody into a stream
extension URLRequest { func httpBodyData() -> Data {
    if let b = httpBody { return b }
    guard let s = httpBodyStream else { return Data() }
    s.open(); defer { s.close() }
    var d = Data(); let n = 4096; var buf = [UInt8](repeating: 0, count: n)
    while s.hasBytesAvailable { let r = s.read(&buf, maxLength: n); if r <= 0 { break }; d.append(buf, count: r) }
    return d
} }
