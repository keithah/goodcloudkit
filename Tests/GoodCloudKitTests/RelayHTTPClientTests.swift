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

    override func setUp() {
        super.setUp()
        StubURLProtocol.resetStopLoading()
    }

    override func tearDown() { StubURLProtocol.handler = nil; super.tearDown() }

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

    func test_get_installsSessionTokenAsBothCookiesForGoodcloudDomain() async throws {
        StubURLProtocol.handler = { _ in .init(status: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:]) }
        // Verified live: gl-rtty-token AND FE_TOKEN both carry the session (FE) token.
        let s = RemoteAccessSession(
            baseURL: URL(string: "https://rttys-ssh-cloud-us.goodcloud.xyz/web/demo01/http/127.0.0.1%3A8377%2F")!,
            tokenDomain: ".goodcloud.xyz", sessionID: "s", issuedAtMillis: 1,
            relayToken: "ignored-content-id", feToken: "FE-TOK")
        let urlSession = StubURLProtocol.session()
        _ = try await RelayHTTPClient(session: s, urlSession: urlSession).get("status")
        let stored = urlSession.configuration.httpCookieStorage?.cookies ?? []
        let byName = Dictionary(uniqueKeysWithValues: stored.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["gl-rtty-token"], "FE-TOK")   // session token, not content.id
        XCTAssertEqual(byName["FE_TOKEN"], "FE-TOK")
        XCTAssertTrue(stored.allSatisfy { $0.domain.contains("goodcloud.xyz") })
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
        for _ in 0..<1_000 where !StubURLProtocol.didStopLoading {
            await Task.yield()
        }

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
