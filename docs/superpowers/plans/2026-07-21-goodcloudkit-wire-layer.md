# GoodCloudKit Wire Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the verified GoodCloud API surface into `GoodCloudKit`: request signing, the signed HTTP client, device enumeration, and remote-access (rtty) provisioning — enough to authenticate (with a supplied token), list devices, and obtain a working relay URL for any router LAN port.

**Architecture:** A `RequestSigner` reproduces GoodCloud's verified `signature` (RSA-PKCS1v1.5-encrypted timestamp). A `SignedAPIClient` actor injects the `token` + `signature` headers on every call to `https://api.goodcloud.xyz`, decodes the uniform `{code,msg,info}` envelope, and surfaces typed errors. On top of it, `devices()` enumerates bound routers and `remoteAccess(...)` provisions an rtty session, returning a relay base URL. Token acquisition is abstracted behind a `TokenProvider` (a `StaticTokenProvider` ships now; the OIDC login provider is a deferred follow-up).

**Tech Stack:** Swift 5.9 SPM; Foundation `URLSession`; **Security** framework (`SecKeyCreateEncryptedData`, `.rsaEncryptionPKCS1`); XCTest with a `URLProtocol` stub. Builds on the merged Phase-1 scaffolding (`GoodCloudError`, `SecretRedactor`, `CredentialStore`).

## Global Constraints

- Module `GoodCloudKit`; platforms iOS 17 / macOS 14; Foundation + Security only, no third-party deps.
- API base URL: `https://api.goodcloud.xyz`. Response envelope: `{ "code": Int, "msg": String, "info": <T?> }`; `code == 0` = success.
- Every API request sends headers: `token` (the session token, verbatim), `signature`, `Accept: application/json`, and `Content-Type: application/json` on POSTs. Auth is header-based — requests use `credentials: omit` semantics (do NOT attach cookies).
- `signature = base64( RSA_PKCS1v1_5_encrypt( <embedded 512-bit public key>, String(currentEpochMillis) ) )`. Non-deterministic (random PKCS#1 v1.5 padding).
- Embedded RSA public key, **PKCS#1 (RSAPublicKey) DER, base64** (ready for `SecKeyCreateWithData` with `kSecAttrKeyTypeRSA`/`kSecAttrKeyClassPublic`):
  `MEgCQQCLaEfJawWf2WiWd1774D/CN9SJmk8GxD8zxJZiGQGrFqAM8NyJ6jFcni+605RUt0xc9xzCgZ6xZa+OtwbtfU89AgMBAAE=`
- rtty provisioning: `POST /cloud-api/cloud/device/v4/{deviceId}/rtty/run` with **query** params
  `enable=true&ip=127.0.0.1&port=<port>&protocol=<http|https>&rtty_type=<web|ssh>&web=true`, empty body.
- Concurrency: `actor`-based client, `Sendable` value types, async/await throughout.
- Secrets (token, signature) never logged; reuse `SecretRedactor` where anything is logged.

---

### Task 1: RequestSigner (RSA-PKCS1v1.5 signature)

**Files:**
- Create: `Sources/GoodCloudKit/RequestSigner.swift`
- Test: `Tests/GoodCloudKitTests/RequestSignerTests.swift`

**Interfaces:**
- Produces:
  - `struct RequestSigner: Sendable` with
    `init(publicKeyPKCS1DER: Data, now: @escaping @Sendable () -> Date = { Date() })`,
    `static func goodCloud(now: @escaping @Sendable () -> Date = { Date() }) -> RequestSigner`,
    and `func signature() throws -> String`.
- Adds `GoodCloudError` case `.signing(String)` (Task 1 also modifies `GoodCloudError.swift`).

- [ ] **Step 1: Add the error case**

Modify `Sources/GoodCloudKit/GoodCloudError.swift`: add `case signing(String)` to the enum and a
`case .signing(let m): return "signing error: \(m)"` arm in `redactedDescription`.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import Security
@testable import GoodCloudKit

final class RequestSignerTests: XCTestCase {
    // Generate a throwaway RSA keypair; sign with its public key; decrypt with the
    // private key to prove the PKCS#1 v1.5 encryption + base64 encoding are correct.
    func test_signature_decryptsBackToInjectedTimestamp() throws {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err)!
        let pub = SecKeyCopyPublicKey(priv)!
        let pubDER = SecKeyCopyExternalRepresentation(pub, &err)! as Data // PKCS#1 for RSA

        let fixed = Date(timeIntervalSince1970: 1_700_000_000) // -> 1700000000000 ms
        let signer = RequestSigner(publicKeyPKCS1DER: pubDER, now: { fixed })
        let sig = try signer.signature()

        let ct = Data(base64Encoded: sig)!
        let pt = SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, ct as CFData, &err)! as Data
        XCTAssertEqual(String(data: pt, encoding: .utf8), "1700000000000")
    }

    func test_goodCloudSigner_producesNonDeterministic88CharBase64Of64Bytes() throws {
        let signer = RequestSigner.goodCloud()
        let a = try signer.signature()
        let b = try signer.signature()
        XCTAssertEqual(a.count, 88)                    // 64-byte block, base64
        XCTAssertEqual(Data(base64Encoded: a)?.count, 64)
        XCTAssertNotEqual(a, b)                          // random PKCS#1 v1.5 padding
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter RequestSignerTests`
Expected: FAIL — `RequestSigner` not defined.

- [ ] **Step 4: Write the implementation**

```swift
import Foundation
import Security

/// Reproduces GoodCloud's `signature` header:
/// base64( RSA/PKCS1v1.5-encrypt( pubkey, String(currentEpochMillis) ) ).
public struct RequestSigner: Sendable {
    private let publicKeyPKCS1DER: Data
    private let now: @Sendable () -> Date

    public init(publicKeyPKCS1DER: Data, now: @escaping @Sendable () -> Date = { Date() }) {
        self.publicKeyPKCS1DER = publicKeyPKCS1DER
        self.now = now
    }

    /// The embedded GoodCloud web-client RSA public key (PKCS#1 RSAPublicKey DER, base64).
    /// 512-bit, e=65537 — a public client key, safe to embed. See docs/signature-re.md.
    public static func goodCloud(now: @escaping @Sendable () -> Date = { Date() }) -> RequestSigner {
        let der = Data(base64Encoded:
            "MEgCQQCLaEfJawWf2WiWd1774D/CN9SJmk8GxD8zxJZiGQGrFqAM8NyJ6jFcni+605RUt0xc9xzCgZ6xZa+OtwbtfU89AgMBAAE="
        )!
        return RequestSigner(publicKeyPKCS1DER: der, now: now)
    }

    public func signature() throws -> String {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(publicKeyPKCS1DER as CFData, attrs as CFDictionary, &error) else {
            throw GoodCloudError.signing("invalid public key: \(errString(error))")
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionPKCS1) else {
            throw GoodCloudError.signing("PKCS1 encryption unsupported for key")
        }
        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let plaintext = Data(String(millis).utf8)
        guard let ct = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plaintext as CFData, &error) else {
            throw GoodCloudError.signing("encrypt failed: \(errString(error))")
        }
        return (ct as Data).base64EncodedString()
    }

    private func errString(_ e: Unmanaged<CFError>?) -> String {
        guard let e else { return "unknown" }
        return CFErrorCopyDescription(e.takeRetainedValue()) as String? ?? "unknown"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter RequestSignerTests`
Expected: PASS (2 tests). Also `swift build` warning-free.

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/RequestSigner.swift Sources/GoodCloudKit/GoodCloudError.swift Tests/GoodCloudKitTests/RequestSignerTests.swift
git commit -m "feat: RequestSigner (RSA-PKCS1v1.5 signature) + GoodCloudError.signing"
```

---

### Task 2: API response envelope + error mapping

**Files:**
- Create: `Sources/GoodCloudKit/APIResponse.swift`
- Modify: `Sources/GoodCloudKit/GoodCloudError.swift` (add `.api` case)
- Test: `Tests/GoodCloudKitTests/APIResponseTests.swift`

**Interfaces:**
- Produces:
  - `struct APIResponse<Info: Decodable & Sendable>: Decodable, Sendable { let code: Int; let msg: String; let info: Info? }`
  - `extension APIResponse { func unwrap() throws -> Info }` — returns `info` when `code == 0`, else throws.
  - `GoodCloudError` case `.api(code: Int, message: String)`.

- [ ] **Step 1: Add the error case**

Modify `GoodCloudError.swift`: add `case api(code: Int, message: String)` and arm
`case .api(let c, _): return "api error (code \(c))"` (message omitted from the redacted line —
it may echo server text; the code is enough to log).

- [ ] **Step 2: Write the failing test**

```swift
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
        XCTAssertThrowsError(try r.unwrap())
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter APIResponseTests`
Expected: FAIL — `APIResponse` not defined.

- [ ] **Step 4: Write the implementation**

```swift
import Foundation

public struct APIResponse<Info: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let msg: String
    public let info: Info?

    /// Returns `info` when the call succeeded (`code == 0`); otherwise throws a typed error.
    public func unwrap() throws -> Info {
        guard code == 0 else { throw GoodCloudError.api(code: code, message: msg) }
        guard let info else { throw GoodCloudError.decoding("code 0 but info was null") }
        return info
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter APIResponseTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/APIResponse.swift Sources/GoodCloudKit/GoodCloudError.swift Tests/GoodCloudKitTests/APIResponseTests.swift
git commit -m "feat: APIResponse envelope + GoodCloudError.api mapping"
```

---

### Task 3: TokenProvider + SignedAPIClient

**Files:**
- Create: `Sources/GoodCloudKit/TokenProvider.swift`
- Create: `Sources/GoodCloudKit/SignedAPIClient.swift`
- Create: `Tests/GoodCloudKitTests/StubURLProtocol.swift`
- Test: `Tests/GoodCloudKitTests/SignedAPIClientTests.swift`

**Interfaces:**
- Consumes: `RequestSigner` (Task 1), `APIResponse` (Task 2).
- Produces:
  - `protocol TokenProvider: Sendable { func token() async throws -> String }`
  - `struct StaticTokenProvider: TokenProvider { init(_ token: String) }`
  - `actor SignedAPIClient` with
    `init(baseURL: URL, session: URLSession, signer: RequestSigner, tokens: TokenProvider)`
    (defaults: `baseURL = https://api.goodcloud.xyz`, `session = .shared`, `signer = .goodCloud()`),
    and
    `func get<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem], as: Info.Type) async throws -> Info`
    `func post<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem], body: Data?, as: Info.Type) async throws -> Info`.

- [ ] **Step 1: Write the URLProtocol stub (test support)**

```swift
import Foundation

/// Test-only URLProtocol that returns a canned response per request.
final class StubURLProtocol: URLProtocol {
    struct Stub { let status: Int; let data: Data; let headers: [String: String] }
    /// Set before each test. Receives the outgoing request (for assertions) and returns a stub.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("StubURLProtocol.handler not set") }
        let stub = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing test**

```swift
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
}

/// Thread-safe one-shot box so the @Sendable handler can hand the request back to the test.
final class CapturedBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v: URLRequest?
    func set(_ r: URLRequest) { lock.lock(); _v = r; lock.unlock() }
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return _v }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter SignedAPIClientTests`
Expected: FAIL — `SignedAPIClient` / `TokenProvider` not defined.

- [ ] **Step 4: Write TokenProvider**

```swift
// TokenProvider.swift
import Foundation

public protocol TokenProvider: Sendable {
    func token() async throws -> String
}

/// A fixed token (e.g. an FE_TOKEN obtained out-of-band). The OIDC login provider is separate.
public struct StaticTokenProvider: TokenProvider {
    private let value: String
    public init(_ token: String) { self.value = token }
    public func token() async throws -> String { value }
}
```

- [ ] **Step 5: Write SignedAPIClient**

```swift
// SignedAPIClient.swift
import Foundation

public actor SignedAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let signer: RequestSigner
    private let tokens: TokenProvider

    public init(baseURL: URL = URL(string: "https://api.goodcloud.xyz")!,
                session: URLSession = .shared,
                signer: RequestSigner = .goodCloud(),
                tokens: TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.signer = signer
        self.tokens = tokens
    }

    public func get<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                                as type: Info.Type) async throws -> Info {
        try await send(method: "GET", path: path, query: query, body: nil, as: type)
    }

    public func post<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                                 body: Data? = nil, as type: Info.Type) async throws -> Info {
        try await send(method: "POST", path: path, query: query, body: body, as: type)
    }

    private func send<Info: Decodable & Sendable>(method: String, path: String,
                                                  query: [URLQueryItem], body: Data?,
                                                  as type: Info.Type) async throws -> Info {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GoodCloudError.decoding("bad url for \(path)") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try await tokens.token(), forHTTPHeaderField: "token")
        req.setValue(try signer.signature(), forHTTPHeaderField: "signature")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch let e as URLError {
            throw GoodCloudError.transport(e)
        }

        do {
            let envelope = try JSONDecoder().decode(APIResponse<Info>.self, from: data)
            return try envelope.unwrap()
        } catch let e as GoodCloudError {
            throw e
        } catch {
            throw GoodCloudError.decoding("\(error)")
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter SignedAPIClientTests`
Expected: PASS (2 tests). Also run full `swift test` and confirm warning-free `swift build`.

- [ ] **Step 7: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/TokenProvider.swift Sources/GoodCloudKit/SignedAPIClient.swift Tests/GoodCloudKitTests/StubURLProtocol.swift Tests/GoodCloudKitTests/SignedAPIClientTests.swift
git commit -m "feat: TokenProvider + SignedAPIClient (token+signature headers, envelope decode)"
```

---

### Task 4: Device model + enumeration

**Files:**
- Create: `Sources/GoodCloudKit/GoodCloudDevice.swift`
- Create: `Sources/GoodCloudKit/SignedAPIClient+Devices.swift`
- Test: `Tests/GoodCloudKitTests/DevicesTests.swift`

**Interfaces:**
- Consumes: `SignedAPIClient` (Task 3).
- Produces:
  - `struct GoodCloudDevice: Decodable, Sendable, Identifiable, Equatable` with
    `id: String, name: String, mac: String, ddns: String?, model: String, status: Int,
     networkMode: String?, rttyWeb: String?, rttySsh: String?` and `var isOnline: Bool { status == 1 }`.
  - `extension SignedAPIClient { func devices(page: Int = 1, pageSize: Int = 100) async throws -> [GoodCloudDevice] }`
    (GET `/cloud-api/cloud/v2/device`, reads `info.rows`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import GoodCloudKit

final class DevicesTests: XCTestCase {
    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

    func test_devices_decodesRowsAndOnlineFlag() async throws {
        let json = """
        {"code":0,"msg":"Success.","info":{"all_count":2,"online_count":1,"total":2,"rows":[
          {"id":"100000001","name":"Mudi7","mac":"aabbccddeeff","ddns":"demo01","model":"e5800",
           "status":1,"network_mode":"router","rtty_web":"1","rtty_ssh":"1"},
          {"id":"111","name":"Tesla","mac":"001122334455","ddns":"tsla","model":"x3000",
           "status":0,"network_mode":"router","rtty_web":"1","rtty_ssh":"1"}
        ]}}
        """
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/cloud-api/cloud/v2/device")
            return .init(status: 200, data: Data(json.utf8), headers: [:])
        }
        let client = SignedAPIClient(session: StubURLProtocol.session(), tokens: StaticTokenProvider("t"))
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].id, "100000001")
        XCTAssertEqual(devices[0].ddns, "demo01")
        XCTAssertTrue(devices[0].isOnline)
        XCTAssertFalse(devices[1].isOnline)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter DevicesTests`
Expected: FAIL — `GoodCloudDevice` / `devices()` not defined.

- [ ] **Step 3: Write the model**

```swift
// GoodCloudDevice.swift
import Foundation

public struct GoodCloudDevice: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let mac: String
    public let ddns: String?
    public let model: String
    public let status: Int
    public let networkMode: String?
    public let rttyWeb: String?
    public let rttySsh: String?

    public var isOnline: Bool { status == 1 }

    enum CodingKeys: String, CodingKey {
        case id, name, mac, ddns, model, status
        case networkMode = "network_mode"
        case rttyWeb = "rtty_web"
        case rttySsh = "rtty_ssh"
    }
}
```

- [ ] **Step 4: Write the enumeration**

```swift
// SignedAPIClient+Devices.swift
import Foundation

extension SignedAPIClient {
    private struct DeviceListInfo: Decodable, Sendable {
        let rows: [GoodCloudDevice]
    }

    /// Bound routers for the current account (GET /cloud-api/cloud/v2/device).
    public func devices(page: Int = 1, pageSize: Int = 100) async throws -> [GoodCloudDevice] {
        let info = try await get("/cloud-api/cloud/v2/device", query: [
            URLQueryItem(name: "pageNum", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ], as: DeviceListInfo.self)
        return info.rows
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter DevicesTests`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/GoodCloudDevice.swift Sources/GoodCloudKit/SignedAPIClient+Devices.swift Tests/GoodCloudKitTests/DevicesTests.swift
git commit -m "feat: GoodCloudDevice model + devices() enumeration"
```

---

### Task 5: Remote-access (rtty) provisioning

**Files:**
- Create: `Sources/GoodCloudKit/RemoteAccessSession.swift`
- Create: `Sources/GoodCloudKit/SignedAPIClient+RemoteAccess.swift`
- Test: `Tests/GoodCloudKitTests/RemoteAccessTests.swift`

**Interfaces:**
- Consumes: `SignedAPIClient` (Task 3), `GoodCloudDevice` (Task 4).
- Produces:
  - `enum RelayProtocol: String, Sendable { case http, https }`
  - `enum RelayKind: String, Sendable { case web, ssh }`
  - `struct RemoteAccessSession: Sendable { let baseURL: URL; let tokenDomain: String; let sessionID: String?; let issuedAtMillis: Int64? }`
  - `extension SignedAPIClient { func remoteAccess(deviceID: String, kind: RelayKind = .web, protocol: RelayProtocol = .http, ip: String = "127.0.0.1", port: Int = 80) async throws -> RemoteAccessSession }`

- [ ] **Step 1: Write the failing test**

```swift
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
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter RemoteAccessTests`
Expected: FAIL — `remoteAccess` / `RemoteAccessSession` not defined.

- [ ] **Step 3: Write the model**

```swift
// RemoteAccessSession.swift
import Foundation

public enum RelayProtocol: String, Sendable { case http, https }
public enum RelayKind: String, Sendable { case web, ssh }

/// A provisioned rtty relay session. `baseURL` proxies HTTP(S) to the chosen router LAN target.
/// NOTE: the session is time-bound and (per recon) served behind a `.goodcloud.xyz` cookie;
/// consuming it from a native HTTP client — carrying that auth and handling expiry/redirect to
/// the rttys web host — is the deferred consumption task (see the plan's Deferred section).
public struct RemoteAccessSession: Sendable {
    public let baseURL: URL
    public let tokenDomain: String
    public let sessionID: String?
    public let issuedAtMillis: Int64?
}
```

- [ ] **Step 4: Write the provisioning call**

```swift
// SignedAPIClient+RemoteAccess.swift
import Foundation

extension SignedAPIClient {
    private struct RttyRunInfo: Decodable, Sendable {
        let token_domain: String
        let url: String
        struct Content: Decodable, Sendable { let id: String?; let time: Int64? }
        let content: Content?
    }

    /// Provision an rtty relay to a device's LAN target and return the relay base URL.
    /// `port`/`protocol`/`ip` select the LAN service (e.g. port 8377 for Wattline).
    public func remoteAccess(deviceID: String,
                             kind: RelayKind = .web,
                             protocol proto: RelayProtocol = .http,
                             ip: String = "127.0.0.1",
                             port: Int = 80) async throws -> RemoteAccessSession {
        let info = try await post("/cloud-api/cloud/device/v4/\(deviceID)/rtty/run", query: [
            URLQueryItem(name: "enable", value: "true"),
            URLQueryItem(name: "ip", value: ip),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "protocol", value: proto.rawValue),
            URLQueryItem(name: "rtty_type", value: kind.rawValue),
            URLQueryItem(name: "web", value: "true"),
        ], body: nil, as: RttyRunInfo.self)

        guard let url = URL(string: info.url) else {
            throw GoodCloudError.decoding("rtty/run returned an invalid relay url")
        }
        return RemoteAccessSession(baseURL: url,
                                   tokenDomain: info.token_domain,
                                   sessionID: info.content?.id,
                                   issuedAtMillis: info.content?.time)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/src/goodcloudkit && swift test --filter RemoteAccessTests`
Expected: PASS (1 test). Run full `swift test`; confirm warning-free `swift build`.

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/RemoteAccessSession.swift Sources/GoodCloudKit/SignedAPIClient+RemoteAccess.swift Tests/GoodCloudKitTests/RemoteAccessTests.swift
git commit -m "feat: remoteAccess() rtty provisioning -> relay base URL"
```

---

## Deferred to a follow-up plan (need a live spike first)

These have observed-but-not-fully-characterized behaviour; writing exact code now would be
guessing. Each needs a short live spike (the recon session confirmed the shape but not every
detail), then its own TDD tasks:

1. **Relay consumption auth + lifecycle.** How a native HTTP client (not a browser) authenticates
   to the rttys relay: the `.goodcloud.xyz` cookie vs. any token; the `rttys-ssh-*` → `rttys-web-*`
   redirect; session TTL and the `/gl-rtty/error.html` expiry sentinel; and a `renew()` that
   re-runs `rtty/run`. This is the last mile to actually pushing HTTP to Wattline through the relay.
2. **OIDC login `TokenProvider`.** Programmatic acquisition of `FE_TOKEN`: the Keycloak
   `goodcloud`-realm flow (client `goodcloud-web`) → `POST /cloud-basic/cloud/v3/auth/login/code`,
   persisted via the Phase-1 `CredentialStore`. Decide ROPC password grant vs.
   `ASWebAuthenticationSession` (the latter also enables Google/Apple SSO). Until this lands,
   consumers supply a token via `StaticTokenProvider`.

## Self-Review

**Spec coverage (against docs/goodcloud-remote-access.md):** §2 signing → Task 1; §1 envelope +
error mapping → Task 2; §2 `token`+`signature` header injection + header-based auth → Task 3; §3
device enumeration → Task 4; §4 rtty provisioning with exact params → Task 5. §5 relay consumption
and §2's OIDC login are explicitly deferred (genuine unknowns), not dropped.

**Placeholder scan:** No TBD/TODO. Every code step shows complete code; the Deferred section is a
scoped split with rationale, not an in-task placeholder.

**Type consistency:** `RequestSigner.signature()`, `APIResponse.unwrap()`, `TokenProvider.token()`,
`SignedAPIClient.get/post`, `devices()`, `remoteAccess(...)`, and the `GoodCloudDevice` CodingKeys
are used consistently across tasks. New `GoodCloudError` cases (`.signing`, `.api`) are added in the
tasks that first use them. Exact rtty/run query values match the verified contract.
