import Foundation

/// Test-only URLProtocol that returns a canned response per request.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let status: Int
        let data: Data
        let headers: [String: String]
        let chunks: [Data]
        let finish: Bool
        let responseURL: URL?

        init(status: Int, data: Data, headers: [String: String], chunks: [Data] = [],
             finish: Bool = true, responseURL: URL? = nil) {
            self.status = status
            self.data = data
            self.headers = headers
            self.chunks = chunks
            self.finish = finish
            self.responseURL = responseURL
        }
    }
    /// Set before each test. Receives the outgoing request (for assertions) and returns a stub.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?
    private static let stopLock = NSLock()
    nonisolated(unsafe) private static var recordedStopLoading = false

    static var didStopLoading: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return recordedStopLoading
    }

    static func resetStopLoading() {
        stopLock.lock()
        recordedStopLoading = false
        stopLock.unlock()
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("StubURLProtocol.handler not set") }
        var currentRequest = request
        if currentRequest.httpBody == nil, let stream = currentRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            currentRequest.httpBody = body
        }
        let stub = handler(currentRequest)
        let resp = HTTPURLResponse(url: stub.responseURL ?? request.url!, statusCode: stub.status,
                                   httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if stub.chunks.isEmpty {
            client?.urlProtocol(self, didLoad: stub.data)
        } else {
            for chunk in stub.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
        }
        if stub.finish {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        Self.stopLock.lock()
        Self.recordedStopLoading = true
        Self.stopLock.unlock()
    }
}
