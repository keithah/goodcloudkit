# GoodCloudKit

A client-side Swift library for reaching **any HTTP service on a GL.iNet router remotely**,
through GL.iNet's [GoodCloud](https://www.goodcloud.xyz) relay — no VPN, no port-forwarding, no
changes to the router. Point it at the router's admin panel, or any app's HTTP API running on the
router (e.g. a custom daemon on `:8377`), from anywhere.

The GoodCloud remote-access protocol is undocumented; this library was reverse-engineered from the
GoodCloud web app and **verified end-to-end against a live account and router** (macOS). See
[`docs/goodcloud-remote-access.md`](docs/goodcloud-remote-access.md) for the full wire contract.

> **Unofficial.** Not affiliated with or endorsed by GL.iNet. Uses your own account and devices.

---

## What it does

```
GoodCloudAuth.logIn(email:password:)        // authenticate → FE_TOKEN (Keychain)
  → SignedAPIClient(tokens:)                 // signs every call (token + RSA signature)
      .devices()                             // list your bound routers
      .remoteAccess(deviceID:port:)          // provision an rtty relay to a LAN host:port
        → RelayHTTPClient.get(path)          // transparent HTTP to that service, from anywhere
```

Under the hood: password (or OIDC) login mints an `FE_TOKEN`; every API request carries `token` +
`signature` (an RSA-encrypted timestamp) headers; `remoteAccess` calls GoodCloud's `rtty/run` to
provision a relay session on GL's `rttys` server; `RelayHTTPClient` then does ordinary HTTP through
that relay (handling the `rttys-ssh → rttys-web` redirect and the `gl-rtty-token`/`rtty-http-sid`
cookies for you).

## Requirements

- Swift 5.9+, **iOS 17 / macOS 14**
- Dependencies: Foundation + Security only (no third-party packages)
- A GoodCloud account with at least one bound, online GL.iNet router

Verified on macOS. The code is cross-platform (iOS-only APIs are `#if os(iOS)`-guarded) but has not
been exercised on iOS device/simulator yet.

## Install (Swift Package Manager)

```swift
.package(url: "https://github.com/<you>/goodcloudkit.git", from: "0.1.0")
// target dependency: .product(name: "GoodCloudKit", package: "goodcloudkit")
```

## Quick start

```swift
import GoodCloudKit

let auth = GoodCloudAuth()
_ = try await auth.logIn(email: "you@example.com", password: "…")   // persists FE_TOKEN

let client = SignedAPIClient(tokens: PasswordTokenProvider(auth: auth))
let devices = try await client.devices()
guard let router = devices.first(where: { $0.isOnline }) else { return }

// Reach a service on the router's LAN (port 80 = admin UI; 8377 = your app's API, etc.)
let session = try await client.remoteAccess(deviceID: router.id, port: 8377)
let (data, response) = try await RelayHTTPClient(session: session).get("status")
print(response.statusCode, String(data: data, encoding: .utf8) ?? "")
```

Public surface: `GoodCloudAuth` (`logIn`, `logOut`, `logOutEverywhere`, `currentToken`),
`PasswordTokenProvider` / `TokenProvider`, `SignedAPIClient` (`devices`, `remoteAccess`, `get`,
`post`), `GoodCloudDevice`, `RemoteAccessSession`, `RelayHTTPClient`, `GoodCloudError`,
`RequestSigner`, `CredentialStore`/`KeychainCredentialStore`, `DeviceIdentity`.

---

## Sample app — “GoodCloud Tester” (macOS SwiftUI)

A small SwiftUI app that exercises the whole library: log in → browse devices → open a relay
console and issue live requests to a device.

**Run it:**

```bash
./run-app.sh          # builds a .app bundle (for proper window focus) and launches it
# or, from Xcode/CLI:  swift run GoodCloudExample
```

> `./run-app.sh` wraps the executable in a `.app` bundle because a bare `swift run` GUI process
> doesn't get a Dock icon or reliable keyboard focus on macOS.

**Screens:**
- **Login** — email + password (`SecureField`); shows redacted errors; auto-focuses email.
- **Devices** — cards with name, model, MAC, and an online/offline pill; pull-to-refresh; a
  logout menu with **Log Out (this app)** and **Log Out Everywhere** (ends the session server-side).
- **Device detail → Remote Access console** — pick HTTP/HTTPS, a port (default 80; e.g. 8377 for a
  custom app), and a path, then **Send Request**: it provisions the relay and shows the HTTP status,
  byte count, relay host, and a body preview.

No secrets are ever displayed or logged (password is a `SecureField`; errors use
`GoodCloudError.redactedDescription`).

## CLI — `gck-probe`

A headless end-to-end diagnostic: login → devices → provision → relay GET, printing **redacted**
results (status codes, device names, response shape — never tokens/passwords/cookies). Handy for
verifying connectivity and for scripted checks.

**Login mode** (derives + persists the token; also writes `GCK_TOKEN` to a git-ignored `.env`):

```bash
GCK_EMAIL='you@example.com' GCK_PASSWORD='…' swift run gck-probe
```

**Token mode** (skip login; reuse a token — useful for repeated runs without re-authenticating):

```bash
set -a; source .env; set +a       # loads GCK_TOKEN written by a prior login-mode run
swift run gck-probe
```

Sample output:

```
[1] Using GCK_TOKEN from environment (skipping login)
[2] Devices (typed SignedAPIClient.devices)
    OK: 2 devices
    - Mudi7 id=100000001 online=true
[3] Remote access provisioning -> Mudi7 (id=…, online=true)
    OK: relay base URL = https://rttys-…/web/<ddns>/http/127.0.0.1%3A80%2F
[4] Relay GET ""
    HTTP 200, 749 bytes, type=text/html, host=rttys-web-…   ← router admin panel, proxied
```

---

## Notes, caveats & security

- **GoodCloud accounts are single-session.** A new login (web, app, or this library) invalidates
  every other session, which surfaces as API `code -1010` ("Account Login Elsewhere"). The library
  treats `-1010` as a typed `.api` error; the sample app clears the session and returns to login.
- **Target redirects to a LAN IP.** The GL admin UI (`:80`) issues 302s to `http://192.168.8.1`;
  `RelayHTTPClient` follows redirects, so such a redirect surfaces as `.transport(-1004)`
  (unreachable). Plain JSON APIs (like a custom `:8377` daemon) return their body directly.
- **Credentials & tokens:** the `FE_TOKEN` is stored in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlock`); nothing sensitive is logged (a `SecretRedactor` scrubs
  logs/errors). The `gck-probe` CLI uses an in-memory credential store (a bare CLI binary has no
  Keychain entitlement) and writes the token to `.env` — keep that file private (it's git-ignored).
- **RSA signature:** requests are signed with an RSA-encrypted timestamp using GoodCloud's embedded
  512-bit public client key. This is a public key extracted from the web bundle, not a secret.

## Repository layout

```
Sources/GoodCloudKit/       the library
Sources/GoodCloudExample/   the SwiftUI sample app  (product: GoodCloudExample)
Sources/GCKProbe/           the CLI diagnostic       (product: gck-probe)
Tests/GoodCloudKitTests/    unit tests (URLProtocol-stubbed; no live network)
docs/goodcloud-remote-access.md   the reverse-engineered wire contract
run-app.sh                  build + launch the sample app as a .app bundle
```

## Tests

```bash
swift test        # offline, no credentials required
```

## License

Licensed under the **GNU Affero General Public License v3.0** — see [LICENSE](LICENSE).
The AGPL's network-use clause (§13) means any modified version offered to users over a network
must make its source available under the same terms.
