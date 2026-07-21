import Foundation

public actor SignedAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let signer: RequestSigner
    private let tokens: TokenProvider

    public init(baseURL: URL = URL(string: "https://api.goodcloud.xyz")!,
                session: URLSession = .shared,
                signer: RequestSigner = .goodCloud(),
                tokens: TokenProvider) {
        self.baseURL = baseURL
        self.session = session
        self.signer = signer
        self.tokens = tokens
    }

    public func get<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                                as type: Info.Type) async throws -> Info {
        try await sendReturningResponse(method: "GET", path: path, query: query, body: nil, as: type).0
    }

    public func post<Info: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = [],
                                                 body: Data? = nil, as type: Info.Type) async throws -> Info {
        try await sendReturningResponse(method: "POST", path: path, query: query, body: body, as: type).0
    }

    /// The current session token (`FE_TOKEN`), for callers that need it beyond header injection
    /// — e.g. `remoteAccess` embedding it as a relay cookie.
    public func currentAuthToken() async throws -> String { try await tokens.token() }

    /// Like `get`/`post`, but also surfaces the raw `HTTPURLResponse` for callers that need
    /// response headers (e.g. `remoteAccess` reading `Set-Cookie: gl-rtty-token`).
    func sendReturningResponse<Info: Decodable & Sendable>(method: String, path: String,
                                                           query: [URLQueryItem], body: Data?,
                                                           as type: Info.Type) async throws -> (Info, HTTPURLResponse) {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw GoodCloudError.decoding("bad url for \(path)") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(try await tokens.token(), forHTTPHeaderField: "token")
        req.setValue(try signer.signature(), forHTTPHeaderField: "signature")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw GoodCloudError.transport(e)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoodCloudError.decoding("response for \(path) was not an HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw GoodCloudError.httpStatus(http.statusCode)
        }

        do {
            let envelope = try JSONDecoder().decode(APIResponse<Info>.self, from: data)
            return (try envelope.unwrap(), http)
        } catch let e as GoodCloudError {
            throw e
        } catch {
            throw GoodCloudError.decoding("\(error)")
        }
    }
}
