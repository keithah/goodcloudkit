import Foundation

/// Consumes a provisioned `RemoteAccessSession` to speak HTTP to the LAN target behind an
/// rtty relay, authenticating with the `gl-rtty-token` cookie captured during provisioning.
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
        // Keep dots literal (IPv4 addresses like "127.0.0.1") but still encode ':' and '/'.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "."))
        let reencoded = full.addingPercentEncoding(withAllowedCharacters: allowed) ?? full
        let prefix = comps.map { "/" + $0 }.joined()                                  // "/web/<ddns>/<proto>"
        guard let url = URL(string: "\(scheme)://\(host)\(prefix)/\(reencoded)") else {
            throw GoodCloudError.relayUnavailable
        }
        return url
    }

    public func get(_ targetPath: String) async throws -> (Data, HTTPURLResponse) {
        // The relay host authenticates via `.goodcloud.xyz` cookies. Verified live: the web
        // client sets BOTH `gl-rtty-token` and `FE_TOKEN` to the SAME value — the session token
        // (`gl-rtty-token = V7()` = the FE_TOKEN cookie). The relay URL is on `rttys-ssh-*` and
        // 302-redirects to `rttys-web-*`; a *manual* Cookie header is stripped on that cross-host
        // redirect, so we put the cookies in the session's cookie STORE for domain
        // `.goodcloud.xyz` and URLSession re-sends them per-host across the redirect, like a browser.
        guard let fe = session.feToken, !fe.isEmpty else { throw GoodCloudError.relayUnavailable }
        if let storage = urlSession.configuration.httpCookieStorage {
            setRelayCookies(into: storage)
        }
        var req = URLRequest(url: try url(forTargetPath: targetPath))
        req.httpShouldHandleCookies = true
        do {
            let (data, resp) = try await urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GoodCloudError.relayUnavailable }
            return (data, http)
        } catch let e as URLError { throw GoodCloudError.transport(e) }
    }

    /// Installs the relay auth cookies for `.goodcloud.xyz` so they are sent to every rttys
    /// subdomain, including across the ssh→web redirect.
    private func setRelayCookies(into storage: HTTPCookieStorage) {
        // Both cookies carry the same session token (see get(...)).
        for (name, value) in [("gl-rtty-token", session.feToken), ("FE_TOKEN", session.feToken)] {
            guard let value, !value.isEmpty,
                  let cookie = HTTPCookie(properties: [
                      .name: name, .value: value, .domain: ".goodcloud.xyz", .path: "/",
                  ]) else { continue }
            storage.setCookie(cookie)
        }
    }
}
