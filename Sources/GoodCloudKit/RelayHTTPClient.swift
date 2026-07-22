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

    public func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
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
        var request = URLRequest(url: try url(forTargetPath: normalized(path)))
        request.httpMethod = method
        request.httpShouldHandleCookies = true
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        do {
            let (data, response) = try await urlSession.data(for: request, delegate: RedirectPolicy())
            guard let http = response as? HTTPURLResponse else { throw GoodCloudError.relayUnavailable }
            return (data, http)
        } catch let error as GoodCloudError {
            throw error
        } catch let error as URLError {
            throw GoodCloudError.transport(error)
        }
    }

    public func get(_ path: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        try await request(method: "GET", path: path, headers: headers)
    }

    public func post(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await request(method: "POST", path: path, headers: headers, body: body)
    }

    public func put(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await request(method: "PUT", path: path, headers: headers, body: body)
    }

    public func delete(_ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        try await request(method: "DELETE", path: path, headers: headers, body: body)
    }

    private func normalized(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }

    /// Whether a redirect should be followed. We follow the relay's own `rttys-ssh → rttys-web`
    /// hop (a `goodcloud.xyz` host), but NOT a redirect the *proxied target* emits — e.g. the GL
    /// admin UI 302-ing to `http://192.168.8.1`. Following that unreachable LAN address would
    /// surface as `.transport(-1004)`; instead we stop and return the 3xx to the caller.
    static func shouldFollowRedirect(toHost host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return host == "goodcloud.xyz" || host.hasSuffix(".goodcloud.xyz")
    }

    /// Per-task delegate enforcing `shouldFollowRedirect`.
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(RelayHTTPClient.shouldFollowRedirect(toHost: request.url?.host) ? request : nil)
        }
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
