# GoodCloudKit — Design

**Date:** 2026-07-20
**Status:** Approved (brainstorming), pending spec review
**Repo:** `~/src/goodcloudkit` (standalone SPM package + git repo)

## 1. Goal

A standalone, client-side Swift library that turns GL.iNet's GoodCloud
(`goodcloud.xyz`) remote-access relay into a general-purpose proxy for reaching
**any web-accessible service on a bound router**, from anywhere, with **no changes
to the consumer app** beyond a base-URL swap, and **no router-side machinery owned
by the library**.

The motivating consumers are the user's own apps and router-hosted web UIs:

- **Wattline** (native iOS/macOS app → the `wattlined` HTTP API)
- **Router-hosted admin web UIs**: GL admin panel, Starwatch, AdGuard, Speedify
  (all served under the admin nginx on port 80)

GoodCloudKit itself is app-agnostic: it authenticates to GoodCloud, finds a device,
and yields a relay **base URL** for that device's admin port (`:80`). Everything
app-specific (paths, app tokens) is the consumer's concern.

## 2. Scope

### In scope
- Reverse-engineering GoodCloud's remote-access flow (auth → device list →
  admin-panel remote-access provisioning → relay base URL + session lifecycle).
- A Swift package (`GoodCloudKit`) providing that flow behind a small typed API.
- Offline, fixture-based tests (no live credentials, no live network in CI).

### Out of scope (explicitly)
- **Reaching arbitrary LAN ports.** GoodCloudKit relies **only** on GoodCloud's
  existing admin-panel (`:80`) remote-access relay — the one already used daily.
  It never depends on an arbitrary-port relay capability.
- **Any router-side change.** Wattline needs to be reachable on `:80` (behind the
  admin nginx, like Starwatch/AdGuard/Speedify). That is a change to *Wattline's own
  package*, tracked separately (see §9), not part of GoodCloudKit.
- **Non-Apple bindings.** A Swift package cannot embed in a pure web SPA or a Python
  script. Other-language bindings are a possible future, not this project.
- **Fully headless login by automation.** During reconnaissance the user logs in to
  goodcloud.xyz personally; the library, once shipped, performs login itself as its
  normal product behavior.

## 3. Architecture

```
                       GoodCloudKit (Swift package, client-side)
 ┌────────────────────────────────────────────────────────────────────┐
 │  Auth          →  device enumeration  →  RemoteAccessSession          │
 │  (email/pw or     (list bound routers,   (provision + keepalive +     │
 │   token; Keychain) pick by MAC/id)        refresh; yields relay base) │
 └────────────────────────────────────────────────────────────────────┘
      │ returns: relayBaseURL  +  a URLSession/handler that injects
      │          GoodCloud session auth and trusts GoodCloud TLS
      ▼
 Consumers (unmodified — base-URL swap only):
   • Wattline app  →  URLSession(base: relayBase + "/wattline/")  → wattlined
   • Starwatch UI  →  WKWebView.load(relayBase + "/<starwatch-path>/")
   • AdGuard / Speedify / GL admin → WKWebView.load(relayBase + "/…")
                                     │
                                     ▼  (all HTTP, all :80)
      GoodCloud relay  →  router admin nginx :80  →  each app
```

**Boundaries**
- GoodCloudKit knows nothing about Wattline/Starwatch. It knows only:
  authenticate → device → relay base URL for that device's `:80`.
- Consumers integrate exactly two ways: (a) point an existing HTTP client at
  `relayBase + path`, or (b) load `relayBase + path` in a webview.
- The relay's auth (GoodCloud session/cookie) **wraps** each app's own auth. The
  SDK injects the relay layer; the consumer still sends its own app token inside
  (e.g. Wattline's bearer token) untouched.

## 4. Phase 0 — Reconnaissance (prerequisite, throwaway)

Feasibility and every wire detail depend on observing the real flow. This phase
produces a documented contract, not shipping code.

**Method**
- The **user** logs in to `goodcloud.xyz` in a browser. The assistant never types
  the user's credentials (entering credentials to authenticate is disallowed for
  the assistant). The assistant drives/inspects the already-authenticated session,
  or works from a user-provided HAR capture.
- Capture and document, in order:
  1. **Auth** — the login request/response; where the session token/JWT lives
     (header vs cookie), its lifetime, and any refresh mechanism.
  2. **Device list** — the endpoint returning bound routers; fields identifying a
     device (id, MAC, name, online state).
  3. **Remote-access provisioning** — the call(s) triggered by "Remote Access";
     the resulting relay base URL format (subdomain vs path token), and any
     required headers/cookies for subsequent proxied requests.
  4. **Session lifecycle** — keepalive cadence, expiry, teardown; behaviour when
     the device is offline.
  5. **Path behaviour** — whether the relay rewrites paths, and whether arbitrary
     `:80` paths (beyond the SPA root) are reachable through it (needed so
     `/wattline/`, Starwatch's path, etc. resolve).

**Output:** `docs/goodcloud-remote-access.md` — the observed contract. All captured
fixtures are **sanitized** (tokens, MACs, account ids, session ids redacted) before
entering the repo.

**Tooling:** the in-app browser (or the `libretto` skill / a user HAR) for capture
and network inspection.

## 5. `GoodCloudKit` public API (draft)

```swift
// 1. Client + auth
let client = GoodCloudClient()
try await client.logIn(email:, password:)      // or .authenticate(token:)
//   → stores refresh material in Keychain; never logs credentials

// 2. Enumerate bound devices
let devices = try await client.devices()        // [GoodCloudDevice: id, name, mac, online]

// 3. Open a remote-access session to a device's :80
let session = try await client.remoteAccess(device)   // provisions + keepalive
session.baseURL                                  // relay root for the device's :80

// 4a. API consumers: an auth/TLS-aware URLSession
let http = session.urlSession                    // injects relay auth, trusts GoodCloud TLS
//   Wattline:  http.get(session.baseURL.appending("wattline/status"))

// 4b. Webview consumers:
let request = session.webViewRequest(path: "…")  // URLRequest w/ relay auth headers/cookies
webView.load(request)

// 5. Lifecycle
session.state       // .provisioning / .active / .expired  (AsyncSequence / Combine)
try await session.renew()                        // SDK auto-renews before expiry
session.close()
```

**Design intent**
- `RemoteAccessSession` encapsulates everything recon reveals about the relay (URL
  format, required headers/cookies, keepalive cadence, expiry). Consumers see only
  `baseURL` + `urlSession` / `webViewRequest`.
- Concurrency: `actor`-based client, `Sendable` value types, async/await throughout.

## 6. Error handling

One typed `GoodCloudError`:
- `.authFailed` / `.credentialsRejected` — bad login or expired refresh
- `.deviceOffline` / `.deviceNotFound` — router not reachable by the cloud
- `.relayUnavailable` — provisioning failed / relay endpoint down
- `.sessionExpired` — surfaced only when auto-`renew()` also fails
- `.transport(URLError)` / `.decoding` — network + shape mismatches

Every case carries a redacted, loggable description (no secrets).

## 7. Security

- Credentials + refresh token live in **Keychain**
  (`kSecAttrAccessibleAfterFirstUnlock`); never `UserDefaults`, never logged.
- A redaction layer scrubs tokens/passwords/session ids from all log/error output.
- **TLS:** GoodCloud endpoints use CA-signed certs → standard validation, no pinning
  (recon confirms hostnames; optional pinning can be added later if certs are stable).
- Reconnaissance credentials are handled by the user, not the assistant (§4); repo
  fixtures are sanitized.

## 8. Testing

- Recon produces sanitized request/response fixtures. The suite replays them against
  `GoodCloudClient` (same spirit as WattlineCore's existing `ReplayTransport`), so the
  full auth → device → relay flow is tested **offline, with zero live credentials**.
- Contract tests assert the SDK parses exactly the shapes recon documented — GoodCloud
  API drift breaks a test, not a user.
- No test hits the live network or requires secrets.

## 9. External dependency — Wattline on :80 (tracked separately)

For the Wattline consumer to work through the `:80` relay, `wattlined` must be
reachable under the admin nginx (an nginx location fragment shipped in Wattline's
own package, like Starwatch/AdGuard/Speedify). This is a Wattline-package task,
already handed off as a standalone prompt, and is **not** part of GoodCloudKit.
Open question for that task: whether the new location must sit under the oui admin
auth/session, and how Wattline's bearer token coexists with the relay's admin session.

The `:80` admin web UIs (Starwatch/AdGuard/Speedify/GL admin) need no such change.

## 10. Repo layout

```
~/src/goodcloudkit/            # standalone git repo, SPM package
  Package.swift
  Sources/GoodCloudKit/…
  Tests/GoodCloudKitTests/…    # fixture replay + contract tests
  Fixtures/…                   # sanitized recon captures
  docs/
    goodcloud-remote-access.md # recon output (the observed contract)
    superpowers/specs/…        # this design + future specs
```

Consumed by Wattline via SPM (local path in dev; git tag later). Nothing in `peakdo`
depends on GoodCloudKit existing.

## 11. Recon-dependent open questions (resolved in Phase 0)

- Session token transport (header vs cookie), lifetime, refresh.
- Relay base-URL format (per-session subdomain vs path token).
- Whether arbitrary `:80` paths beyond the SPA root are reachable through the relay.
- Keepalive cadence and expiry behaviour; device-offline behaviour.
- Whether the relay wraps requests in an admin auth/session the consumer must satisfy.

## 12. Milestones (high level; detailed plan follows separately)

1. **Recon** — document the GoodCloud remote-access contract + sanitized fixtures.
2. **SDK core** — auth + device enumeration + Keychain, fixture-tested.
3. **RemoteAccessSession** — provisioning, base URL, keepalive/renew, `urlSession` +
   `webViewRequest`.
4. **Consumer proof** — reach a `:80` admin UI (Starwatch/AdGuard) end-to-end via
   webview; then Wattline once its `:80` task lands.
```
