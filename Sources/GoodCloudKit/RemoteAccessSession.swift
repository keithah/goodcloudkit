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
    /// The `gl-rtty-token` cookie value. The provisioning response carries no `Set-Cookie`; the
    /// web client derives this cookie from the response body (value = `content.id`), so we do the
    /// same. Sent to the relay host by `RelayHTTPClient`.
    public let relayToken: String?
    /// The GoodCloud session token (`FE_TOKEN`), also sent as a cookie to the relay host — the
    /// browser sends both `gl-rtty-token` and `FE_TOKEN` (both `.goodcloud.xyz` cookies).
    public let feToken: String?

    public init(baseURL: URL, tokenDomain: String, sessionID: String?, issuedAtMillis: Int64?,
                relayToken: String? = nil, feToken: String? = nil) {
        self.baseURL = baseURL
        self.tokenDomain = tokenDomain
        self.sessionID = sessionID
        self.issuedAtMillis = issuedAtMillis
        self.relayToken = relayToken
        self.feToken = feToken
    }
}
