import Foundation

/// A minimal, spec-correct `application/x-www-form-urlencoded` body encoder.
///
/// `URLComponents.queryItems` + `percentEncodedQuery` is NOT safe for this content type: it does
/// not percent-encode `+`, but form parsers decode `+` as a literal space. Values that are base64
/// (like an RSA-encrypted password, which is full of `+`, `/`, and `=`) get silently corrupted
/// server-side as a result. This encoder escapes everything except the unreserved character set,
/// so every byte round-trips through a spec-correct decoder.
enum FormURLEncoded {
    static func body(_ pairs: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
    }
}

/// Password-based login against `/cloud-basic/cloud/v2/auth/login`, persisting the resulting FE_TOKEN.
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
        self.baseURL = baseURL
        self.session = session
        self.signer = signer
        self.identity = identity
        self.credentials = credentials
    }

    /// The login endpoint returns the FE_TOKEN as `info` — a plain STRING — on success, but
    /// `info` is `{}` / null on failure. So `info` is decoded leniently as an optional string
    /// (verified live 2026-07-21: `{"code":0,"msg":"Success.","info":"<FE_TOKEN>"}`).
    private struct LoginResponse: Decodable, Sendable {
        let code: Int
        let msg: String
        let token: String?
        enum CodingKeys: String, CodingKey { case code, msg, info }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decode(Int.self, forKey: .code)
            msg = (try? c.decode(String.self, forKey: .msg)) ?? ""
            token = try? c.decode(String.self, forKey: .info)
        }
    }

    /// Logs in with `email`/`password`, RSA-encrypting the password before it ever leaves the
    /// device. Returns the FE_TOKEN and persists it to `credentials`.
    @discardableResult
    public func logIn(email: String, password: String) async throws -> String {
        let id = identity.identity()
        let form = FormURLEncoded.body([
            ("name", email),
            ("password", try signer.encrypt(password)),
            ("deviceId", id.deviceId),
            ("singleId", id.singleId),
        ])

        var req = URLRequest(url: baseURL.appendingPathComponent("/cloud-basic/cloud/v2/auth/login"))
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try signer.signature(), forHTTPHeaderField: "signature")
        req.httpBody = Data(form.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw GoodCloudError.transport(e)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GoodCloudError.httpStatus(http.statusCode)
        }

        // Envelope: non-zero code -> .api (covers bad credentials).
        let resp: LoginResponse
        do {
            resp = try JSONDecoder().decode(LoginResponse.self, from: data)
        } catch {
            throw GoodCloudError.decoding("\(error)")
        }
        guard resp.code == 0 else { throw GoodCloudError.api(code: resp.code, message: resp.msg) }

        // Token: `info` string on success; fall back to Set-Cookie: FE_TOKEN if absent.
        let token = resp.token
            ?? Self.feTokenFromSetCookie((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"))
        guard let token, !token.isEmpty else {
            throw GoodCloudError.decoding("login succeeded but no FE_TOKEN in body or Set-Cookie")
        }
        try credentials.save(Credentials(account: email, refreshToken: token))
        return token
    }

    /// The currently persisted FE_TOKEN, if any.
    public func currentToken() throws -> String? { try credentials.load()?.refreshToken }

    /// Clears the persisted FE_TOKEN (local only).
    public func logOut() throws { try credentials.delete() }

    /// Ends the session server-side (`POST /cloud-basic/cloud/v3/auth/logout`) and then clears the
    /// local token. Because GoodCloud accounts are single-session, this invalidates the one active
    /// session everywhere. Best-effort on the network call; the local token is always cleared.
    public func logOutEverywhere() async {
        if let token = try? credentials.load()?.refreshToken, !token.isEmpty {
            var req = URLRequest(url: baseURL.appendingPathComponent("/cloud-basic/cloud/v3/auth/logout"))
            req.httpMethod = "POST"
            req.httpShouldHandleCookies = false
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(token, forHTTPHeaderField: "token")
            if let sig = try? signer.signature() { req.setValue(sig, forHTTPHeaderField: "signature") }
            _ = try? await session.data(for: req)
        }
        try? credentials.delete()
    }

    static func feTokenFromSetCookie(_ header: String?) -> String? {
        CookieHeader.value(named: "FE_TOKEN", in: header)
    }
}

/// A `TokenProvider` backed by the FE_TOKEN persisted by a prior `GoodCloudAuth.logIn`.
public struct PasswordTokenProvider: TokenProvider {
    private let auth: GoodCloudAuth
    public init(auth: GoodCloudAuth) { self.auth = auth }
    public func token() async throws -> String {
        guard let t = try await auth.currentToken() else { throw GoodCloudError.authFailed }
        return t
    }
}
