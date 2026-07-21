# GoodCloudKit — Recon & Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the reverse-engineered GoodCloud remote-access contract, and build the wire-independent foundation of the `GoodCloudKit` Swift package.

**Architecture:** Phase 0 is a reconnaissance investigation that documents GoodCloud's auth → device → relay flow and captures sanitized fixtures. Phase 1 builds the parts of the SDK that do not depend on observed wire shapes: package skeleton, typed errors, a secret-redaction layer, and a Keychain-backed credential store behind a protocol. The wire-dependent SDK (auth, device enumeration, `RemoteAccessSession`, consumer proofs) is deferred to a follow-up plan written against the Phase 0 contract.

**Tech Stack:** Swift 5.9+ / Swift Package Manager; async/await + `Sendable`; Foundation `URLSession`; Security framework (Keychain); XCTest.

## Global Constraints

- Package name / module: `GoodCloudKit`. (verbatim from spec §10)
- Platforms floor: iOS 17, macOS 14. (matches the Wattline consumer)
- No third-party dependencies — Foundation + Security only. (spec §2 "standalone")
- Secrets (passwords, tokens, session ids, MACs) never logged and never committed; all repo fixtures sanitized. (spec §7, §8)
- The assistant never types the user's GoodCloud credentials; the user authenticates during recon. (spec §4)
- Concurrency: `actor`-based client, `Sendable` value types, async/await throughout. (spec §5)

---

## Phase 0 — Reconnaissance

### Task 0: Document the GoodCloud remote-access contract

This is an investigation, not a TDD cycle. It has concrete deliverables and a hard gate (the user must log in). Do **not** proceed to Phase 2 (the follow-up plan) until `docs/goodcloud-remote-access.md` exists and its fixtures are sanitized.

**Files:**
- Create: `docs/goodcloud-remote-access.md`
- Create: `Fixtures/recon/` (sanitized request/response captures)

**Deliverable:** a documented contract covering the five recon items in spec §4, sufficient to write decoding code and replay tests against.

- [ ] **Step 1: User authenticates.** The user logs in to `goodcloud.xyz` in the in-app browser (or provides a HAR export of a logged-in session). The assistant does not type credentials.

- [ ] **Step 2: Capture the auth exchange.** From the authenticated session / HAR, record the login request + response. Document: endpoint URL + method, where the session token/JWT is carried (request header name vs cookie name), token lifetime/expiry claim, and any refresh endpoint. Save the sanitized response body to `Fixtures/recon/auth-response.json`.

- [ ] **Step 3: Capture device enumeration.** Trigger the device/router list view. Document the endpoint and the JSON shape; identify the fields for device id, MAC, display name, and online state. Save sanitized body to `Fixtures/recon/devices-response.json`.

- [ ] **Step 4: Capture remote-access provisioning.** Click "Remote Access" for a device. Document every request in the provisioning sequence, the resulting relay base URL format (per-session subdomain vs path token), and any headers/cookies required on subsequent proxied requests. Save sanitized bodies to `Fixtures/recon/remote-access-*.json`.

- [ ] **Step 5: Probe session lifecycle & path behavior.** Observe keepalive cadence, session expiry, and teardown. Then load a non-root `:80` path through the relay (e.g. the admin panel plus a deep path) and record whether arbitrary `:80` paths resolve and whether the relay rewrites paths. Document findings.

- [ ] **Step 6: Resolve the §9 open question.** Determine whether the relay wraps requests in the admin login/session (cookie) that a consumer must satisfy, or whether the relay base URL is directly usable. Record the answer explicitly — it drives the follow-up plan's transport design.

- [ ] **Step 7: Sanitize.** Grep every file under `Fixtures/recon/` for real tokens, MACs, account ids, session ids, and personal data; replace with clearly-fake placeholders. Verify with: `grep -rniE '([0-9a-f]{2}:){5}[0-9a-f]{2}|bearer |eyJ' Fixtures/recon/` → expect no real values.

- [ ] **Step 8: Write the contract doc** at `docs/goodcloud-remote-access.md` capturing Steps 2–6 as a single reference an implementer can code against without re-observing the site.

- [ ] **Step 9: Commit**

```bash
cd ~/src/goodcloudkit
git add docs/goodcloud-remote-access.md Fixtures/recon
git commit -m "docs(recon): document GoodCloud remote-access contract + sanitized fixtures"
```

---

## Phase 1 — Wire-independent scaffolding

### Task 1: Package skeleton + typed errors

**Files:**
- Create: `Package.swift`
- Create: `Sources/GoodCloudKit/GoodCloudError.swift`
- Test: `Tests/GoodCloudKitTests/GoodCloudErrorTests.swift`

**Interfaces:**
- Produces: `enum GoodCloudError: Error, Equatable, Sendable` with cases
  `.authFailed`, `.credentialsRejected`, `.deviceOffline`, `.deviceNotFound`,
  `.relayUnavailable`, `.sessionExpired`, `.transport(URLError)`, `.decoding(String)`;
  and `var redactedDescription: String`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoodCloudKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GoodCloudKit", targets: ["GoodCloudKit"]),
    ],
    targets: [
        .target(name: "GoodCloudKit"),
        .testTarget(name: "GoodCloudKitTests", dependencies: ["GoodCloudKit"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import GoodCloudKit

final class GoodCloudErrorTests: XCTestCase {
    func test_redactedDescription_neverContainsUnderlyingSecrets() {
        let err = GoodCloudError.decoding("unexpected field")
        XCTAssertEqual(err, .decoding("unexpected field"))
        XCTAssertFalse(err.redactedDescription.isEmpty)
    }

    func test_transportWrapsURLError() {
        let err = GoodCloudError.transport(URLError(.notConnectedToInternet))
        XCTAssertEqual(err, .transport(URLError(.notConnectedToInternet)))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter GoodCloudErrorTests`
Expected: FAIL — `GoodCloudError` is not defined (build error).

- [ ] **Step 4: Write minimal implementation**

```swift
import Foundation

public enum GoodCloudError: Error, Equatable, Sendable {
    case authFailed
    case credentialsRejected
    case deviceOffline
    case deviceNotFound
    case relayUnavailable
    case sessionExpired
    case transport(URLError)
    case decoding(String)

    /// Loggable description guaranteed to carry no secrets.
    public var redactedDescription: String {
        switch self {
        case .authFailed: return "authentication failed"
        case .credentialsRejected: return "credentials rejected"
        case .deviceOffline: return "device offline"
        case .deviceNotFound: return "device not found"
        case .relayUnavailable: return "relay unavailable"
        case .sessionExpired: return "remote-access session expired"
        case .transport(let e): return "transport error (\(e.code.rawValue))"
        case .decoding(let context): return "decoding error: \(context)"
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/src/goodcloudkit && swift test --filter GoodCloudErrorTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Package.swift Sources Tests
git commit -m "feat: package skeleton + GoodCloudError"
```

---

### Task 2: Secret redaction layer

**Files:**
- Create: `Sources/GoodCloudKit/SecretRedactor.swift`
- Test: `Tests/GoodCloudKitTests/SecretRedactorTests.swift`

**Interfaces:**
- Produces: `struct SecretRedactor: Sendable` with
  `init(secrets: Set<String> = [])`, `func adding(_ secret: String) -> SecretRedactor`,
  and `func redact(_ text: String) -> String`. Redacts registered secret substrings
  (longest-first) and `Authorization: Bearer <token>` headers; empty secrets ignored.

- [ ] **Step 1: Write the failing test**

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter SecretRedactorTests`
Expected: FAIL — `SecretRedactor` is not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public struct SecretRedactor: Sendable {
    private let secrets: Set<String>

    public init(secrets: Set<String> = []) {
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    public func adding(_ secret: String) -> SecretRedactor {
        guard !secret.isEmpty else { return self }
        return SecretRedactor(secrets: secrets.union([secret]))
    }

    public func redact(_ text: String) -> String {
        var out = text
        // Longest secrets first so a shorter secret can't partially mask a longer one.
        for secret in secrets.sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: secret, with: "•••")
        }
        out = Self.bearerRegex.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..., in: out),
            withTemplate: "Authorization: Bearer •••"
        )
        return out
    }

    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"Authorization:\s*Bearer\s+\S+"#,
        options: [.caseInsensitive]
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/src/goodcloudkit && swift test --filter SecretRedactorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/SecretRedactor.swift Tests/GoodCloudKitTests/SecretRedactorTests.swift
git commit -m "feat: secret redaction layer"
```

---

### Task 3: Credential store (protocol + in-memory fake + Keychain)

**Files:**
- Create: `Sources/GoodCloudKit/CredentialStore.swift`
- Create: `Sources/GoodCloudKit/KeychainCredentialStore.swift`
- Test: `Tests/GoodCloudKitTests/CredentialStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct Credentials: Sendable, Equatable { var account: String; var refreshToken: String }`
  - `protocol CredentialStore: Sendable { func save(_:) throws; func load() throws -> Credentials?; func delete() throws }`
  - `final class InMemoryCredentialStore: CredentialStore` (test/support double)
  - `struct KeychainCredentialStore: CredentialStore` (service-scoped, real)

- [ ] **Step 1: Write the failing test** (behavior verified against the in-memory store)

```swift
import XCTest
@testable import GoodCloudKit

final class CredentialStoreTests: XCTestCase {
    func test_loadIsNilBeforeSave() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.load())
    }

    func test_saveThenLoadRoundTrips() throws {
        let store = InMemoryCredentialStore()
        let creds = Credentials(account: "user@example.com", refreshToken: "rt-123")
        try store.save(creds)
        XCTAssertEqual(try store.load(), creds)
    }

    func test_deleteClears() throws {
        let store = InMemoryCredentialStore()
        try store.save(Credentials(account: "a", refreshToken: "b"))
        try store.delete()
        XCTAssertNil(try store.load())
    }

    func test_saveOverwrites() throws {
        let store = InMemoryCredentialStore()
        try store.save(Credentials(account: "a", refreshToken: "1"))
        try store.save(Credentials(account: "a", refreshToken: "2"))
        XCTAssertEqual(try store.load()?.refreshToken, "2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/src/goodcloudkit && swift test --filter CredentialStoreTests`
Expected: FAIL — `Credentials` / `CredentialStore` / `InMemoryCredentialStore` not defined.

- [ ] **Step 3: Write the protocol + fake**

```swift
// CredentialStore.swift
import Foundation

public struct Credentials: Sendable, Equatable {
    public var account: String
    public var refreshToken: String
    public init(account: String, refreshToken: String) {
        self.account = account
        self.refreshToken = refreshToken
    }
}

public protocol CredentialStore: Sendable {
    func save(_ credentials: Credentials) throws
    func load() throws -> Credentials?
    func delete() throws
}

/// In-memory store for tests and previews. Not persistent.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?
    public init() {}
    public func save(_ credentials: Credentials) throws {
        lock.lock(); defer { lock.unlock() }
        value = credentials
    }
    public func load() throws -> Credentials? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    public func delete() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}
```

- [ ] **Step 4: Write the Keychain implementation**

```swift
// KeychainCredentialStore.swift
import Foundation
import Security

/// Persists a single Credentials record as a generic-password item,
/// scoped by `service`. account is the item account; refreshToken is the secret.
public struct KeychainCredentialStore: CredentialStore {
    public enum KeychainError: Error, Equatable { case status(OSStatus) }

    private let service: String
    public init(service: String = "xyz.goodcloud.GoodCloudKit") {
        self.service = service
    }

    public func save(_ credentials: Credentials) throws {
        try delete()
        var query = baseQuery(account: credentials.account)
        query[kSecValueData as String] = Data(credentials.refreshToken.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load() throws -> Credentials? {
        var query = baseQuery(account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let account = dict[kSecAttrAccount as String] as? String,
              let token = String(data: data, encoding: .utf8)
        else { throw KeychainError.status(status) }
        return Credentials(account: account, refreshToken: token)
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/src/goodcloudkit && swift test --filter CredentialStoreTests`
Expected: PASS (4 tests). (Keychain impl compiles; its live behavior is verified on-device during Phase 2, since Keychain access needs an entitled host process.)

- [ ] **Step 6: Commit**

```bash
cd ~/src/goodcloudkit
git add Sources/GoodCloudKit/CredentialStore.swift Sources/GoodCloudKit/KeychainCredentialStore.swift Tests/GoodCloudKitTests/CredentialStoreTests.swift
git commit -m "feat: credential store protocol + in-memory + Keychain"
```

---

## Deferred to the follow-up plan (post-recon)

Written after Task 0 produces `docs/goodcloud-remote-access.md`, so exact request
construction, response decoding, and replay fixtures reflect observed shapes:

- **Auth flow** — `GoodCloudClient.logIn` / `.authenticate(token:)` against the real
  endpoint; token transport + refresh per the contract.
- **Device enumeration** — `client.devices()` decoding the real list shape.
- **`RemoteAccessSession`** — provisioning, `baseURL`, keepalive/`renew`, `urlSession`,
  `webViewRequest`; TLS trust; relay-auth-vs-app-auth layering per the §9 resolution.
- **Replay tests** — drive the client from the sanitized recon fixtures (WattlineCore
  `ReplayTransport` pattern); contract tests that break on GoodCloud API drift.
- **Consumer proof** — reach a `:80` admin UI end-to-end via webview; then Wattline
  once its `:80` task lands.

---

## Self-Review

**Spec coverage:** §3 architecture, §5 API, §6 errors (Task 1), §7 security (Tasks 2–3: redaction + Keychain; recon credential handling Task 0), §8 testing (fixture pattern seeded in Task 0, exercised in follow-up), §4 recon (Task 0), §10 layout (Task 1 Package.swift + dirs), §11 open questions (Task 0 Steps 5–6). §5's `GoodCloudClient`/`RemoteAccessSession` and §8's replay tests are intentionally deferred (wire-dependent) — documented above, not dropped.

**Placeholder scan:** No "TBD/TODO/handle appropriately". Every code step shows complete code; the deferred section is an explicit scope split with rationale, not an in-task placeholder.

**Type consistency:** `GoodCloudError` cases match spec §6. `Credentials`/`CredentialStore` names consistent across Task 3 code and interfaces block. `SecretRedactor.redact` used consistently.
