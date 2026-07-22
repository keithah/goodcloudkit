# Design: Consuming the GoodCloud Relay from a Client App

A client-agnostic design for building an application that reaches a service on a GL.iNet
router **from anywhere**, tunneled through GoodCloud's remote-access relay — with no changes
to the router and no port-forwarding.

This is the **design** layer. It sits on top of the observed wire contract in
[`goodcloud-remote-access.md`](goodcloud-remote-access.md) (auth, request signing,
`rtty/run`, cookies) and is the cloud-side counterpart to
[`goodcloud-device-integration.md`](goodcloud-device-integration.md) (how the router connects).

The guidance here is **language- and platform-neutral** — described in terms of roles and
interfaces, not a specific SDK. (`GoodCloudKit` is one concrete Swift implementation of this
design; nothing here assumes it.)

---

## 1. Goal, scope, non-goals

**Goal.** Given a GoodCloud account and a bound, online device, obtain a working base URL
that proxies a chosen LAN `host:port` on that device, and consume it reliably as either a
raw HTTP API or a browser-embeddable web UI.

**In scope.**
- Authenticating to the GoodCloud API and enumerating devices.
- Provisioning a relay session (`rtty/run`) and consuming it.
- The session lifecycle: expiry, re-provision, and the failure signals that drive it.
- The auth/cookie/redirect mechanics a client must get right.

**Non-goals.**
- The device side (`gl-cloud`, MQTT) — that's the integration doc.
- GoodCloud's SSO/account internals beyond obtaining a session token.
- Being a general MQTT/command client — this design is about the **HTTP relay** only.

---

## 2. Components

Five roles. Keep them as separate units with narrow interfaces so each can be understood and
tested on its own.

| Role | Responsibility | Depends on |
|---|---|---|
| **AuthProvider** | Produce a valid session token (`FE_TOKEN`) and a fresh per-request `signature`. Persist/refresh credentials. | RSA primitive, secret store |
| **DeviceCatalog** | List/look up devices; expose `id`, `ddns`, `status`, `rtty_web/ssh`. | SignedApiClient |
| **RelayProvisioner** | Call `rtty/run` for a device+target and return a `RelaySession`. | SignedApiClient |
| **RelaySession** | Own one relay's `baseURL`, region host, auth cookie(s), and freshness state; know how to renew/close. | — (value object + policy) |
| **RelayHTTPClient / WebViewLoader** | Actually consume the `baseURL` — as an HTTP client (JSON APIs) or a web view (admin UIs). | RelaySession |

A thin **SignedApiClient** underlies AuthProvider/DeviceCatalog/RelayProvisioner: it injects
the `token` and `signature` headers, disables its own cookie handling for API calls, and
unwraps the `{code,msg,info}` envelope (`code==0` = success). See the wire doc §2.

```
AuthProvider ──token──▶ SignedApiClient ──▶ DeviceCatalog ──device──▶ RelayProvisioner
                                                                          │
                                                                    RelaySession
                                                                     ┌────┴────┐
                                                          RelayHTTPClient   WebViewLoader
```

---

## 3. Session lifecycle (state machine)

A relay session is **ephemeral and freshness-sensitive** — treat it as a short-lived lease,
not a stable endpoint.

```
        provision (rtty/run)
   ─────────────────────────────▶  ACTIVE ──────consume OK──────▶ ACTIVE
                                     │  ▲                            │
                       404→error.html│  │ re-provision               │ idle/stale
                       or transport  │  │ (fresh rtty/run)           ▼
                            fail      ▼  │                         EXPIRED
                                   EXPIRED ──────────────────────────┘
```

- **Provision** — `POST /cloud-api/cloud/device/v4/{deviceId}/rtty/run` with query params
  (`enable=true`, `ip`, `port`, `protocol=http|https`, `rtty_type=web|ssh`, `web=true`).
  Response yields the relay `url` (the base) and `token_domain: .goodcloud.xyz`.
- **Consume** — issue requests against the returned base URL (see §4/§5).
- **Expire** — the session is time-bound. A stale or re-opened session redirects/`404`s to
  `https://<rttys-host>/gl-rtty/error.html`. Treat **any** navigation to `…/gl-rtty/error.html`
  (or a transport failure after previously working) as `EXPIRED`.
- **Re-provision** — on `EXPIRED`, call `rtty/run` again to mint a fresh session. Do **not**
  try to "reuse" the old base URL.

**Design rule:** callers should go through a `withRelay(device, target) { session in … }`
helper that provisions lazily, and on an `EXPIRED` signal re-provisions **once** and retries
the operation. Bound the retries (e.g. 1 re-provision) to avoid loops when the device is
genuinely offline.

**Open items to pin down on first live runs** (carried from the wire doc): exact TTL, whether
a keepalive exists, and behavior when the device is offline. Design defensively until these
are measured — assume no keepalive and a short TTL.

---

## 4. Auth model — the three things clients get wrong

### 4.1 API auth: header-based, per-request signature
Every `api.goodcloud.xyz` call carries `token` (the `FE_TOKEN` verbatim) and a fresh
`signature = base64(RSA_PKCS1v1_5(pubkey, String(now_ms)))`. It's **not** cookie-based, so API
calls should use `credentials: omit` / cookie handling disabled. (Full detail + the embedded
pubkey: wire doc §2 and `signature-re.md`.)

### 4.2 Relay auth: a cookie, in a cookie *store*
The relay (`rttys-*.goodcloud.xyz`) authenticates via a **`gl-rtty-token` cookie** on domain
`.goodcloud.xyz`. The critical, non-obvious requirements:

- **Use a cookie store, not a hand-set `Cookie:` header.** The relay entry URL is on a
  `rttys-ssh-*` host and **302-redirects** to a `rttys-web-*` host. A manually attached
  `Cookie:` header is **stripped across that cross-host redirect**; a cookie placed in the
  client's cookie store for domain `.goodcloud.xyz` **survives** it. This single detail is the
  difference between `200` and `403`.
- **Carry both token cookies.** In practice set **`gl-rtty-token`** *and* **`FE_TOKEN`** to the
  session token value, for domain `.goodcloud.xyz`, in the store. (Empirically the relay's
  `gl-rtty-token` value equals the `FE_TOKEN` session token; the ssh→web hop also sets an
  `HttpOnly` `rtty-http-sid` cookie which the store must retain.)
- **Let the client follow the ssh→web redirect** with the cookie store attached; don't try to
  pre-compute the `-web-` URL yourself.

### 4.3 Region is per-session — never hardcode
The `rttys` host in the returned URL is regional (e.g. `…-cloud-us`). Read it from the
`rtty/run` response / redirect every time. Do not hardcode a region.

---

## 5. Design decisions & gotchas

### 5.1 The redirect-to-LAN trap (auto-follow is dangerous here)
The relay transparently proxies the target service. If the **target** issues a redirect to a
private LAN address — e.g. a router admin UI bouncing to `http://192.168.8.1/` — a client that
blindly auto-follows redirects will chase the LAN IP off-tunnel and fail with an unreachable /
transport error, which is easy to misread as "device offline."

**Decision:** distinguish **relay redirects** (the `rttys-ssh-*` → `rttys-web-*` hop, which you
*must* follow, still on `*.goodcloud.xyz`) from **target redirects** to RFC-1918 / private
addresses (which you must **not** auto-follow). Either:
- consume JSON APIs that don't redirect (preferred for machine clients — see 5.2), or
- for web-UI consumption, load inside a web view that keeps the relay origin, and don't let a
  programmatic HTTP client auto-follow a `Location` pointing at a private IP.

### 5.2 Two consumption modes — pick by target
- **HTTP API target (e.g. an app's own service on a custom port).** Point `rtty/run` at that
  port (`ip=127.0.0.1&port=<n>&protocol=http`) and use the **RelayHTTPClient** to issue
  requests against `baseURL + "/<path>"`. JSON responses come straight back with no
  redirect-to-LAN problem. This is the clean path for programmatic integration, and it means
  **arbitrary LAN ports are reachable** — no need to front your service on `:80`.
- **Web UI target (router admin panel, AdGuard, etc.).** Provision `port=80` (or the UI's
  port) and load `baseURL` in a **WebViewLoader** (embedded browser) so the SPA runs with the
  relay origin and its cookies intact. Apply the 5.1 rule to any framed navigation.

### 5.3 Single-session token invalidation
The GoodCloud account is (observed) **single-session**: a newer login elsewhere invalidates
older session tokens, surfacing as API `code: -1010` ("Account Login Elsewhere."). Design for
it:
- The **AuthProvider** must recognize `-1010` and treat the token as dead → trigger re-auth,
  not an infinite retry.
- Diagnostic/CLI tools must **not** double-login (a second login kills the first session).
  Mint one token and reuse it; keep other clients (e.g. a browser on goodcloud.xyz) off the
  account during automated runs.
- Decode the `{code,msg,info}` envelope **leniently** — a non-zero `code` may carry an
  error-shaped `info`; a strict decoder throws a confusing parse error and masks the real
  code (this is how `-1010` gets hidden).

### 5.4 Secret handling
`FE_TOKEN`, the bind `token`, `gl-rtty-token`, and passwords are all credentials.
- Persist tokens in the platform secret store (Keychain / equivalent), never in plaintext
  config or logs.
- Run all diagnostic output through a **secret redactor** before printing/logging (tokens,
  cookies, MACs, ddns, device ids).
- If login uses direct password (wire doc §6b option 1), the password is RSA-encrypted
  client-side; when form-encoding it, **percent-encode the base64** (`+`/`/`/`=`) — a naive
  encoder turns `+` into a space and corrupts the password.

---

## 6. Error handling & retry/renew policy

| Signal | Meaning | Client action |
|---|---|---|
| API `code == 0` | success | proceed |
| API `code == -1010` | session invalidated elsewhere | drop token → re-auth (once), then retry |
| API non-zero (other) | request-level error | surface `msg`; do **not** retry blindly |
| HTTP non-2xx from API host | transport/gateway | map to a typed transport error; bounded retry |
| Relay nav → `…/gl-rtty/error.html` | session expired/invalid | mark `EXPIRED` → re-provision once → retry |
| Relay/transport error after previously working | likely expiry, possibly device offline | re-provision once; if it fails again, report "device unreachable", stop |
| Target `Location:` → private IP | redirect-to-LAN trap (5.1) | do **not** follow; handle per consumption mode |

Principles: **bounded** retries (one re-auth, one re-provision), typed errors that name the
layer (auth / provisioning / relay / target), and never an unbounded loop when the device is
simply offline.

---

## 7. Testing strategy

Make the whole flow testable without a live device or network:

- **Stub the API transport.** Inject a fake HTTP layer that returns canned `{code,msg,info}`
  envelopes for `device` list, `orgDevice/count`, and `rtty/run`. Verify header injection
  (`token` present, `signature` present and fresh per call) and lenient envelope decoding
  (including `-1010`).
- **Simulate the relay redirect.** A stub that returns a `302` from `rttys-ssh-*` to
  `rttys-web-*` and asserts the cookie **survives** via the store (fails if the client used a
  manual header). Include a variant that emits a target `Location` to `192.168.x.x` and assert
  the client does **not** follow it (5.1).
- **Session lifecycle.** Drive ACTIVE → `error.html` → re-provision → ACTIVE and assert exactly
  one re-provision and one retry; assert it gives up (typed "unreachable") on repeated failure.
- **Redaction.** Feed known secrets through the redactor and assert none appear in emitted
  logs, including overlapping/substring cases.
- **Live smoke (manual, gated).** A CLI that does auth → devices → `rtty/run` →
  RelayHTTPClient.get against a real online device, with redacted output. Keep it single-login
  (5.3). Note: GoodCloud's edge may WAF unfamiliar server IPs — run live checks from the user's
  own network.

---

## 8. Summary of design rules

1. Relay sessions are **leases** — provision lazily, re-provision on `error.html`, never reuse.
2. Relay auth lives in a **cookie store**, not a header — it must survive the ssh→web redirect.
3. **Never hardcode** the region/rttys host — read it per session.
4. **Don't auto-follow** target redirects to private IPs; choose HTTP-API vs web-view
   consumption by target type.
5. Handle **`-1010`** as token death; keep clients single-login; decode envelopes leniently.
6. Arbitrary LAN ports are reachable — **no `:80` fronting required** for API targets.
7. Everything token-shaped is a secret — **store securely, redact in logs**.
