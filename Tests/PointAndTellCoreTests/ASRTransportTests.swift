import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PointAndTellCore

/// Exercises the real URLSession delegate transport through an in-memory protocol.
/// The protocol handles every fixture request; no credential or network is used.
final class ASRTransportTests: XCTestCase {
    func testTransportAcceptsBodyAtExactLimit() {
        let finished = expectation(description: "bounded response")
        let transport = makeTransport(limit: 16)
        transport.send(request("exact-limit")) { result in
            switch result {
            case .success(let response):
                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(response.data, Data(repeating: 65, count: 16))
            case .failure(let error): XCTFail("Unexpected failure: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }

    func testTransportRejectsOversizedDeclaredLength() {
        assertSizeFailure(scenario: "declared-overflow")
    }

    func testTransportRejectsOversizedStreamWithoutContentLength() {
        assertSizeFailure(scenario: "stream-overflow")
    }

    func testTransportRejectsBodyLargerThanClaimedContentLength() {
        assertSizeFailure(scenario: "false-length")
    }

    func testTransportCancellationCompletesExactlyOnce() {
        let cancelled = expectation(description: "cancelled")
        let duplicate = expectation(description: "no repeated completion")
        duplicate.isInverted = true
        let transport = makeTransport(limit: 16)
        var count = 0
        let handle = transport.send(request("held-open")) { result in
            count += 1
            guard count == 1 else { duplicate.fulfill(); return }
            if case .failure(let error) = result { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
            else { XCTFail("Cancellation succeeded unexpectedly") }
            cancelled.fulfill()
        }
        handle.cancel()
        handle.cancel()
        wait(for: [cancelled, duplicate], timeout: 0.2)
    }

    func testRequestDelegateIsReleasedAfterCompletion() {
        let finished = expectation(description: "finished")
        let transport = makeTransport(limit: 16)
        weak var operation: ASRURLSessionRequest?
        drainingAutoreleasePool {
            var handle: ASRCancellable? = transport.send(request("exact-limit")) { _ in finished.fulfill() }
            operation = handle as? ASRURLSessionRequest
            handle = nil
        }
        wait(for: [finished], timeout: 3)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in operation == nil }, object: nil)
        wait(for: [released], timeout: 3)
    }

    func testRequestDelegateIsReleasedAfterSizeFailure() {
        let finished = expectation(description: "failed")
        let transport = makeTransport(limit: 16)
        weak var operation: ASRURLSessionRequest?
        drainingAutoreleasePool {
            var handle: ASRCancellable? = transport.send(request("stream-overflow")) { _ in finished.fulfill() }
            operation = handle as? ASRURLSessionRequest
            handle = nil
        }
        wait(for: [finished], timeout: 3)
        let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in operation == nil }, object: nil)
        wait(for: [released], timeout: 3)
    }

    func testRedirectDelegateDeclinesDestinationWithoutSendingIt() throws {
        // FoundationNetworking cannot simulate URLProtocol redirects on Linux.
        // Invoke the actual transport delegate hook with an unresumed local task.
        let session = URLSession(configuration: fixtureConfiguration())
        defer { session.invalidateAndCancel() }
        let original = request("exact-limit")
        let task = session.dataTask(with: original)
        let redirectURL = try XCTUnwrap(URL(string: "https://different-destination.invalid/audio"))
        let response = try XCTUnwrap(HTTPURLResponse(url: ASRProvider.endpoint, statusCode: 302,
                                                     httpVersion: nil, headerFields: ["Location": redirectURL.absoluteString]))
        let operation = ASRURLSessionRequest(maximumResponseBytes: 16) { _ in }
        var called = false
        operation.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: redirectURL)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    func testCallerCannotRaiseMaximumResponseCap() {
        let transport = ASRURLSessionTransport(configuration: fixtureConfiguration(), maximumResponseBytes: Int.max)
        XCTAssertEqual(transport.maximumResponseBytes, 8 * 1_024 * 1_024)
    }

    private func assertSizeFailure(scenario: String, file: StaticString = #filePath, line: UInt = #line) {
        let finished = expectation(description: "size failure")
        let duplicate = expectation(description: "no repeated completion")
        duplicate.isInverted = true
        let transport = makeTransport(limit: 16)
        var count = 0
        transport.send(request(scenario)) { result in
            count += 1
            guard count == 1 else { duplicate.fulfill(); return }
            if case .failure(let error) = result {
                XCTAssertEqual(error as? ASRError, .responseTooLarge, file: file, line: line)
            } else { XCTFail("Oversized response was accepted", file: file, line: line) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        wait(for: [duplicate], timeout: 0.1)
    }

    private func makeTransport(limit: Int) -> ASRURLSessionTransport {
        ASRURLSessionTransport(configuration: fixtureConfiguration(), maximumResponseBytes: limit)
    }

    private func fixtureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ASRFixtureURLProtocol.self]
        return configuration
    }

    private func request(_ scenario: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://asr-fixture.invalid/\(scenario)")!)
        request.httpMethod = "POST"
        request.setValue(scenario, forHTTPHeaderField: "X-ASR-Test-Scenario")
        return request
    }

    /// URLSession and URLSessionTask bridge through Objective-C. Drain creation
    /// temporaries before checking weak lifetime; XCTest's wait loop does not
    /// establish an autorelease-pool boundary for the enclosing test method.
    private func drainingAutoreleasePool(_ body: () -> Void) {
        #if canImport(ObjectiveC)
        autoreleasepool(invoking: body)
        #else
        body()
        #endif
    }
}

private final class ASRFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-ASR-Test-Scenario") ?? ""
        var headers = ["Content-Type": "application/json"]
        switch scenario {
        case "declared-overflow": headers["Content-Length"] = "17"
        case "exact-limit": headers["Content-Length"] = "16"
        case "false-length": headers["Content-Length"] = "4"
        default: break
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch scenario {
        case "exact-limit":
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8))
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 8))
        case "stream-overflow", "false-length":
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 10))
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 10))
        case "held-open": return
        default: break
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
