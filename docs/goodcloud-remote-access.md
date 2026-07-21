# GoodCloud Remote-Access Contract (Phase 0 recon)

**Captured:** 2026-07-21, from a logged-in `www.goodcloud.xyz` session (web app v3.19.0),
driven live in the user's Chrome. All tokens/signatures/MACs/ddns/device-ids below are
**redacted placeholders** — real values were never committed.

> This document is the observed wire contract. It supersedes the pre-recon assumptions in
> the design spec (§4/§5), which assumed a simple email/password login and an opaque
> "relay base URL". The reality is (a) Keycloak OIDC auth, (b) **signed** API requests, and
> (c) an **rtty**-based relay. See "Design implications" at the end.

## 1. Hosts & envelope

- **Web app:** `https://www.goodcloud.xyz` — Vue SPA, hash router (`#/…`).
- **API:** `https://api.goodcloud.xyz` with two path prefixes:
  - `/cloud-api/…` — device & cloud operations
  - `/cloud-basic/…` — user, auth, org, notifications
- **Response envelope (uniform):** `{ "code": <number>, "msg": <string>, "info": <any> }`.
  `code == 0` means success (`msg` often `"Success."`).

## 2. Authentication

**Identity provider: Keycloak OIDC.**
- Authorize endpoint: `https://sso.gl-inet.com/realms/goodcloud/protocol/openid-connect/auth`
  - `client_id=goodcloud-web`, `response_type=code`, `scope=openid email profile`,
    `redirect_uri=https://www.goodcloud.xyz/`, plus `state` and `nonce`. The web app sends
    `prompt=login` (forces a fresh prompt). Google and Apple social login are also offered.
- **Code exchange:** the app trades the returned OIDC `code` at
  `POST https://api.goodcloud.xyz/cloud-basic/cloud/v3/auth/login/code`.
- **Session material:** a cookie **`FE_TOKEN`** on domain `.goodcloud.xyz` (JS-readable —
  NOT HttpOnly). No bearer token is kept in localStorage (only Countly analytics + UI prefs
  live there). The `FE_TOKEN` value feeds the per-request `token` header (below).

**Per-request signing — every `api.goodcloud.xyz` call carries two custom headers:**
- `token` — the `FE_TOKEN` cookie value, **verbatim** (no transform).
- `signature` — **SOLVED + empirically verified** (2026-07-21). It is *not* an HMAC/hash of
  the request. It is simply the current epoch-ms timestamp, RSA-encrypted:
  ```
  signature = base64( RSA_PKCS1v1_5_encrypt( <hardcoded 512-bit pubkey>, String(Date.now()) ) )
  ```
  - 88-char base64. **Non-deterministic** (PKCS#1 v1.5 random padding) — you can't byte-match a
    captured value, only produce a fresh valid one. The server RSA-decrypts to recover the
    timestamp (freshness/anti-replay). No `timestamp`/`nonce` header exists; the timestamp lives
    *inside* the encrypted blob. No symmetric secret, no canonical string.
  - **Hardcoded RSA public key** (from `index.*.js`, SPKI DER b64, 512-bit, e=65537 — a public
    client key, safe to embed):
    ```
    MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAItoR8lrBZ/ZaJZ3XvvgP8I31ImaTwbEPzPElmIZAasWoAzw3InqMVyeL7rTlFS3TFz3HMKBnrFlr463Bu19Tz0CAwEAAQ==
    ```
  - Requests also send `Accept`, and `Content-Type` on POSTs. Auth is **header-based, not
    cookie-based** — cross-origin calls work with `credentials: 'omit'`.
  - **Empirically verified:** an independently generated signature (from-scratch RSA, not the
    app's own signer) + the `token` header was accepted by
    `GET /cloud-api/cloud/v2/orgDevice/count` → `{code:0,"Success."}` with live data.
  - Full RE writeup + reference implementation: `docs/signature-re.md`.

## 3. Device enumeration

- **List:** `GET /cloud-api/cloud/v2/device?pageNum=&pageSize=&fuzzyKey=&productType=Router&…`
  (many optional filter params: `mac, ip, version, model, network_mode, status, name, …`).
  Response `info`:
  ```
  { all_count, online_count, offline_count, deactivated_count, total,
    rows: [ { id, name, description, mac, sn, ddns, model, gl_model, ip,
              status, network_mode, version, boardInfoModel, firmwareType,
              rtty_web, rtty_ssh, ddns, hasFirmwareUpdate, … } ] }
  ```
- **Detail:** `GET /cloud-api/cloud/device/{deviceId}` → `info` includes
  `{ id, name, mac, sn, ddns, ip, model, status, network_mode, rtty_web, rtty_ssh, … }`.
- **Counts:** `GET /cloud-api/cloud/v2/orgDevice/count` → `{ allCount, onlineCount,
  offlineCount, deactivatedCount, abnormalCount }`.
- Key fields for remote access: **`id`** (numeric device id, used in the provisioning path),
  **`ddns`** (short per-device name, e.g. `<DDNS>` — appears in the relay URL), **`status`**
  (1 = online), and **`rtty_web` / `rtty_ssh`**.

## 4. Remote GUI / SSH provisioning  ← the core mechanism

The "Remote GUI" button opens a modal to choose **protocol (HTTP/HTTPS)** and **target port**
(default `80`, editable). "Apply" fires:

**`POST /cloud-api/cloud/device/v4/{deviceId}/rtty/run`** — params on the **query string**
(axios `params`), empty body. Exact values observed for "Remote GUI" (HTTP, port 80):
```
?enable=true&ip=127.0.0.1&port=80&protocol=http&rtty_type=web&web=true
```
- `rtty_type=web` (GUI) / `ssh` (Remote SSH); `web=true`, `enable=true`.
- `ip`/`port`/`protocol` = the LAN target → set `port=8377` to reach Wattline directly.

**Response `info`:**
```json
{
  "token_domain": ".goodcloud.xyz",
  "url": "https://rttys-ssh-cloud-us.goodcloud.xyz/web/<DDNS>/http/127.0.0.1%3A80%2F",
  "content": { "goodcloud": [], "code": 0, "id": "<SESSION_ID>", "time": <epoch_ms> }
}
```

**Relay URL structure:**
```
https://<rttys-host>/web/<ddns>/<http|https>/<url-encoded TARGET>
                     ^^^^^^^^^^^                ^^^^^^^^^^^^^^^^^^^
   e.g. rttys-ssh-cloud-us     device ddns     e.g. 127.0.0.1%3A80%2F  = "127.0.0.1:80/"
   (regional: -us)
```
- The relay is GL.iNet's **rtty / rttys** (WebSocket reverse-access server; open source:
  github.com/zhaojh329/rtty + rttys). The router runs an rtty client that dials the rttys
  server; rttys proxies HTTP(S) to the chosen LAN `host:port` and streams it back.
- **The target `host:port` is literally in the URL path** → arbitrary LAN port is supported.
  Pointing at `127.0.0.1%3A8377%2F…` would reach Wattline's own port directly.

## 5b. Relay consumption auth — SOLVED (spike 2026-07-21)

- Provisioning (`rtty/run`) sets a **`gl-rtty-token` cookie on domain `.goodcloud.xyz`**
  (via `Set-Cookie` on the api response). That cookie is the relay's auth — the browser
  sends it to `rttys-*.goodcloud.xyz` when the relay URL loads.
- **Native-client recipe:** the `SignedAPIClient` disables cookie storage, so after `rtty/run`
  read `Set-Cookie: gl-rtty-token=…` from the response's `allHeaderFields`, capture that value
  into the `RemoteAccessSession`, and attach it as `Cookie: gl-rtty-token=<value>` on every
  request to the relay `baseURL`. `URLSession` follows the `-ssh-`→`-web-` redirect on its own.
- FE_TOKEN and gl-rtty-token are distinct values; the relay only needs `gl-rtty-token`.

## 6b. Login (OIDC) — options (spike 2026-07-21)

- Keycloak realm `goodcloud` advertises `password` + `refresh_token` + `authorization_code`
  + PKCE(S256). BUT **ROPC (password grant) is BLOCKED for client `goodcloud-web`** — a probe
  returned `unauthorized_client` ("Invalid client"). So raw email/password → Keycloak token
  endpoint does NOT work with the public SPA client.
- Viable login mechanisms for a native app:
  1. **Direct password login (RECOMMENDED for in-app fields)** — GoodCloud's OWN endpoint, not
     Keycloak. From the bundle (`j2e`/`handleLoginCloud`):
     ```
     POST https://api.goodcloud.xyz/cloud/v2/auth/login   (form-encoded body)
       name     = <email>
       password = base64(RSA_PKCS1v1_5(embedded pubkey, <plaintext password>))   // same hoe() as signature
       deviceId = <stable per-install id>      // web uses FingerprintJS; native app can use a persisted UUID
       singleId = <stable per-install id #2>
     headers: signature (RSA timestamp); token empty pre-login
     → returns FE_TOKEN (exact response shape UNVERIFIED — see caveat)
     ```
     Gives true in-app email/password. Password is RSA-encrypted client-side with the key we
     already reproduce. **Caveat:** couldn't verify live — a browser JS probe is CORS-blocked on
     this endpoint (native URLSession isn't CORS-bound), and testing needs a real credential.
     Verify the response shape (FE_TOKEN in body vs Set-Cookie; refresh token) during the first
     live run.
  2. **auth-code via in-app `WKWebView` (for Google/Apple SSO)** — user taps "Log in", a web view
     shows GL's real login (incl. SSO), the app intercepts the redirect to
     `https://www.goodcloud.xyz/?code=…` (via `WKNavigationDelegate`, since the redirect targets
     GL's own domain — `ASWebAuthenticationSession` can't catch an https redirect to a domain we
     don't own), then exchanges the code:
     `POST /cloud-basic/cloud/v3/auth/login/code` body
     `{authorizationCode, authorizationType:"keycloak", redirectUrl:"https://www.goodcloud.xyz/", loginDeviceType:"web", deviceId, singleId}`.
     Secondary option for SSO; embedded-webview SSO may be limited (Google blocks OAuth in
     embedded webviews).
- `refresh_token` is supported → persist it (Keychain) for silent re-auth.

## 5. Relay consumption & session lifecycle (partially characterized)

- Loading the returned `url` renders the proxied service — **confirmed end-to-end**: it served
  the router's real "GL-E5800 Admin Panel" login through the relay.
- **Two rttys hostnames:** `rtty/run` returns a URL on `rttys-ssh-cloud-us.goodcloud.xyz`, which
  redirects to the actual web proxy on `rttys-web-cloud-us.goodcloud.xyz/?_=<ts>#/…`. Both are
  regional (`-us`); read them from the response/redirect, don't hardcode the region.
- **Auth to rttys is via the `.goodcloud.xyz` cookie** (`token_domain` in the response), not a
  URL token. A client hitting the relay URL must carry that cookie.
- **Session is time-bound / freshness-sensitive.** A stale or re-opened session 404s to
  `https://<rttys-host>/gl-rtty/error.html`. Observed: worked immediately after `rtty/run`;
  a later re-navigation to the same URL failed. Implies each access should follow a fresh
  `rtty/run`, and/or the session has a short TTL keyed on `content.time`.
- **OPEN (resolve in the wire plan):** exact session TTL; whether a keepalive exists; whether
  rttys needs any header/token beyond the `.goodcloud.xyz` cookie; behaviour when the device
  is offline (our X3000 was offline, so untested there — the online Mudi7/E5800 was used).

## 6. Design implications (update the spec before the wire plan)

1. **Auth = Keycloak OIDC, not email/password.** `GoodCloudClient.logIn` should perform the
   OIDC flow against realm `goodcloud`, client `goodcloud-web` (resource-owner-password grant
   for a headless client, or authorization-code), then hit
   `/cloud-basic/cloud/v3/auth/login/code`. Persist `FE_TOKEN`/`token` in Keychain.
2. **Request signing is SOLVED + verified (no longer a blocker).** `signature =
   base64(RSA_PKCS1v1_5_encrypt(pubkey, String(Date.now())))`; `token` = `FE_TOKEN` verbatim.
   Trivial to reproduce (embed the public key; RSA-encrypt the timestamp). A from-scratch impl
   was accepted live by the server. → The SDK just needs an RSA/PKCS1v1.5 primitive (Security
   framework / SwiftCrypto) + the embedded public key. See `docs/signature-re.md`.
3. **The "relay base URL" is per-session and rtty-backed** — provision with
   `POST …/device/v4/{id}/rtty/run`, then use the returned `url` as the base. Not a static
   endpoint. `RemoteAccessSession` must own: provisioning, the `.goodcloud.xyz` cookie,
   freshness/TTL, and re-provision-on-expiry (the 404→error.html signal).
4. **Arbitrary target port IS supported** → Wattline's `:8377` is directly reachable via the
   relay; fronting Wattline on `:80` is now **optional**, not required. (Still fine to do it,
   but the constraint that drove that decision is lifted.)
5. **Regional rttys host** (`…-us`) is returned per session — read it from the response, don't
   hardcode.

## 7. Endpoints observed (reference)

```
POST /cloud-basic/cloud/v3/auth/login/code            (OIDC code -> session)
GET  /cloud-basic/cloud/v2/user
GET  /cloud-basic/cloud/v2/user/permissions
GET  /cloud-basic/cloud/v2/user/organization/switchList
GET  /cloud-api/cloud/v2/device?pageNum=&pageSize=&…   (device list)
GET  /cloud-api/cloud/device/{id}                      (device detail)
GET  /cloud-api/cloud/v2/orgDevice/count               (dashboard counts)
POST /cloud-api/cloud/device/v4/{id}/rtty/run?port=&ip=&web=&enable=&rtty_type=&protocol=
GET  /cloud-api/cloud/v2/device/getModelAndVersion | networkModes | basicAttrColumn
```
