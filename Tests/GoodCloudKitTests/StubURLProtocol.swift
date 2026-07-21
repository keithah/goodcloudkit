import Foundation

/// Test-only URLProtocol that returns a canned response per request.
final class StubURLProtocol: URLProtocol {
    struct Stub { let status: Int; let data: Data; let headers: [String: String] }
    /// Set before each test. Receives the outgoing request (for assertions) and returns a stub.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("StubURLProtocol.handler not set") }
        let stub = handler(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                   httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
