import Foundation

public enum RelayHTTPStreamEvent: @unchecked Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

/// Consumes a provisioned `RemoteAccessSession` to speak HTTP to the LAN target behind an
/// rtty relay, authenticating with the `gl-rtty-token` cookie captured during provisioning.
public struct RelayHTTPClient: Sendable {
    private let session: RemoteAccessSession
    private let urlSession: any RelayURLSessioning
    public init(session: RemoteAccessSession, urlSession: URLSession? = nil) {
        self.session = session
        self.urlSession = RelayURLSessionBridge(
            session: Self.makeIsolatedURLSession(copying: urlSession)
        )
    }

    init(session: RemoteAccessSession, transport: any RelayURLSessioning) {
        self.session = session
        self.urlSession = transport
    }

    var relayCookieStorage: HTTPCookieStorage? {
        urlSession.relayCookieStorage
    }

    static func makeIsolatedURLSession(copying session: URLSession? = nil) -> URLSession {
        let configuration = session?.configuration ?? .ephemeral
        configuration.httpCookieStorage = URLSessionConfiguration.ephemeral.httpCookieStorage
        return URLSession(
            configuration: configuration,
            delegate: session?.delegate,
            delegateQueue: session?.delegateQueue
        )
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
        do {
            let request = try makeRequest(method: method, path: path, headers: headers, body: body)
            let (data, response) = try await urlSession.data(
                for: request,
                delegate: RedirectPolicy(originalRequest: request)
            )
            guard let http = response as? HTTPURLResponse else { throw GoodCloudError.relayUnavailable }
            guard !Self.isExpiredRelay(response: http) else { throw GoodCloudError.sessionExpired }
            return (data, http)
        } catch let error as GoodCloudError {
            throw error
        } catch let error as URLError {
            throw GoodCloudError.transport(error)
        }
    }

    public func stream(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> AsyncThrowingStream<RelayHTTPStreamEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(method: method, path: path, headers: headers, body: body)
                    let (bytes, response) = try await urlSession.bytes(
                        for: request,
                        delegate: RedirectPolicy(originalRequest: request)
                    )
                    guard let http = response as? HTTPURLResponse else {
                        throw GoodCloudError.relayUnavailable
                    }
                    guard !Self.isExpiredRelay(response: http) else {
                        throw GoodCloudError.sessionExpired
                    }
                    try Self.yield(.response(http), to: continuation)
                    var chunk = Data()
                    chunk.reserveCapacity(16 * 1_024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == UInt8(ascii: "\n") || chunk.count == 16 * 1_024 {
                            try Self.yield(.data(chunk), to: continuation)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        try Self.yield(.data(chunk), to: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch let error as GoodCloudError {
                    continuation.finish(throwing: error)
                } catch let error as URLError {
                    continuation.finish(throwing: GoodCloudError.transport(error))
                } catch {
                    continuation.finish(throwing: GoodCloudError.relayUnavailable)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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

    private func makeRequest(
        method: String,
        path: String,
        headers: [String: String],
        body: Data?
    ) throws -> URLRequest {
        // The relay host authenticates via `.goodcloud.xyz` cookies. Verified live: the web
        // client sets BOTH `gl-rtty-token` and `FE_TOKEN` to the SAME value — the session token
        // (`gl-rtty-token = V7()` = the FE_TOKEN cookie). The relay URL is on `rttys-ssh-*` and
        // 302-redirects to `rttys-web-*`; a *manual* Cookie header is stripped on that cross-host
        // redirect, so we install host-only Secure cookies for the exact ssh and matching web
        // relay hosts. URLSession then sends the eligible cookie at each side of the trusted hop.
        guard let fe = session.feToken, !fe.isEmpty else { throw GoodCloudError.relayUnavailable }
        let requestURL = try url(forTargetPath: normalized(path))
        if let storage = urlSession.relayCookieStorage {
            setRelayCookies(into: storage, originalRelayURL: requestURL)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpShouldHandleCookies = true
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    private static func isExpiredRelay(response: HTTPURLResponse) -> Bool {
        response.url?.path.hasSuffix("/gl-rtty/error.html") == true
    }

    private static func matchingWebRelayHost(forSSHHost host: String) -> String? {
        let host = host.lowercased()
        guard host.hasPrefix("rttys-ssh-"), host.hasSuffix(".goodcloud.xyz") else {
            return nil
        }
        return "rttys-web-\(host.dropFirst("rttys-ssh-".count))"
    }

    private static func yield(
        _ event: RelayHTTPStreamEvent,
        to continuation: AsyncThrowingStream<RelayHTTPStreamEvent, Error>.Continuation
    ) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            throw GoodCloudError.relayUnavailable
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw GoodCloudError.relayUnavailable
        }
    }

    /// Per-task delegate that permits exactly the relay's first HTTPS `rttys-ssh-*` → matching
    /// `rttys-web-*` hop. Foundation's synthesized cross-host request is deliberately discarded:
    /// it rewrites POST to GET and removes caller authorization. Rebuilding from the original
    /// request preserves Wattline's independent credentials and payload only for this trusted hop.
    final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        private let originalRequest: URLRequest

        init(originalRequest: URLRequest) {
            self.originalRequest = originalRequest
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard Self.isExpectedRelayHop(
                originalURL: originalRequest.url,
                responseURL: response.url,
                destinationURL: request.url
            ) else {
                completionHandler(nil)
                return
            }
            var preserved = originalRequest
            preserved.url = request.url
            completionHandler(preserved)
        }

        private static func isExpectedRelayHop(
            originalURL: URL?, responseURL: URL?, destinationURL: URL?
        ) -> Bool {
            guard
                let originalURL,
                let responseURL,
                let destinationURL,
                originalURL.scheme?.lowercased() == "https",
                responseURL.scheme?.lowercased() == "https",
                destinationURL.scheme?.lowercased() == "https",
                originalURL.port == nil || originalURL.port == 443,
                responseURL.port == originalURL.port,
                destinationURL.port == originalURL.port,
                destinationURL.user == nil,
                destinationURL.password == nil,
                let originalHost = originalURL.host?.lowercased(),
                let responseHost = responseURL.host?.lowercased(),
                let destinationHost = destinationURL.host?.lowercased(),
                let expectedDestinationHost = RelayHTTPClient.matchingWebRelayHost(forSSHHost: originalHost),
                responseHost == originalHost
            else { return false }

            return destinationHost == expectedDestinationHost
        }
    }

    /// Installs host-only Secure relay auth cookies for the exact ssh host and its matching web
    /// redirect host. No other GoodCloud service, subdomain, or plaintext request is eligible.
    private func setRelayCookies(into storage: HTTPCookieStorage, originalRelayURL: URL) {
        guard
            originalRelayURL.scheme?.lowercased() == "https",
            originalRelayURL.port == nil || originalRelayURL.port == 443,
            let sshHost = originalRelayURL.host?.lowercased(),
            let webHost = Self.matchingWebRelayHost(forSSHHost: sshHost)
        else { return }

        // Both cookies carry the same session token (see get(...)).
        for host in [sshHost, webHost] {
            var origin = URLComponents()
            origin.scheme = "https"
            origin.host = host
            origin.port = originalRelayURL.port
            guard let originURL = origin.url else { continue }
            for (name, value) in [("gl-rtty-token", session.feToken), ("FE_TOKEN", session.feToken)] {
                guard let value, !value.isEmpty,
                      let cookie = HTTPCookie(properties: [
                          .originURL: originURL,
                          .name: name,
                          .value: value,
                          .path: "/",
                          .secure: "TRUE",
                      ]) else { continue }
                storage.setCookie(cookie)
            }
        }
    }
}

protocol RelayURLSessioning: Sendable {
    var relayCookieStorage: HTTPCookieStorage? { get }

    func data(
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy
    ) async throws -> (Data, URLResponse)

    func bytes(
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy
    ) async throws -> (URLSession.AsyncBytes, URLResponse)
}

struct RelayURLSessionBridge: RelayURLSessioning {
    let session: URLSession
    let calls: any RelayURLSessionCalling

    init(
        session: URLSession,
        calls: any RelayURLSessionCalling = FoundationRelayURLSessionCalls()
    ) {
        self.session = session
        self.calls = calls
    }

    var relayCookieStorage: HTTPCookieStorage? {
        session.configuration.httpCookieStorage
    }

    func data(
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy
    ) async throws -> (Data, URLResponse) {
        try await calls.data(using: session, for: request, delegate: delegate)
    }

    func bytes(
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await calls.bytes(using: session, for: request, delegate: delegate)
    }
}

protocol RelayURLSessionCalling: Sendable {
    func data(
        using session: URLSession,
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy?
    ) async throws -> (Data, URLResponse)

    func bytes(
        using session: URLSession,
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy?
    ) async throws -> (URLSession.AsyncBytes, URLResponse)
}

struct FoundationRelayURLSessionCalls: RelayURLSessionCalling {
    func data(
        using session: URLSession,
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy?
    ) async throws -> (Data, URLResponse) {
        guard let delegate else { return try await session.data(for: request) }
        return try await session.data(for: request, delegate: delegate)
    }

    func bytes(
        using session: URLSession,
        for request: URLRequest,
        delegate: RelayHTTPClient.RedirectPolicy?
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let delegate else { return try await session.bytes(for: request) }
        return try await session.bytes(for: request, delegate: delegate)
    }
}
