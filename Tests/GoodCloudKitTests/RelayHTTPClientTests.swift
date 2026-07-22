import XCTest
@testable import GoodCloudKit

final class RelayHTTPClientTests: XCTestCase {
    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class RedirectLifecycleSession: RelayURLSessioning, @unchecked Sendable {
        let backing: URLSession

        init(backing: URLSession) {
            self.backing = backing
        }

        var relayCookieStorage: HTTPCookieStorage? {
            backing.configuration.httpCookieStorage
        }

        func data(
            for request: URLRequest,
            delegate: RelayHTTPClient.RedirectPolicy
        ) async throws -> (Data, URLResponse) {
            let (initialData, initialResponse) = try await backing.data(for: requestWithEligibleCookies(request))
            guard let redirected = await redirectRequest(
                from: request, response: initialResponse, delegate: delegate
            ) else { return (initialData, initialResponse) }
            return try await backing.data(for: requestWithEligibleCookies(redirected))
        }

        func bytes(
            for request: URLRequest,
            delegate: RelayHTTPClient.RedirectPolicy
        ) async throws -> (URLSession.AsyncBytes, URLResponse) {
            let (_, initialResponse) = try await backing.data(for: requestWithEligibleCookies(request))
            guard let redirected = await redirectRequest(
                from: request, response: initialResponse, delegate: delegate
            ) else {
                return try await backing.bytes(for: requestWithEligibleCookies(request))
            }
            return try await backing.bytes(for: requestWithEligibleCookies(redirected))
        }

        private func requestWithEligibleCookies(_ request: URLRequest) -> URLRequest {
            guard
                let url = request.url,
                let cookies = relayCookieStorage?.cookies(for: url),
                !cookies.isEmpty
            else { return request }
            var result = request
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                result.setValue(value, forHTTPHeaderField: name)
            }
            return result
        }

        private func redirectRequest(
            from original: URLRequest,
            response: URLResponse,
            delegate: RelayHTTPClient.RedirectPolicy
        ) async -> URLRequest? {
            guard
                let http = response as? HTTPURLResponse,
                (300..<400).contains(http.statusCode),
                let location = http.value(forHTTPHeaderField: "Location"),
                let destination = URL(string: location, relativeTo: original.url)?.absoluteURL
            else { return nil }

            var foundationRequest = original
            foundationRequest.url = destination
            foundationRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            if http.statusCode == 303 || ([301, 302].contains(http.statusCode) && original.httpMethod == "POST") {
                foundationRequest.httpMethod = "GET"
                foundationRequest.httpBody = nil
                foundationRequest.setValue(nil, forHTTPHeaderField: "Content-Type")
                foundationRequest.setValue(nil, forHTTPHeaderField: "Content-Length")
            }
            return await withCheckedContinuation { continuation in
                delegate.urlSession(
                    backing,
                    task: backing.dataTask(with: original),
                    willPerformHTTPRedirection: http,
                    newRequest: foundationRequest
                ) { continuation.resume(returning: $0) }
            }
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetStopLoading()
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.onStopLoading = nil
        super.tearDown()
    }

    private func session(relayBase: String, token: String?) -> RemoteAccessSession {
        RemoteAccessSession(baseURL: URL(string: relayBase)!, tokenDomain: ".goodcloud.xyz",
                            sessionID: "s", issuedAtMillis: 1, feToken: token)
    }

    private func makeClient() -> RelayHTTPClient {
        RelayHTTPClient(session: session(
            relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
            token: "FE-TOK"
        ), urlSession: StubURLProtocol.session())
    }

    private func finalCookieNames(_ request: URLRequest) -> [String] {
        (request.value(forHTTPHeaderField: "Cookie") ?? "")
            .split(separator: ";")
            .compactMap { $0.split(separator: "=", maxSplits: 1).first }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func originalRelayRequest(method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(
            string: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fapi%2Fv1%2Fstatus"
        )!)
        request.httpMethod = method
        request.setValue("Bearer wattline-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(method, forHTTPHeaderField: "X-Wattline-Request")
        request.httpBody = body
        return request
    }

    private func foundationRedirectRequest(from original: URLRequest, to destination: URL) -> URLRequest {
        var request = original
        request.url = destination
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        if original.httpMethod == "POST" {
            request.httpMethod = "GET"
            request.httpBody = nil
            request.setValue(nil, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func applyRedirectPolicy(
        original: URLRequest,
        responseURL: URL? = nil,
        destination: URL
    ) -> URLRequest? {
        let response = HTTPURLResponse(
            url: responseURL ?? original.url!, statusCode: 302,
            httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]
        )!
        let proposed = foundationRedirectRequest(from: original, to: destination)
        var result: URLRequest?
        RelayHTTPClient.RedirectPolicy(originalRequest: original).urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: original),
            willPerformHTTPRedirection: response,
            newRequest: proposed
        ) { result = $0 }
        return result
    }

    private func assertThrowsSessionExpired(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected sessionExpired", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GoodCloudError, .sessionExpired, file: file, line: line)
        }
    }

    private func assertStreamThrowsSessionExpired(
        _ stream: AsyncThrowingStream<RelayHTTPStreamEvent, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            for try await _ in stream {}
            XCTFail("expected sessionExpired", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GoodCloudError, .sessionExpired, file: file, line: line)
        }
    }

    func test_url_forTargetPath_encodesHostPortAndPathIntoLastSegment() throws {
        let s = session(relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F", token: "T")
        let c = RelayHTTPClient(session: s)
        let u = try c.url(forTargetPath: "status")
        XCTAssertEqual(u.absoluteString,
            "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fstatus")
    }

    func test_getInstallsHostOnlySecureSessionCookiesForExactRelayHosts() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:]) }
        // Verified live: gl-rtty-token AND FE_TOKEN both carry the session (FE) token.
        let s = RemoteAccessSession(
            baseURL: URL(string: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F")!,
            tokenDomain: ".goodcloud.xyz", sessionID: "s", issuedAtMillis: 1,
            relayToken: "ignored-content-id", feToken: "FE-TOK")
        let urlSession = StubURLProtocol.session()
        let suppliedStorage = try XCTUnwrap(urlSession.configuration.httpCookieStorage)
        let client = RelayHTTPClient(session: s, urlSession: urlSession)
        _ = try await client.get("status")
        let storage = try XCTUnwrap(client.relayCookieStorage)
        XCTAssertFalse(storage === suppliedStorage)
        XCTAssertTrue((suppliedStorage.cookies ?? []).isEmpty)
        let stored = storage.cookies ?? []
        XCTAssertEqual(stored.count, 4)
        XCTAssertTrue(stored.allSatisfy(\.isSecure))
        for host in ["rttys-ssh-cloud-us.goodcloud.xyz", "rttys-web-cloud-us.goodcloud.xyz"] {
            let eligible = storage.cookies(for: URL(string: "https://\(host)/")!) ?? []
            XCTAssertEqual(Set(eligible.map(\.name)), ["gl-rtty-token", "FE_TOKEN"])
            XCTAssertTrue(eligible.allSatisfy { $0.value == "FE-TOK" })
        }
        for ineligible in [
            "https://www.goodcloud.xyz/",
            "https://other.goodcloud.xyz/",
            "https://sub.rttys-ssh-cloud-us.goodcloud.xyz/",
            "http://rttys-ssh-cloud-us.goodcloud.xyz/",
            "http://rttys-web-cloud-us.goodcloud.xyz/",
        ] {
            XCTAssertTrue((storage.cookies(for: URL(string: ineligible)!) ?? []).isEmpty, ineligible)
        }
    }

    func test_defaultRelaySessionsUseIsolatedCookieStores() throws {
        let first = try XCTUnwrap(RelayHTTPClient.makeIsolatedURLSession().configuration.httpCookieStorage)
        let second = try XCTUnwrap(RelayHTTPClient.makeIsolatedURLSession().configuration.httpCookieStorage)
        let shared = try XCTUnwrap(URLSession.shared.configuration.httpCookieStorage)
        XCTAssertFalse(first === second)
        XCTAssertFalse(first === shared)
        XCTAssertFalse(second === shared)
    }

    func test_get_throwsWhenNoSessionToken() async {
        let s = RemoteAccessSession(baseURL: URL(string: "https://x.goodcloud.xyz/web/d/http/127.0.0.1%3A80%2F")!,
            tokenDomain: ".goodcloud.xyz", sessionID: "s", issuedAtMillis: 1, relayToken: "content-id", feToken: nil)
        let c = RelayHTTPClient(session: s, urlSession: StubURLProtocol.session())
        do { _ = try await c.get(""); XCTFail() } catch { XCTAssertEqual(error as? GoodCloudError, .relayUnavailable) }
    }

    func test_request_passesMethodHeadersAndBodyVerbatim() async throws {
        let body = Data(#"{"action":"dc_off"}"#.utf8)
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 200, data: Data(), headers: [:])
        }
        let client = RelayHTTPClient(session: session(
            relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
            token: "FE-TOK"
        ), urlSession: StubURLProtocol.session())

        _ = try await client.request(
            method: "POST",
            path: "/api/v1/device/action",
            headers: [
                "Authorization": "Bearer wattline-token",
                "Content-Type": "application/json",
            ],
            body: body
        )

        let captured = try XCTUnwrap(capture.requests.first)
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.httpBody, body)
        XCTAssertEqual(captured.url?.absoluteString,
            "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2Fapi%2Fv1%2Fdevice%2Faction")
    }

    func test_convenienceMethodsDelegateWithoutInventingHeadersOrBody() async throws {
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 200, data: Data(), headers: [:])
        }
        let client = RelayHTTPClient(session: session(
            relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
            token: "FE-TOK"
        ), urlSession: StubURLProtocol.session())
        _ = try await client.get("api/v1/status", headers: ["Accept": "application/json"])
        _ = try await client.post("api/v1/rules", body: Data("{}".utf8))
        _ = try await client.put("api/v1/rules/night", body: Data("{}".utf8))
        _ = try await client.delete("api/v1/rules/night")

        let requests = capture.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "PUT", "DELETE"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(requests[0].httpBody)
        XCTAssertEqual(requests[1].httpBody, Data("{}".utf8))
        XCTAssertEqual(requests[2].httpBody, Data("{}".utf8))
        XCTAssertNil(requests[3].httpBody)
    }

    func test_redirectToMatchingRelayWebHostPreservesEveryHTTPMethodHeadersAndBody() async throws {
        for method in ["GET", "POST", "PUT", "DELETE"] {
            let capture = RequestCapture()
            let body = method == "GET" ? nil : Data("body-\(method)".utf8)
            let original = originalRelayRequest(method: method, body: body)
            let destination = URL(
                string: "https://rttys-web-cloud-us.goodcloud.xyz\(original.url!.path)"
            )!
            let redirected = try XCTUnwrap(applyRedirectPolicy(
                original: original,
                destination: destination
            ))
            StubURLProtocol.handler = { request in
                capture.append(request)
                return .init(status: 200, data: Data("ok".utf8), headers: [:])
            }
            _ = try await StubURLProtocol.session().data(for: redirected)

            let final = try XCTUnwrap(capture.requests.last)
            XCTAssertEqual(capture.requests.count, 1, method)
            XCTAssertEqual(final.url?.host, "rttys-web-cloud-us.goodcloud.xyz", method)
            XCTAssertEqual(final.httpMethod, method, method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token", method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "X-Wattline-Request"), method, method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "Content-Type"), "application/json", method)
            XCTAssertEqual(final.httpBody, body, method)
        }
    }

    func test_streamRedirectToMatchingRelayWebHostPreservesHeaders() async throws {
        let capture = RequestCapture()
        var original = originalRelayRequest(method: "GET")
        original.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let policyRequest = try XCTUnwrap(applyRedirectPolicy(
            original: original,
            destination: URL(string: "https://rttys-web-cloud-us.goodcloud.xyz/events")!
        ))
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 200, data: Data("data: ready\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        }
        _ = try await StubURLProtocol.session().bytes(for: policyRequest)

        let redirected = try XCTUnwrap(capture.requests.last)
        XCTAssertEqual(capture.requests.count, 1)
        XCTAssertEqual(redirected.url?.host, "rttys-web-cloud-us.goodcloud.xyz")
        XCTAssertEqual(redirected.httpMethod, "GET")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
        XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func test_redirectDoesNotForwardCallerCredentialsToUnexpectedHostOrRelayHop() async throws {
        for location in [
            "https://attacker.example/steal",
            "https://other.goodcloud.xyz/steal",
            "https://rttys-web-cloud-eu.goodcloud.xyz/steal",
            "http://rttys-web-cloud-us.goodcloud.xyz/steal",
            "https://rttys-web-cloud-us.goodcloud.xyz:444/steal",
            "https://attacker@rttys-web-cloud-us.goodcloud.xyz/steal",
        ] {
            let original = originalRelayRequest(method: "POST", body: Data("secret-body".utf8))
            XCTAssertNil(applyRedirectPolicy(
                original: original,
                destination: URL(string: location)!
            ), location)
        }
    }

    func test_redirectFollowsOnlyOneMatchingRelayInternalHop() async throws {
        let original = originalRelayRequest(method: "GET")
        let firstDestination = URL(string: "https://rttys-web-cloud-us.goodcloud.xyz/first")!
        let first = try XCTUnwrap(applyRedirectPolicy(original: original, destination: firstDestination))
        XCTAssertNil(applyRedirectPolicy(
            original: original,
            responseURL: first.url,
            destination: URL(string: "https://rttys-web-cloud-us.goodcloud.xyz/second")!
        ))
    }

    func test_requestAPIDrivesRedirectLifecycleAndPreservesFinalRequest() async throws {
        for method in ["GET", "POST", "PUT", "DELETE"] {
            let capture = RequestCapture()
            StubURLProtocol.handler = { request in
                capture.append(request)
                if request.url?.host == "rttys-ssh-cloud-us.goodcloud.xyz" {
                    var destination = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    destination.host = "rttys-web-cloud-us.goodcloud.xyz"
                    destination.queryItems = [URLQueryItem(name: "_", value: "123")]
                    return .init(status: 302, data: Data(), headers: ["Location": destination.url!.absoluteString])
                }
                return .init(status: 200, data: Data("ok".utf8), headers: [:])
            }
            let body = method == "GET" ? nil : Data("body-\(method)".utf8)
            let backing = StubURLProtocol.session()
            let client = RelayHTTPClient(
                session: session(
                    relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
                    token: "FE-TOK"
                ),
                transport: RedirectLifecycleSession(backing: backing)
            )

            _ = try await client.request(
                method: method,
                path: "/api/v1/status",
                headers: [
                    "Authorization": "Bearer wattline-token",
                    "Content-Type": "application/json",
                    "Content-Encoding": "identity",
                    "X-Wattline-Request": method,
                ],
                body: body
            )

            let requests = capture.requests
            XCTAssertEqual(requests.count, 2, method)
            let initial = requests[0]
            let final = requests[1]
            XCTAssertEqual(initial.url?.host, "rttys-ssh-cloud-us.goodcloud.xyz", method)
            XCTAssertEqual(Set(finalCookieNames(initial)), ["FE_TOKEN", "gl-rtty-token"], method)
            XCTAssertEqual(final.url?.host, "rttys-web-cloud-us.goodcloud.xyz", method)
            XCTAssertEqual(final.url?.path, initial.url?.path, method)
            XCTAssertEqual(final.url?.query, "_=123", method)
            XCTAssertEqual(final.httpMethod, method, method)
            XCTAssertEqual(final.httpBody, body, method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token", method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "Content-Type"), "application/json", method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "Content-Encoding"), "identity", method)
            XCTAssertEqual(final.value(forHTTPHeaderField: "X-Wattline-Request"), method, method)
            XCTAssertEqual(Set(finalCookieNames(final)), ["FE_TOKEN", "gl-rtty-token"], method)
        }
    }

    func test_streamAPIDrivesRedirectLifecycleAndPreservesFinalRequest() async throws {
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            if request.url?.host == "rttys-ssh-cloud-us.goodcloud.xyz" {
                var destination = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                destination.host = "rttys-web-cloud-us.goodcloud.xyz"
                destination.query = "_=stream"
                return .init(status: 302, data: Data(), headers: ["Location": destination.url!.absoluteString])
            }
            return .init(status: 200, data: Data("data: ready\n\n".utf8), headers: ["Content-Type": "text/event-stream"])
        }
        let client = RelayHTTPClient(
            session: session(
                relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
                token: "FE-TOK"
            ),
            transport: RedirectLifecycleSession(backing: StubURLProtocol.session())
        )
        var received = Data()
        for try await event in client.stream(
            method: "GET",
            path: "/api/v1/events",
            headers: ["Authorization": "Bearer wattline-token", "Accept": "text/event-stream"]
        ) {
            if let data = event.testData { received.append(data) }
        }

        XCTAssertEqual(received, Data("data: ready\n\n".utf8))
        let requests = capture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].url?.host, "rttys-web-cloud-us.goodcloud.xyz")
        XCTAssertEqual(requests[1].url?.path, requests[0].url?.path)
        XCTAssertEqual(requests[1].url?.query, "_=stream")
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(Set(finalCookieNames(requests[1])), ["FE_TOKEN", "gl-rtty-token"])
    }

    func test_requestAPIRejectsHostileRedirectWithoutSendingAnotherRequest() async throws {
        let capture = RequestCapture()
        StubURLProtocol.handler = { request in
            capture.append(request)
            return .init(status: 302, data: Data(), headers: ["Location": "https://attacker.example/steal"])
        }
        let client = RelayHTTPClient(
            session: session(
                relayBase: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F",
                token: "FE-TOK"
            ),
            transport: RedirectLifecycleSession(backing: StubURLProtocol.session())
        )

        let (_, response) = try await client.post(
            "/api/v1/rules",
            headers: ["Authorization": "Bearer wattline-token", "Content-Type": "application/json"],
            body: Data("secret".utf8)
        )

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(capture.requests.count, 1)
    }

    func test_stream_emitsResponseThenIncrementalBodyChunks() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer wattline-token")
            return .init(status: 200, data: Data(), headers: ["Content-Type": "text/event-stream"],
                         chunks: [Data("data: one\n\n".utf8), Data("data: two\n\n".utf8)],
                         finish: false)
        }
        let client = makeClient()
        let expectedBody = Data("data: one\n\ndata: two\n\n".utf8)
        let task = Task { () throws -> (HTTPURLResponse, Data) in
            var iterator = client.stream(
                method: "GET", path: "/api/v1/events",
                headers: ["Authorization": "Bearer wattline-token", "Accept": "text/event-stream"]
            ).makeAsyncIterator()
            guard let first = try await iterator.next(), let response = first.testResponse else {
                XCTFail("response must be first")
                throw GoodCloudError.relayUnavailable
            }
            var body = Data()
            while body.count < expectedBody.count, let event = try await iterator.next() {
                if let chunk = event.testData { body.append(chunk) }
            }
            return (response, body)
        }
        let (response, body) = try await task.value
        task.cancel()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, expectedBody)
    }

    func test_streamCoalescesBytesInsteadOfEmittingOneDataEventPerByte() async throws {
        let body = Data((0..<100).map { UInt8(ascii: $0.isMultiple(of: 10) ? "\n" : "x") })
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: body, headers: ["Content-Type": "text/event-stream"])
        }
        var iterator = makeClient().stream(method: "GET", path: "api/v1/events").makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first?.testResponse)
        var received = Data()
        var dataEventCount = 0
        while let event = try await iterator.next() {
            if let data = event.testData {
                dataEventCount += 1
                received.append(data)
            }
        }
        XCTAssertEqual(received, body)
        XCTAssertLessThan(dataEventCount, body.count / 2)
    }

    func test_streamSplitsNewlineFreeBodyIntoBoundedChunksWithoutChangingBytes() async throws {
        let body = Data(repeating: UInt8(ascii: "x"), count: 40 * 1_024 + 7)
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: body, headers: ["Content-Type": "text/event-stream"])
        }
        var iterator = makeClient().stream(method: "GET", path: "api/v1/events").makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first?.testResponse)
        var chunks: [Data] = []
        while let event = try await iterator.next() {
            if let data = event.testData { chunks.append(data) }
        }
        XCTAssertEqual(Data(chunks.joined()), body)
        XCTAssertEqual(chunks.map(\.count), [16 * 1_024, 16 * 1_024, 8 * 1_024 + 7])
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 16 * 1_024 })
    }

    func test_streamFailsInsteadOfBufferingUnboundedDataForASlowConsumer() async throws {
        let body = Data(repeating: UInt8(ascii: "\n"), count: 10_000)
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: body, headers: ["Content-Type": "text/event-stream"])
        }
        var iterator = makeClient().stream(method: "GET", path: "api/v1/events").makeAsyncIterator()
        var dataEventCount = 0
        do {
            while let event = try await iterator.next() {
                if event.testData != nil { dataEventCount += 1 }
                for _ in 0..<10 { await Task.yield() }
            }
            XCTFail("expected bounded stream overflow")
        } catch {
            XCTAssertEqual(error as? GoodCloudError, .relayUnavailable)
        }
        XCTAssertLessThan(dataEventCount, body.count)
    }

    func test_streamCancellationStopsUnderlyingRequest() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 200, data: Data(), headers: ["Content-Type": "text/event-stream"],
                  finish: false)
        }
        let responseReceived = expectation(description: "stream response received")
        let requestStopped = expectation(description: "underlying request stopped")
        StubURLProtocol.onStopLoading = { requestStopped.fulfill() }
        let consumer = Task {
            var iterator = makeClient().stream(method: "GET", path: "api/v1/events").makeAsyncIterator()
            guard try await iterator.next()?.testResponse != nil else {
                return XCTFail("response must be first")
            }
            responseReceived.fulfill()
            _ = try await iterator.next()
        }

        await fulfillment(of: [responseReceived], timeout: 1)
        consumer.cancel()
        _ = await consumer.result
        await fulfillment(of: [requestStopped], timeout: 1)
        XCTAssertTrue(StubURLProtocol.didStopLoading)
    }

    func test_requestAndStreamMapRelayErrorPageToSessionExpired() async {
        StubURLProtocol.handler = { _ in
            .init(status: 404, data: Data(), headers: [:],
                  responseURL: URL(string: "https://rttys-web-cloud-us.goodcloud.xyz/gl-rtty/error.html"))
        }
        await assertThrowsSessionExpired { _ = try await self.makeClient().get("api/v1/status") }
        await assertStreamThrowsSessionExpired(self.makeClient().stream(method: "GET", path: "api/v1/events"))
    }

    func test_requestAndStreamPreserveOrdinaryTarget404() async throws {
        StubURLProtocol.handler = { _ in
            .init(status: 404, data: Data("missing".utf8), headers: [:])
        }

        let (data, response) = try await makeClient().get("api/v1/missing")
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(data, Data("missing".utf8))

        var iterator = makeClient().stream(method: "GET", path: "api/v1/missing").makeAsyncIterator()
        guard let streamResponse = try await iterator.next()?.testResponse else {
            return XCTFail("response must be first")
        }
        XCTAssertEqual(streamResponse.statusCode, 404)
    }
}

private extension RelayHTTPStreamEvent {
    var testResponse: HTTPURLResponse? {
        guard case .response(let response) = self else { return nil }
        return response
    }

    var testData: Data? {
        guard case .data(let data) = self else { return nil }
        return data
    }
}
