import Foundation
import GoodCloudKit

/// `gck-probe` — a native command-line end-to-end diagnostic for GoodCloudKit.
///
/// Runs the full stack (login -> device list -> remote-access provisioning -> relay GET)
/// against the REAL GoodCloud API from a native `URLSession` (no browser, no CORS), using
/// credentials supplied only via environment variables (`GCK_EMAIL` / `GCK_PASSWORD`) so no
/// password is ever hardcoded or committed.
///
/// SECRET HANDLING: this tool never prints the password, the FE_TOKEN, the `gl-rtty-token`,
/// or any `Set-Cookie` value. Failures are reported via `GoodCloudError.redactedDescription`
/// (or a bare `"\(error)"` for non-`GoodCloudError` cases, which for the errors this tool can
/// hit — transport/decoding/JSON — never contain the password or a token).
@main
struct GCKProbe {
    static func main() async {
        print("=== gck-probe: GoodCloudKit live end-to-end diagnostic ===")

        // Auth: prefer GCK_TOKEN (a session FE_TOKEN) — lets us iterate on the device/relay path
        // without a password. Else fall back to a full email/password login.
        let tokenProvider: TokenProvider
        if let token = nonEmptyEnv("GCK_TOKEN") {
            print("\n[1] Using GCK_TOKEN from environment (skipping login)")
            tokenProvider = StaticTokenProvider(token)
        } else if let email = nonEmptyEnv("GCK_EMAIL"), let password = nonEmptyEnv("GCK_PASSWORD") {
            // Use an in-memory store, not the Keychain: a bare `swift run` binary isn't
            // code-signed with a keychain entitlement, so KeychainCredentialStore fails
            // (OSStatus -25244). The probe hands the token onward via .env instead.
            let auth = GoodCloudAuth(credentials: InMemoryCredentialStore())
            print("\n[1] Login (GoodCloudAuth.logIn)")
            do {
                let feToken = try await auth.logIn(email: email, password: password)
                // Hand the derived session token to autonomous re-runs via .env (gitignored),
                // so subsequent `swift run gck-probe` can use GCK_TOKEN without a password.
                persistTokenToEnv(feToken)
                print("    OK: authenticated. Wrote GCK_TOKEN to .env for token-mode re-runs.")
            } catch {
                print("    FAIL: \(describe(error))\n\nStopping: login failed, cannot continue.")
                return
            }
            // NOTE: do NOT perform any second login here — the account is single-session, so a
            // second login (e.g. a raw diagnostic replay) invalidates this session and every
            // subsequent call fails with code -1010 "Account Login Elsewhere."
            tokenProvider = PasswordTokenProvider(auth: auth)
        } else {
            printErr("""
                ERROR: no auth provided.
                Provide a session token:  GCK_TOKEN=<FE_TOKEN> swift run gck-probe
                (or, to also test login:  GCK_EMAIL=you@example.com GCK_PASSWORD=... swift run gck-probe)
                """)
            exit(1)
        }

        let client = SignedAPIClient(tokens: tokenProvider)
        let token = (try? await tokenProvider.token()) ?? ""

        // Step 2a: typed devices() — the code path we're validating.
        print("\n[2] Devices (typed SignedAPIClient.devices)")
        do {
            let devices = try await client.devices()
            print("    OK: \(devices.count) devices")
            for d in devices { print("    - \(d.name) id=\(d.id) online=\(d.isOnline)") }
        } catch {
            print("    FAIL (typed): \(describe(error))")
        }

        // Step 2b: raw device-list shape diagnostic + target extraction (works even if the
        // typed model is wrong). Prints structure only — no secret values.
        print("\n[2b] Device-list raw shape")
        let raw = await rawDevices(token: token)
        print("    " + raw.shape)
        for d in raw.devices { print("    device: name=\(d.name) id=\(d.id) online=\(d.online)") }

        // Step 3: pick a target — prefer "Mudi", else first online.
        guard let target = raw.devices.first(where: { $0.name.localizedCaseInsensitiveContains("Mudi") })
                ?? raw.devices.first(where: { $0.online })
                ?? raw.devices.first else {
            print("\nStopping: no device found in raw response to probe.")
            return
        }

        print("\n[3] Remote access provisioning -> \(target.name) (id=\(target.id), online=\(target.online))")
        var session: RemoteAccessSession?
        do {
            let s = try await client.remoteAccess(deviceID: target.id, kind: .web, protocol: .http, port: 80)
            session = s
            print("    OK: relay base URL = \(s.baseURL.absoluteString)")
            print("        relayToken captured = \(s.relayToken != nil), feToken present = \(s.feToken != nil)")
        } catch {
            print("    FAIL: \(describe(error))")
        }

        guard let session else {
            print("\nStopping: remote access provisioning failed.")
            return
        }

        // Step 4: use the provisioned relay to GET the device's root page through the tunnel.
        print("\n[4] Relay GET \"\" (RelayHTTPClient.get)")
        // Transparent-proxy check: GET the target root through the relay. (A target that issues
        // its own redirect to a LAN IP — e.g. GL admin → http://192.168.8.1 — will surface as a
        // .transport(-1004) if followed; a JSON API like Wattline returns its body directly.)
        do {
            let (data, resp) = try await RelayHTTPClient(session: session).get("")
            let preview = String(data: data.prefix(90), encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ") ?? "<non-text>"
            let ct = resp.value(forHTTPHeaderField: "Content-Type") ?? "?"
            print("    HTTP \(resp.statusCode), \(data.count) bytes, type=\(ct), host=\(resp.url?.host ?? "?")")
            print("    body[0..90]: \(preview)")
        } catch {
            print("    FAIL: \(describe(error))")
        }

        print("\n=== done ===")
    }
}

// MARK: - Helpers

private func nonEmptyEnv(_ name: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else { return nil }
    return v
}

private func describe(_ error: Error) -> String {
    (error as? GoodCloudError)?.redactedDescription ?? "\(error)"
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Raw device-list fetch: describes the `info` shape (structure only, no values) and extracts
/// candidate devices from wherever the array lives, so the probe works even if the typed model
/// is wrong.
private func rawDevices(token: String) async -> (shape: String, devices: [(id: String, name: String, online: Bool)]) {
    guard let sig = try? RequestSigner.goodCloud().signature(),
          let url = URL(string: "https://api.goodcloud.xyz/cloud-api/cloud/v2/device?pageNum=1&pageSize=100") else {
        return ("could not build request", [])
    }
    var req = URLRequest(url: url)
    req.httpShouldHandleCookies = false
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue(token, forHTTPHeaderField: "token")
    req.setValue(sig, forHTTPHeaderField: "signature")
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ("no/invalid JSON response", [])
    }
    let code = obj["code"] as? Int ?? -999
    let msg = obj["msg"] as? String ?? ""
    if code != 0 { return ("code=\(code) msg=\(msg)", []) }

    let info = obj["info"]
    var shape = "info "
    var rows: [[String: Any]] = []
    if let d = info as? [String: Any] {
        shape += "= dict keys=\(d.keys.sorted())"
        for (k, v) in d {
            if let arr = v as? [[String: Any]], (arr.first?["mac"] != nil || arr.first?["id"] != nil) {
                shape += "; '\(k)' = array[\(arr.count)] itemKeys=\(arr.first.map { Array($0.keys.sorted()) } ?? [])"
                rows = arr
            }
        }
    } else if let arr = info as? [[String: Any]] {
        shape += "= array[\(arr.count)] itemKeys=\(arr.first.map { Array($0.keys.sorted()) } ?? [])"
        rows = arr
    } else {
        shape += "= \(type(of: info))"
    }

    let devices = rows.map { row -> (id: String, name: String, online: Bool) in
        let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init) ?? ""
        let name = (row["name"] as? String) ?? "?"
        let statusInt = (row["status"] as? Int) ?? (row["status"] as? String).flatMap { Int($0) }
        let online = (statusInt == 1) || ((row["online"] as? Bool) == true)
        return (id, name, online)
    }
    return (shape, devices)
}

/// Writes/updates `GCK_TOKEN=<token>` in `./.env` (gitignored) so token-mode re-runs work
/// without a password. Best-effort; ignores I/O errors.
private func persistTokenToEnv(_ token: String) {
    let path = ".env"
    var lines = (try? String(contentsOfFile: path, encoding: .utf8))
        .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
    lines.removeAll { $0.hasPrefix("GCK_TOKEN=") || $0.isEmpty }
    lines.append("GCK_TOKEN=\(token)")
    try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Self-contained login-shape diagnostic

private struct LoginDiagnostic {
    let code: Int
    let msg: String
    let infoKeys: [String]
    /// "body", "set-cookie", or "none" — never the token value itself.
    let tokenSource: String
}

private enum ProbeDiagnosticError: Error {
    case notHTTPResponse
    case notJSONObject
}

/// Redoes GoodCloudAuth's raw `/cloud/v2/auth/login` POST entirely within the probe target,
/// deliberately kept separate from — and no more privileged than — GoodCloudKit's public API
/// (it uses only `RequestSigner.goodCloud()`, which is public). This exists purely to surface
/// response-shape diagnostics the library intentionally doesn't expose (to avoid weakening its
/// own redaction guarantees): the envelope's `code`/`msg`, the top-level key NAMES of `info`
/// (never their values), and whether the FE_TOKEN arrived via the JSON body or a Set-Cookie
/// header (never the token value itself, and never the password or any cookie value).
private func rawLoginDiagnostic(email: String, password: String) async throws -> LoginDiagnostic {
    let signer = RequestSigner.goodCloud()
    let encryptedPassword = try signer.encrypt(password)

    let pairs: [(String, String)] = [
        ("name", email),
        ("password", encryptedPassword),
        ("deviceId", UUID().uuidString),
        ("singleId", UUID().uuidString),
    ]
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    let body = pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")

    var req = URLRequest(url: URL(string: "https://api.goodcloud.xyz/cloud-basic/cloud/v2/auth/login")!)
    req.httpMethod = "POST"
    req.httpShouldHandleCookies = false
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue(try signer.signature(), forHTTPHeaderField: "signature")
    req.httpBody = Data(body.utf8)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw ProbeDiagnosticError.notHTTPResponse }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProbeDiagnosticError.notJSONObject
    }

    let code = obj["code"] as? Int ?? -1
    let msg = obj["msg"] as? String ?? ""
    let infoDict = obj["info"] as? [String: Any]
    let infoKeys = infoDict.map { Array($0.keys).sorted() } ?? []

    var tokenSource = "none"
    if let t = infoDict?["token"] as? String, !t.isEmpty {
        tokenSource = "body"
    } else if let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              probeCookieValue(named: "FE_TOKEN", in: setCookie) != nil {
        tokenSource = "set-cookie"
    }

    return LoginDiagnostic(code: code, msg: msg, infoKeys: infoKeys, tokenSource: tokenSource)
}

/// Tiny self-contained Set-Cookie value lookup — intentionally separate from GoodCloudKit's
/// internal (non-public) `CookieHeader` helper. Only used to detect a named cookie's PRESENCE;
/// the returned value is checked for non-nil/emptiness and never printed.
private func probeCookieValue(named name: String, in setCookie: String) -> String? {
    let prefix = name + "="
    for cookie in setCookie.components(separatedBy: ",") {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix(prefix) { return String(kv.dropFirst(prefix.count)) }
        }
    }
    return nil
}
