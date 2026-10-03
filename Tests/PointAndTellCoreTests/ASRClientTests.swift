import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PointAndTellCore

final class ASRClientTests: XCTestCase {
    func testRequestMatchesAudioOnlyFixture() throws {
        let request = try ASRRequestBuilder.makeRequest(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key")
        XCTAssertEqual(request.url, ASRProvider.endpoint)
        XCTAssertEqual(request.url?.absoluteString, "https://maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), "disable")
        let actual = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? NSDictionary)
        let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ASRFixtures.request.utf8)) as? NSDictionary)
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(ASRProvider.integrationVerified)
    }

    func testQwenTimelineModeMatchesDocumentedDurationBoundary() throws {
        for seconds in [1, 59, 60, 180] {
            let request = try ASRRequestBuilder.makeRequest(wav: ASRFixtures.wav(seconds: seconds), apiKey: "offline-test-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-DashScope-SSE"), seconds >= 60 ? "enable" : "disable")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), seconds >= 60 ? "text/event-stream, application/json" : "application/json")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "qwen-audio-3.0-asr-flash")
            XCTAssertNil(body["stream"])
        }
        XCTAssertEqual(ASRProvider.documentationURL.absoluteString, "https://www.qianwenai.com/models/qwen-audio-3.0-asr-flash")
    }

    func testFinalTextAndActualTimingGranularityArePreservedWithoutBilledRetry() {
        let cases = [ASRFixtures.missingTimingJSON, ASRFixtures.partialTimingJSON, ASRFixtures.fullTextJSON,
            #"{"output":{"text":"Only text"}}"#,
            #"{"output":{"sentence":{"text":"No words","begin_time":100,"end_time":1000,"sentence_end":true}}}"#,
            ASRFixtures.json.replacingOccurrences(of: "\"fixed\":true", with: "\"fixed\":false"),
            ASRFixtures.json.replacingOccurrences(of: "\"text\":\"world\"", with: "\"text\":\"incomplete\"")]
        for body in cases {
            let transport = ASRStubTransport()
            transport.response = .success(ASRHTTPResponse(statusCode: 200, data: Data(body.utf8), contentType: "application/json"))
            let done = expectation(description: "timestamp validation")
            ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
                if case .success(let sentences) = result {
                    XCTAssertFalse(sentences.isEmpty)
                    XCTAssertTrue(sentences.contains { !$0.transcriptSegment(chunkOffset: 0).hasCompleteWordTiming })
                } else { XCTFail("Final source text must remain available for manual review") }
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
            XCTAssertEqual(transport.requests.count, 1, "Never silently retry a billed request")
        }
    }

    func testEmptyAndHeaderInjectionKeysRejected() {
        XCTAssertThrowsError(try ASRRequestBuilder.makeRequest(wav: ASRFixtures.tinyWAV, apiKey: "   ")) {
            XCTAssertEqual($0 as? ASRError, .missingAPIKey)
        }
        XCTAssertThrowsError(try ASRRequestBuilder.makeRequest(wav: ASRFixtures.tinyWAV, apiKey: "key\r\nX-Other: injected")) {
            XCTAssertEqual($0 as? ASRError, .invalidAPIKey)
        }
    }

    func testStubTransportSuccessAndMainQueueCompletion() {
        let transport = ASRStubTransport()
        transport.response = .success(ASRHTTPResponse(statusCode: 200, data: Data(ASRFixtures.json.utf8), contentType: "application/json"))
        let finished = expectation(description: "complete")
        let client = ASRClient(transport: transport)
        client.transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case .success(let sentences): XCTAssertEqual(sentences.first?.text, "Hello world.")
            case .failure(let error): XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testSSEThroughStubTransport() {
        let transport = ASRStubTransport()
        transport.response = .success(ASRHTTPResponse(statusCode: 200, data: Data(ASRFixtures.sse.utf8), contentType: "text/event-stream"))
        let finished = expectation(description: "complete")
        ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            XCTAssertEqual(try? result.get().map(\.text), ["First.", "第二句。"])
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testInvalidAudioNeverReachesTransport() {
        let transport = ASRStubTransport()
        let finished = expectation(description: "validation complete")
        ASRClient(transport: transport).transcribe(wav: Data(), apiKey: "offline-test-key") { result in
            if case .failure(let error) = result {
                XCTAssertEqual((error as? ASRError)?.stage, .requestValidation)
                XCTAssertTrue(ASRError.safeDescription(for: error).contains("[Request validation]"))
            } else { XCTFail("Invalid audio was accepted") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testOversizedEncodedAudioNeverReachesTransport() {
        let transport = ASRStubTransport()
        let finished = expectation(description: "size validation")
        ASRClient(transport: transport).transcribe(wav: ASRFixtures.wav(seconds: 240), apiKey: "offline-test-key") { result in
            if case .failure(let error) = result { XCTAssertEqual(error as? ASRError, .encodedAudioTooLarge) }
            else { XCTFail("Oversized audio was accepted") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testHTTPFailureIsNotParsedAsSuccessOrRetried() {
        let transport = ASRStubTransport()
        transport.response = .success(ASRHTTPResponse(statusCode: 401, data: Data(ASRFixtures.providerError.utf8)))
        let finished = expectation(description: "failure")
        ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            switch result {
            case .success: XCTFail("Unauthorized response accepted")
            case .failure(let error):
                XCTAssertEqual(error as? ASRError, .httpStatus(401, code: "InvalidApiKey", requestID: "55555555-5555-4555-8555-555555555555"))
                XCTAssertFalse(error.localizedDescription.contains("offline-test-key"))
                XCTAssertFalse(error.localizedDescription.contains("Provider detail"))
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTransportFailureIsSafelyClassifiedWithoutRetry() {
        let transport = ASRStubTransport()
        transport.response = .failure(URLError(.timedOut))
        let finished = expectation(description: "timeout")
        ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            if case .failure(let error) = result { XCTAssertEqual(error as? ASRError, .transport(code: URLError.Code.timedOut.rawValue)) }
            else { XCTFail("Timeout accepted as success") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCancellationCompletesExactlyOnceAndCancelsUnderlyingTask() {
        let transport = ASRStubTransport()
        let client = ASRClient(transport: transport)
        let cancelled = expectation(description: "cancelled")
        let duplicated = expectation(description: "must not complete twice")
        duplicated.isInverted = true
        var completionCount = 0
        let handle = client.transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            completionCount += 1
            if completionCount > 1 { duplicated.fulfill(); return }
            if case .failure(let error) = result { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
            else { XCTFail("Cancellation reported success") }
            cancelled.fulfill()
        }
        handle.cancel()
        handle.cancel()
        transport.finish(.success(ASRHTTPResponse(statusCode: 200, data: Data(ASRFixtures.json.utf8))))
        wait(for: [cancelled, duplicated], timeout: 0.2)
        XCTAssertEqual(transport.handle.cancelCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    func testDuplicateTransportCallbacksCompleteOnlyOnce() {
        let transport = ASRStubTransport()
        let client = ASRClient(transport: transport)
        let finished = expectation(description: "complete")
        let duplicated = expectation(description: "must not complete twice")
        duplicated.isInverted = true
        var count = 0
        client.transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { _ in
            count += 1
            if count == 1 { finished.fulfill() } else { duplicated.fulfill() }
        }
        let response = ASRHTTPResponse(statusCode: 200, data: Data(ASRFixtures.json.utf8))
        transport.finish(.success(response)); transport.finish(.success(response))
        wait(for: [finished, duplicated], timeout: 0.2)
        XCTAssertEqual(count, 1)
    }

    func testClientDistinguishesHTTPProviderAndParsingFailures() {
        let cases: [(ASRHTTPResponse, ASRFailureStage)] = [
            (ASRHTTPResponse(statusCode: 400, data: Data(ASRFixtures.providerError.utf8)), .http),
            (ASRHTTPResponse(statusCode: 200, data: Data(ASRFixtures.providerError.utf8)), .provider),
            (ASRHTTPResponse(statusCode: 200, data: Data("<html>invalid</html>".utf8)), .responseParsing),
            (ASRHTTPResponse(statusCode: 200, data: Data(#"{"output":{"text":""}}"#.utf8)), .responseParsing)
        ]
        for (response, expectedStage) in cases {
            let transport = ASRStubTransport()
            transport.response = .success(response)
            let finished = expectation(description: "stage \(expectedStage.rawValue)")
            ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
                if case .failure(let error) = result {
                    XCTAssertEqual((error as? ASRError)?.stage, expectedStage)
                    XCTAssertFalse(ASRError.safeDescription(for: error).contains("offline-test-key"))
                } else { XCTFail("A failed response was accepted") }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testClientRedactsActualKeyFromHTTPAndProviderMetadata() {
        let key = "offline-test-key"
        let data = Data(#"{"code":"InvalidApiKey","request_id":"offline-test-key","message":"Authorization: Bearer offline-test-key"}"#.utf8)
        for status in [401, 200] {
            let transport = ASRStubTransport()
            transport.response = .success(ASRHTTPResponse(statusCode: status, data: data))
            let finished = expectation(description: "redacted \(status)")
            ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: key) { result in
                if case .failure(let error) = result {
                    XCTAssertFalse(error.localizedDescription.contains(key))
                    XCTAssertFalse(String(describing: error).contains(key))
                    if status == 401 {
                        XCTAssertEqual(error as? ASRError, .httpStatus(401, code: "InvalidApiKey", requestID: nil))
                    } else {
                        XCTAssertEqual(error as? ASRError, .provider(code: "InvalidApiKey", requestID: nil))
                    }
                } else { XCTFail("Provider rejection was accepted") }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

    func testClientTransportErrorDropsArbitraryProviderTextAndURL() {
        let transport = ASRStubTransport()
        transport.response = .failure(NSError(domain: "private-domain", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "https://example.invalid/private?key=offline-test-key data:audio/wav;base64,private"
        ]))
        let finished = expectation(description: "safe transport")
        ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: "offline-test-key") { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error as? ASRError, .transport(code: nil))
                XCTAssertTrue(error.localizedDescription.contains("[Transport]"))
                XCTAssertFalse(error.localizedDescription.contains("private"))
                XCTAssertFalse(error.localizedDescription.contains("offline-test-key"))
            } else { XCTFail("Transport failure accepted") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
    }


    func testClientRedactsUUIDShapedKeyBeforeCreatingPersistentDiagnostic() {
        let key = "21da954f-704d-4931-8fe5-444d8e6fe33f"
        let body = #"{"code":"InvalidApiKey","request_id":"21da954f-704d-4931-8fe5-444d8e6fe33f"}"#
        for status in [401, 200] {
            let transport = ASRStubTransport()
            transport.response = .success(ASRHTTPResponse(statusCode: status, data: Data(body.utf8)))
            let finished = expectation(description: "UUID key redaction")
            ASRClient(transport: transport).transcribe(wav: ASRFixtures.tinyWAV, apiKey: key) { result in
                if case .failure(let error) = result {
                    let diagnostic = ASRDiagnostic(error: error)
                    XCTAssertNotNil(diagnostic)
                    XCTAssertNil(diagnostic?.requestID)
                    XCTAssertFalse(diagnostic?.safeSummary.contains(key) ?? false)
                    XCTAssertFalse(error.localizedDescription.contains(key))
                } else { XCTFail("Rejected request was accepted") }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
        }
    }

}

private final class ASRStubHandle: ASRCancellable {
    private(set) var cancelCount = 0
    func cancel() { cancelCount += 1 }
}

private final class ASRStubTransport: ASRTransport {
    let handle = ASRStubHandle()
    var response: Result<ASRHTTPResponse, Error>?
    private(set) var requests: [URLRequest] = []
    private var completion: ((Result<ASRHTTPResponse, Error>) -> Void)?
    func send(_ request: URLRequest,
              completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) -> ASRCancellable {
        requests.append(request)
        self.completion = completion
        if let response = response { completion(response) }
        return handle
    }
    func finish(_ result: Result<ASRHTTPResponse, Error>) { completion?(result) }
}
