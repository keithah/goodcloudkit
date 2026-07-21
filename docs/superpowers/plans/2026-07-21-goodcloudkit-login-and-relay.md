# GoodCloudKit Login + Relay-Consumption + Example App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make GoodCloudKit end-to-end usable: in-app email/password login (mints `FE_TOKEN`), a relay HTTP client that actually pushes requests to a router LAN service through the rtty relay, and a small example app wiring login → devices → relay request.

**Architecture:** Login uses GoodCloud's own `POST /cloud/v2/auth/login` (RSA-encrypted password via the same key as the signature) behind a `PasswordTokenProvider: TokenProvider`, persisting `FE_TOKEN` (+ refresh if present) in the Keychain `CredentialStore`. `remoteAccess()` now captures the `gl-rtty-token` cookie from the provisioning response; a `RelayHTTPClient` builds relay URLs for arbitrary target sub-paths and attaches that cookie. An SPM SwiftUI example app demonstrates the full flow.

**Tech Stack:** Swift 5.9 SPM; Foundation `URLSession`; Security (RSA, Keychain); SwiftUI (example app, macOS executable target); XCTest + `StubURLProtocol`. Builds on the merged wire layer.

## Global Constraints

- Module `GoodCloudKit`; iOS 17 / macOS 14; Foundation + Security + SwiftUI (example only), no third-party deps.
- API base `https://api.goodcloud.xyz`; envelope `{code,msg,info}`, code 0 = success.
- **Login:** `POST /cloud/v2/auth/login`, body **form-url-encoded** with `name=<email>`, `password=<base64 RSA-PKCS1v1.5(embedded pubkey, plaintext)>`, `deviceId=<stable id>`, `singleId=<stable id>`; request carries a `signature` header (RSA timestamp), no `token` yet. Response is `{code,msg,info}` — the `FE_TOKEN` is either in `info` (field name unverified) or a `Set-Cookie: FE_TOKEN` header; read both, prefer body, error if neither. (Verify the exact field on first live run.)
- **Signature/password encryption:** reuse the verified `RequestSigner` RSA primitive; password plaintext must be ≤ 53 bytes (512-bit PKCS#1 limit) — validate and throw a clear error otherwise.
- **Relay auth:** provisioning (`rtty/run`) returns `Set-Cookie: gl-rtty-token=<v>` (domain `.goodcloud.xyz`). Capture it; send `Cookie: gl-rtty-token=<v>` on every relay request. Relay URL form: `https://<rttysHost>/web/<ddns>/<http|https>/<percent-encoded "host:port/<targetPath>">`. `URLSession` follows the `-ssh-`→`-web-` redirect automatically.
- Secrets (password, tokens, signature, cookies) never logged; reuse `SecretRedactor`. Concurrency: actors + `Sendable` + async/await.

---

### Task 1: Expose RSA encryption on RequestSigner (for password)

**Files:**
- Modify: `Sources/GoodCloudKit/RequestSigner.swift`
- Modify: `Tests/GoodCloudKitTests/RequestSignerTests.swift`

**Interfaces:**
- Produces: `func encrypt(_ plaintext: String) throws -> String` on `RequestSigner` (base64 RSA-PKCS1v1.5); `signature()` becomes `try encrypt(String(currentMillis))`. Throws `GoodCloudError.signing` if plaintext exceeds the key's max (53 bytes for 512-bit).

- [ ] **Step 1: Write the failing test**

```swift
func test_encrypt_roundTripsArbitraryString() throws {
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                kSecAttrKeySizeInBits as String: 1024]
    var err: Unmanaged<CFError>?
    let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err)!
    let pubDER = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(priv)!, &err)! as Data
    let signer = RequestSigner(publicKeyPKCS1DER: pubDER)
    let ct = try signer.encrypt("hunter2-secret")
    let pt = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, Data(base64Encoded: ct)! as CFData, &err)! as Data
    XCTAssertEqual(String(data: pt, encoding: .utf8), "hunter2-secret")
}

func test_encrypt_throwsWhenPlaintextTooLongForKey() {
    let signer = RequestSigner.goodCloud() // 512-bit: max 53 bytes
    XCTAssertThrowsError(try signer.encrypt(String(repeating: "x", count: 54)))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter RequestSignerTests`
Expected: FAIL — `encrypt` not defined.

- [ ] **Step 3: Refactor implementation**

In `RequestSigner.swift`, extract the key-building + encryption into `encrypt`, and make `signature()` delegate:

```swift
public func signature() throws -> String {
    let millis = Int64((now().timeIntervalSince1970 * 1000).rounded())
    return try encrypt(String(millis))
}

public func encrypt(_ plaintext: String) throws -> String {
    var error: Unmanaged<CFError>?
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(publicKeyPKCS1DER as CFData, attrs as CFDictionary, &error) else {
        throw GoodCloudError.signing("invalid public key: \(errString(error))")
    }
    guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
        throw GoodCloudError.signing("PKCS1 encryption unsupported")
    }
    let data = Data(plaintext.utf8)
    let maxLen = SecKeyGetBlockSize(key) - 11 // PKCS#1 v1.5 overhead
    guard data.count <= maxLen else {
        throw GoodCloudError.signing("plaintext too long (\(data.count) > \(maxLen))")
    }
    guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, data as CFData, &error) else {
        throw GoodCloudError.signing("encrypt failed: \(errString(error))")
    }
    return (ct as Data).base64EncodedString()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter RequestSignerTests`
Expected: PASS (all, incl. the 2 new). Warning-free `swift build`.

- [ ] **Step 5: Commit**

```bash
cd ~/src/goodcloudkit && git add Sources/GoodCloudKit/RequestSigner.swift Tests/GoodCloudKitTests/RequestSignerTests.swift
git commit -m "feat: expose RequestSigner.encrypt(_:) for password encryption"
```

---

### Task 2: DeviceIdentity (stable deviceId/singleId)

**Files:**
- Create: `Sources/GoodCloudKit/DeviceIdentity.swift`
- Test: `Tests/GoodCloudKitTests/DeviceIdentityTests.swift`

**Interfaces:**
- Produces:
  - `struct DeviceIdentity: Sendable, Equatable { let deviceId: String; let singleId: String }`
  - `protocol DeviceIdentityStore: Sendable { func identity() -> DeviceIdentity }`
  - `final class PersistentDeviceIdentityStore: DeviceIdentityStore` — generates two UUID strings once and persists them in `UserDefaults` (key-namespaced), returning the same values thereafter.
  - `struct FixedDeviceIdentityStore: DeviceIdentityStore` (test/support: returns injected values).

- [ ] **Step 1: Write the failing test**

```swift
func test_persistentStore_isStableAcrossInstances() {
    let suite = UserDefaults(suiteName: "gck.test.\(UUID().uuidString)")!
    let a = PersistentDeviceIdentityStore(defaults: suite).identity()
    let b = PersistentDeviceIdentityStore(defaults: suite).identity()
    XCTAssertEqual(a, b)                      // persisted, not regenerated
    XCTAssertNotEqual(a.deviceId, a.singleId) // two distinct ids
    XCTAssertFalse(a.deviceId.isEmpty)
}

func test_fixedStore_returnsInjected() {
    let s = FixedDeviceIdentityStore(deviceId: "d", singleId: "s")
    XCTAssertEqual(s.identity(), DeviceIdentity(deviceId: "d", singleId: "s"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter DeviceIdentityTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct DeviceIdentity: Sendable, Equatable {
    public let deviceId: String
    public let singleId: String
    public init(deviceId: String, singleId: String) { self.deviceId = deviceId; self.singleId = singleId }
}

public protocol DeviceIdentityStore: Sendable {
    func identity() -> DeviceIdentity
}

public struct FixedDeviceIdentityStore: DeviceIdentityStore {
    private let value: DeviceIdentity
    public init(deviceId: String, singleId: String) { value = .init(deviceId: deviceId, singleId: singleId) }
    public func identity() -> DeviceIdentity { value }
}

/// Generates two UUIDs once and persists them; returns the same identity thereafter.
public final class PersistentDeviceIdentityStore: DeviceIdentityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let deviceKey = "xyz.goodcloud.GoodCloudKit.deviceId"
    private let singleKey = "xyz.goodcloud.GoodCloudKit.singleId"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func identity() -> DeviceIdentity {
        lock.lock(); defer { lock.unlock() }
        let d = defaults.string(forKey: deviceKey) ?? persist(UUID().uuidString, deviceKey)
        let s = defaults.string(forKey: singleKey) ?? persist(UUID().uuidString, singleKey)
        return DeviceIdentity(deviceId: d, singleId: s)
    }
    private func persist(_ v: String, _ k: String) -> String { defaults.set(v, forKey: k); return v }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter DeviceIdentityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/src/goodcloudkit && git add Sources/GoodCloudKit/DeviceIdentity.swift Tests/GoodCloudKitTests/DeviceIdentityTests.swift
git commit -m "feat: DeviceIdentity + persistent/fixed stores"
```

---

### Task 3: Password login + PasswordTokenProvider

**Files:**
- Create: `Sources/GoodCloudKit/GoodCloudAuth.swift`
- Test: `Tests/GoodCloudKitTests/GoodCloudAuthTests.swift`

**Interfaces:**
- Consumes: `RequestSigner.encrypt` (T1), `DeviceIdentityStore` (T2), `CredentialStore` (Phase 1), `APIResponse` (wire), `GoodCloudError`.
- Produces:
  - `actor GoodCloudAuth` with
    `init(baseURL: URL = .init(string:"https://api.goodcloud.xyz")!, session: URLSession = .shared, signer: RequestSigner = .goodCloud(), identity: DeviceIdentityStore = PersistentDeviceIdentityStore(), credentials: CredentialStore = KeychainCredentialStore())`,
    `func logIn(email: String, password: String) async throws -> String` (returns FE_TOKEN, persists it),
    `func currentToken() throws -> String?` (from CredentialStore),
    `func logOut() throws`.
  - `struct PasswordTokenProvider: TokenProvider` wrapping a stored token: `init(auth: GoodCloudAuth)`, `func token() async throws -> String` (returns the persisted token or throws `.authFailed` if none).

- [ ] **Step 1: Write the failing test**

```swift
final class GoodCloudAuthTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func test_logIn_postsFormWithEncryptedPasswordAndStoresTokenFromBody() async throws {
        let captured = CapturedBox()
        StubURLProtocol.handler = { req in
            captured.set(req)
            // token returned in the envelope body
            let body = #"{"code":0,"msg":"Success.","info":{"token":"FE-XYZ"}}"#
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
        XCTAssertEqual(req.url?.path, "/cloud/v2/auth/login")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter GoodCloudAuthTests`
Expected: FAIL — `GoodCloudAuth` not defined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public actor GoodCloudAuth {
    private let baseURL: URL
    private let session: URLSession
    private let signer: RequestSigner
    private let identity: DeviceIdentityStore
    private let credentials: CredentialStore

    public init(baseURL: URL = URL(string: "https://api.goodcloud.xyz")!,
                session: URLSession = .shared,
                signer: RequestSigner = .goodCloud(),
                identity: DeviceIdentityStore = PersistentDeviceIdentityStore(),
                credentials: CredentialStore = KeychainCredentialStore()) {
        self.baseURL = baseURL; self.session = session; self.signer = signer
        self.identity = identity; self.credentials = credentials
    }

    private struct LoginInfo: Decodable, Sendable { let token: String? }

    @discardableResult
    public func logIn(email: String, password: String) async throws -> String {
        let id = identity.identity()
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "name", value: email),
            .init(name: "password", value: try signer.encrypt(password)),
            .init(name: "deviceId", value: id.deviceId),
            .init(name: "singleId", value: id.singleId),
        ]
        let form = comps.percentEncodedQuery ?? ""

        var req = URLRequest(url: baseURL.appendingPathComponent("/cloud/v2/auth/login"))
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try signer.signature(), forHTTPHeaderField: "signature")
        req.httpBody = Data(form.utf8)

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch let e as URLError { throw GoodCloudError.transport(e) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoodCloudError.httpStatus(http.statusCode)
        }
        // Envelope: non-zero code -> .api (covers bad credentials)
        let envelope: APIResponse<LoginInfo>
        do { envelope = try JSONDecoder().decode(APIResponse<LoginInfo>.self, from: data) }
        catch { throw GoodCloudError.decoding("\(error)") }
        guard envelope.code == 0 else { throw GoodCloudError.api(code: envelope.code, message: envelope.msg) }

        // Token: prefer body, fall back to Set-Cookie: FE_TOKEN. (Exact body field verified on first live run.)
        let token = envelope.info?.token
            ?? Self.feTokenFromSetCookie((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        guard let token, !token.isEmpty else {
            throw GoodCloudError.decoding("login succeeded but no FE_TOKEN in body or Set-Cookie")
        }
        try credentials.save(Credentials(account: email, refreshToken: token))
        return token
    }

    public func currentToken() throws -> String? { try credentials.load()?.refreshToken }
    public func logOut() throws { try credentials.delete() }

    static func feTokenFromSetCookie(_ header: String?) -> String? {
        guard let header else { return nil }
        // "FE_TOKEN=value; Domain=...; Path=/"
        for part in header.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("FE_TOKEN=") { return String(kv.dropFirst("FE_TOKEN=".count)) }
        }
        return nil
    }
}

public struct PasswordTokenProvider: TokenProvider {
    private let auth: GoodCloudAuth
    public init(auth: GoodCloudAuth) { self.auth = auth }
    public func token() async throws -> String {
        guard let t = try await auth.currentToken() else { throw GoodCloudError.authFailed }
        return t
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter GoodCloudAuthTests`
Expected: PASS (3 tests). Warning-free build.

- [ ] **Step 5: Commit**

```bash
cd ~/src/goodcloudkit && git add Sources/GoodCloudKit/GoodCloudAuth.swift Tests/GoodCloudKitTests/GoodCloudAuthTests.swift
git commit -m "feat: password login (/cloud/v2/auth/login) + PasswordTokenProvider"
```

---

### Task 4: Relay consumption (capture gl-rtty-token + RelayHTTPClient)

**Files:**
- Modify: `Sources/GoodCloudKit/SignedAPIClient.swift` (surface response headers to callers)
- Modify: `Sources/GoodCloudKit/RemoteAccessSession.swift` (add `relayToken`)
- Modify: `Sources/GoodCloudKit/SignedAPIClient+RemoteAccess.swift` (capture `gl-rtty-token`)
- Create: `Sources/GoodCloudKit/RelayHTTPClient.swift`
- Test: `Tests/GoodCloudKitTests/RelayHTTPClientTests.swift`

**Interfaces:**
- Consumes: `SignedAPIClient`, `RemoteAccessSession` (wire).
- Produces:
  - `RemoteAccessSession` gains `let relayToken: String?`.
  - `SignedAPIClient` internal `func send(...)` also captures the response and, in `remoteAccess`, extracts `gl-rtty-token` from `Set-Cookie` into the session.
  - `struct RelayHTTPClient: Sendable` with
    `init(session: RemoteAccessSession, urlSession: URLSession = .shared)`,
    `func url(forTargetPath path: String) throws -> URL` (builds the relay URL for a target sub-path),
    `func get(_ path: String) async throws -> (Data, HTTPURLResponse)` (attaches `Cookie: gl-rtty-token=…`).

- [ ] **Step 1: Write the failing test**

```swift
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

    func test_get_attachesGlRttyTokenCookie() async throws {
        let captured = CapturedBox()
        StubURLProtocol.handler = { req in captured.set(req)
            return .init(status: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:]) }
        let s = session(relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F", token: "RT-TOK")
        let c = RelayHTTPClient(session: s, urlSession: StubURLProtocol.session())
        _ = try await c.get("status")
        XCTAssertEqual(captured.value?.value(forHTTPHeaderField: "Cookie"), "gl-rtty-token=RT-TOK")
    }

    func test_get_throwsWhenNoRelayToken() async {
        let s = session(relayBase: "https://x.goodcloud.xyz/web/d/http/127.0.0.1%3A80%2F", token: nil)
        let c = RelayHTTPClient(session: s, urlSession: StubURLProtocol.session())
        do { _ = try await c.get(""); XCTFail() } catch { XCTAssertEqual(error as? GoodCloudError, .relayUnavailable) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter RelayHTTPClientTests`
Expected: FAIL — `RelayHTTPClient` / `relayToken` not defined.

- [ ] **Step 3: Add `relayToken` to RemoteAccessSession**

In `RemoteAccessSession.swift` add `public let relayToken: String?` (and include it in the initializer, defaulting to `nil` for source compatibility).

- [ ] **Step 4: Capture gl-rtty-token in provisioning**

In `SignedAPIClient.swift`, change the private `send` to also return the `HTTPURLResponse` to internal callers (add an internal `sendReturningResponse` that the public `get`/`post` wrap, discarding the response). In `SignedAPIClient+RemoteAccess.swift`, use `sendReturningResponse`, read `Set-Cookie`, extract `gl-rtty-token` via the same cookie-parsing helper style as `GoodCloudAuth.feTokenFromSetCookie` (add a small shared `HTTPCookieHeader.value(named:in:)` util in a new `Sources/GoodCloudKit/CookieHeader.swift`, and use it in both places — DRY), and set it on the returned `RemoteAccessSession`.

```swift
// CookieHeader.swift
enum CookieHeader {
    /// Extract a cookie value by name from one or more Set-Cookie header strings.
    static func value(named name: String, in setCookie: String?) -> String? {
        guard let setCookie else { return nil }
        let prefix = name + "="
        for cookie in setCookie.components(separatedBy: ",") {
            for part in cookie.split(separator: ";") {
                let kv = part.trimmingCharacters(in: .whitespaces)
                if kv.hasPrefix(prefix) { return String(kv.dropFirst(prefix.count)) }
            }
        }
        return nil
    }
}
```
(Refactor `GoodCloudAuth.feTokenFromSetCookie` to call `CookieHeader.value(named: "FE_TOKEN", in:)`.)

- [ ] **Step 5: Write RelayHTTPClient**

```swift
// RelayHTTPClient.swift
import Foundation

public struct RelayHTTPClient: Sendable {
    private let session: RemoteAccessSession
    private let urlSession: URLSession
    public init(session: RemoteAccessSession, urlSession: URLSession = .shared) {
        self.session = session; self.urlSession = urlSession
    }

    /// Build the relay URL for a target sub-path. The relay path is
    /// `/web/<ddns>/<proto>/<percent-encoded "host:port/<path>">`; the target host:port + path
    /// live percent-encoded in the LAST path segment, so we decode it, append, and re-encode.
    public func url(forTargetPath path: String) throws -> URL {
        let base = session.baseURL
        // Split off the last (encoded target) segment.
        var comps = base.pathComponents.filter { $0 != "/" }   // ["web","<ddns>","<proto>","<encoded target>"]
        guard comps.count >= 4, let scheme = base.scheme, let host = base.host else {
            throw GoodCloudError.relayUnavailable
        }
        let encodedTarget = comps.removeLast()
        let decodedTarget = encodedTarget.removingPercentEncoding ?? encodedTarget  // "host:port/"
        let cleanBase = decodedTarget.hasSuffix("/") ? decodedTarget : decodedTarget + "/"
        let full = cleanBase + path                                                  // "host:port/status"
        let allowed = CharacterSet.alphanumerics                                      // encode ':' and '/'
        let reencoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? full
        let prefix = comps.map { "/" + $0 }.joined()                                  // "/web/<ddns>/<proto>"
        guard let url = URL(string: "\(scheme)://\(host)\(prefix)/\(reencoded)") else {
            throw GoodCloudError.relayUnavailable
        }
        return url
    }

    public func get(_ targetPath: String) async throws -> (Data, HTTPURLResponse) {
        guard let token = session.relayToken, !token.isEmpty else { throw GoodCloudError.relayUnavailable }
        var req = URLRequest(url: try url(forTargetPath: targetPath))
        req.httpShouldHandleCookies = false
        req.setValue("gl-rtty-token=\(token)", forHTTPHeaderField: "Cookie")
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GoodCloudError.relayUnavailable }
            return (data, http)
        } catch let e as URLError { throw GoodCloudError.transport(e) }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter RelayHTTPClientTests` then full `swift test`.
Expected: PASS. Warning-free build. (Fix the existing RemoteAccess provisioning test if the initializer changed — add `relayToken:` where constructed, or rely on the default.)

- [ ] **Step 7: Commit**

```bash
cd ~/src/goodcloudkit && git add Sources/GoodCloudKit Tests/GoodCloudKitTests
git commit -m "feat: relay consumption — capture gl-rtty-token + RelayHTTPClient"
```

---

### Task 5: Example app (SwiftUI, SPM executable)

**Files:**
- Modify: `Package.swift` (add an `.executable` product + `.executableTarget` "GoodCloudExample" depending on "GoodCloudKit")
- Create: `Sources/GoodCloudExample/GoodCloudExampleApp.swift`

**Interfaces:**
- Consumes: the full public API (`GoodCloudAuth`, `PasswordTokenProvider`, `SignedAPIClient`, `devices()`, `remoteAccess`, `RelayHTTPClient`).
- Produces: a runnable macOS SwiftUI app demonstrating login → devices → relay GET. No unit tests (demo); it must **compile** (`swift build`).

- [ ] **Step 1: Add the executable target to Package.swift**

```swift
products: [
    .library(name: "GoodCloudKit", targets: ["GoodCloudKit"]),
    .executable(name: "GoodCloudExample", targets: ["GoodCloudExample"]),
],
targets: [
    .target(name: "GoodCloudKit"),
    .executableTarget(name: "GoodCloudExample", dependencies: ["GoodCloudKit"]),
    .testTarget(name: "GoodCloudKitTests", dependencies: ["GoodCloudKit"]),
]
```

- [ ] **Step 2: Write the SwiftUI app**

```swift
import SwiftUI
import GoodCloudKit

@main
struct GoodCloudExampleApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class Model: ObservableObject {
    @Published var status = "Not logged in"
    @Published var devices: [GoodCloudDevice] = []
    @Published var relayOutput = ""
    private let auth = GoodCloudAuth()

    func logIn(email: String, password: String) async {
        do {
            _ = try await auth.logIn(email: email, password: password)
            status = "Logged in"
        } catch { status = "Login failed: \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")" }
    }

    private func client() -> SignedAPIClient { SignedAPIClient(tokens: PasswordTokenProvider(auth: auth)) }

    func loadDevices() async {
        do { devices = try await client().devices() }
        catch { status = "Devices failed: \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")" }
    }

    /// Provision a relay to the device's admin (:80) and GET the root through it.
    func probeRelay(_ device: GoodCloudDevice, port: Int) async {
        do {
            let s = try await client().remoteAccess(deviceID: device.id, kind: .web, protocol: .http, port: port)
            let (data, resp) = try await RelayHTTPClient(session: s).get("")
            relayOutput = "HTTP \(resp.statusCode), \(data.count) bytes from \(device.name):\(port)"
        } catch { relayOutput = "Relay failed: \((error as? GoodCloudError)?.redactedDescription ?? "\(error)")" }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var email = ""; @State private var password = ""; @State private var port = "80"
    var body: some View {
        Form {
            Section("Login") {
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                Button("Log In") { Task { await model.logIn(email: email, password: password) } }
                Text(model.status).font(.footnote)
            }
            Section("Devices") {
                Button("Load Devices") { Task { await model.loadDevices() } }
                ForEach(model.devices) { d in
                    HStack {
                        Text("\(d.name) — \(d.isOnline ? "online" : "offline")")
                        Spacer()
                        TextField("port", text: $port).frame(width: 60)
                        Button("Relay") { Task { await model.probeRelay(d, port: Int(port) ?? 80) } }
                            .disabled(!d.isOnline)
                    }
                }
                if !model.relayOutput.isEmpty { Text(model.relayOutput).font(.footnote) }
            }
        }
        .padding().frame(width: 460, height: 520)
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `cd ~/src/goodcloudkit && swift build`
Expected: `Build complete!`, zero warnings. (This proves the public API wires together; live run requires real credentials + an online device.)

- [ ] **Step 4: Commit**

```bash
cd ~/src/goodcloudkit && git add Package.swift Sources/GoodCloudExample
git commit -m "feat: SwiftUI example app (login -> devices -> relay probe)"
```

---

## Verify on first live run (documented, not code)

- **Login response token field** — Task 3 reads `info.token` OR `Set-Cookie: FE_TOKEN`. Confirm which the server actually returns for `/cloud/v2/auth/login`; adjust `LoginInfo`/extraction if the field differs. Also confirm whether `/cloud/v2/auth/login` is enabled server-side (bundle-present but the web UI uses SSO); if disabled, fall back to the WKWebView SSO + `login/code` path (documented in the recon contract §6b option 2).
- **Relay sub-path** — Task 4 assumes a provisioned session serves arbitrary target sub-paths under the chosen host:port. Confirm `.../http/127.0.0.1%3A8377%2Fstatus` reaches Wattline's `/status` after provisioning port 8377.
- **Refresh token** — if login returns a refresh token, persist and use it for silent re-auth (add to `GoodCloudAuth` once observed).

## Self-Review

**Spec coverage:** login (§6b option 1) → Tasks 1-3; relay consumption (§5b) → Task 4; example app → Task 5. WKWebView SSO (§6b option 2) intentionally not built (user chose in-app fields; SSO is a documented fallback).

**Placeholder scan:** No TBD/TODO in code. The two genuine unknowns (login token field, relay sub-path) are handled defensively in code AND listed under "Verify on first live run" — concrete behavior with a flagged verification point, not placeholders.

**Type consistency:** `RequestSigner.encrypt`, `DeviceIdentity`/`DeviceIdentityStore`, `GoodCloudAuth.logIn/currentToken`, `PasswordTokenProvider.token`, `RemoteAccessSession.relayToken`, `RelayHTTPClient.get/url`, `CookieHeader.value` are used consistently across tasks. `RemoteAccessSession`'s new `relayToken` defaults to `nil` so the Task-5 wire-layer initializer call sites still compile.
