import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PointAndTellCore

/// Privacy assertions use synthetic values only. No real account or network is used.
final class ASRErrorTests: XCTestCase {
    func testFailureStagesDistinguishEveryPipelineBoundary() {
        let values: [(ASRError, ASRFailureStage)] = [
            (.missingAPIKey, .requestValidation), (.invalidAPIKey, .requestValidation),
            (.invalidWAV("untrusted"), .requestValidation), (.audioTooLong, .requestValidation),
            (.encodedAudioTooLarge, .requestValidation), (.requestEncoding, .requestValidation),
            (.transport(code: URLError.Code.timedOut.rawValue), .transport),
            (.invalidHTTPResponse, .transport), (.responseTooLarge, .transport),
            (.httpStatus(400, code: nil, requestID: nil), .http),
            (.provider(code: "InvalidParameter", requestID: nil), .provider),
            (.malformedResponse, .responseParsing), (.noFinalSentences, .responseParsing)
        ]
        for (error, stage) in values {
            XCTAssertEqual(error.stage, stage)
            XCTAssertTrue(error.localizedDescription.contains("[\(stage.rawValue)]"))
        }
    }

    func testHTTPStatusCodeRequestIDAndMappedReasonAreVisible() {
        let error = ASRError.httpStatus(401, code: "InvalidApiKey", requestID: "req-123")
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("[HTTP]"))
        XCTAssertTrue(text.contains("HTTP 401"))
        XCTAssertTrue(text.contains("code InvalidApiKey"))
        XCTAssertTrue(text.contains("request ID req-123"))
        XCTAssertTrue(text.contains("Authentication was rejected"))
    }

    func testProviderFailureIncludesSafeMetadataButNeverProviderMessage() throws {
        let payload: [String: Any] = [
            "code": "InvalidParameter",
            "request_id": "req-123",
            "message": "Authorization: Bearer synthetic-private-key; https://example.invalid/private; data:audio/wav;base64,UklGRPRIVATE; secret speech transcript",
            "output": ["echoed_request": "never display this"]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try ASRResponseParser.parse(data: data)) {
            XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidParameter", requestID: "req-123"))
            let text = ASRError.safeDescription(for: $0)
            XCTAssertTrue(text.contains("[Provider]"))
            XCTAssertTrue(text.contains("code InvalidParameter"))
            XCTAssertTrue(text.contains("request ID req-123"))
            XCTAssertTrue(text.contains("request parameter"))
            for secret in ["synthetic-private-key", "https://", "data:audio", "UklGRPRIVATE", "secret speech", "echoed_request"] {
                XCTAssertFalse(text.contains(secret))
            }
        }
    }

    func testUnknownProviderReasonAndCodeAreOmittedEvenWhenPlausible() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "code": "PrivateSpeechToken",
            "message": "The provided key synthetic-private-key was invalid.",
            "request_id": "req-unknown"
        ])
        XCTAssertThrowsError(try ASRResponseParser.parse(data: data)) {
            XCTAssertEqual($0 as? ASRError, .provider(code: "UnrecognizedProviderError", requestID: "req-unknown"))
            XCTAssertFalse(String(describing: $0).contains("PrivateSpeechToken"))
            XCTAssertFalse($0.localizedDescription.contains("synthetic-private-key"))
            XCTAssertTrue($0.localizedDescription.contains("No safe reason"))
        }
    }

    func testCodeAllowlistCannotEchoSecretsOrRawResponse() {
        for value in ["synthetic-private-key", "sk-secret", "InvalidApiKey\nAuthorization: Bearer secret",
                      "https://example.invalid/key", "data:audio/wav;base64,UklGR",
                      "{\"model\":\"private-model\"}", String(repeating: "A", count: 1000)] {
            XCTAssertNil(ASRSafeDiagnostics.code(value))
            let text = ASRError.provider(code: value, requestID: nil).localizedDescription
            XCTAssertFalse(text.contains(value))
        }
    }

    func testRequestIDRejectsURLsCredentialsAudioProseAndOversizedValues() {
        let values = [
            "https://example.invalid/private", "data:audio/wav;base64,UklGR",
            "Bearer synthetic-private-key", "sk-secret", "authorization-secret",
            "req-123\nsecret", "req-123\u{202E}secret", "私密内容",
            "UklGRiYAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQIAAAAAAA==",
            String(repeating: "A", count: 1000), "plainprivateword",
            "{\"request\":\"private\"}", "speech with spaces"
        ]
        for value in values {
            XCTAssertNil(ASRSafeDiagnostics.requestID(value), value)
            XCTAssertFalse(ASRError.httpStatus(400, code: nil, requestID: value).localizedDescription.contains(value))
        }
    }

    func testActualKeyAndItsBase64AreRedactedFromOtherwiseValidMetadata() throws {
        let key = "offline-test-key"
        for requestID in [key, "req-\(key)", key.uppercased(), Data(key.utf8).base64EncodedString()] {
            let data = try JSONSerialization.data(withJSONObject: [
                "code": "InvalidApiKey", "request_id": requestID, "message": key
            ])
            let metadata = ASRResponseParser.errorMetadata(data, redactingSecrets: [key])
            XCTAssertEqual(metadata.code, "InvalidApiKey")
            XCTAssertNil(metadata.requestID)
            XCTAssertThrowsError(try ASRResponseParser.parse(data: data, redactingSecrets: [key])) {
                XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidApiKey", requestID: nil))
                XCTAssertFalse(String(describing: $0).lowercased().contains(key))
            }
        }
    }

    func testAllowlistedCodeThatEqualsTheKeyIsStillRedacted() throws {
        let data = Data(#"{"code":"InvalidApiKey","request_id":"req-123"}"#.utf8)
        let metadata = ASRResponseParser.errorMetadata(data, redactingSecrets: ["InvalidApiKey"])
        XCTAssertNil(metadata.code)
        XCTAssertThrowsError(try ASRResponseParser.parse(data: data, redactingSecrets: ["InvalidApiKey"])) {
            XCTAssertFalse(String(describing: $0).contains("InvalidApiKey"))
        }
    }

    func testValidRequestIdentifiersRemainAvailable() {
        for value in ["req-123", "fixture-error", "request_001",
                      "21da954f-704d-4931-8fe5-444d8e6fe33f",
                      "21da954f704d49318fe5444d8e6fe33f"] {
            XCTAssertEqual(ASRSafeDiagnostics.requestID(value), value)
        }
    }

    func testHTTPMetadataSurvivesMalformedOutputAndUntrustedMessageShape() {
        let data = Data(#"{"code":"InvalidParameter","request_id":"req-456","message":{"request":"secret"},"output":17}"#.utf8)
        let metadata = ASRResponseParser.errorMetadata(data)
        XCTAssertEqual(metadata.code, "InvalidParameter")
        XCTAssertEqual(metadata.requestID, "req-456")
        XCTAssertThrowsError(try ASRResponseParser.parse(data: data)) {
            XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidParameter", requestID: "req-456"))
        }
    }

    func testSSEErrorAfterFinalTextCannotLeakProviderMessage() {
        let event = #"{"code":"InvalidParameter","message":"Bearer private-key","request_id":"req-789"}"#
        let data = Data("data: \(ASRFixtures.json)\n\ndata: \(event)\n\n".utf8)
        XCTAssertThrowsError(try ASRResponseParser.parse(data: data)) {
            XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidParameter", requestID: "req-789"))
            XCTAssertFalse($0.localizedDescription.contains("private-key"))
        }
    }

    func testWhitespaceOnlyJSONAndSSEDoNotProduceSuccessfulEmptyCards() {
        let json = #"{"output":{"sentence":{"text":" \n\t ","sentence_end":true}}}"#
        for value in [json, "data: \(json)\n\n", #"{"output":{"text":" \n "}}"#] {
            XCTAssertThrowsError(try ASRResponseParser.parse(data: Data(value.utf8))) {
                XCTAssertEqual($0 as? ASRError, .noFinalSentences)
            }
        }
    }

    func testBlankTranscriptExplainsRecordingCheckWithoutBlamingKey() {
        let text = ASRError.noFinalSentences.localizedDescription
        XCTAssertTrue(text.contains("[Response parsing]"))
        XCTAssertTrue(text.contains("no finalized transcript"))
        XCTAssertTrue(text.contains("Replay the local recording"))
        XCTAssertTrue(text.contains("silence"))
        XCTAssertFalse(text.lowercased().contains("key"))
        XCTAssertFalse(text.lowercased().contains("unauthorized"))
    }

    func testSafeTransportDescriptionDoesNotExposeUnderlyingURLOrUserInfo() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Request https://example.invalid/private?key=synthetic-key failed",
            "NSErrorFailingURLStringKey": "https://example.invalid/private",
            "request": "data:audio/wav;base64,UklGRPRIVATE"
        ])
        let normalized = ASRError.safeTransportError(error)
        XCTAssertEqual(normalized as? ASRError, .transport(code: URLError.Code.timedOut.rawValue))
        let text = ASRError.safeDescription(for: error)
        XCTAssertTrue(text.contains("[Transport]"))
        XCTAssertTrue(text.contains("timed out"))
        XCTAssertTrue(text.contains("-1001"))
        for value in ["synthetic-key", "https://", "data:audio", "UklGRPRIVATE"] {
            XCTAssertFalse(text.contains(value))
            XCTAssertFalse(String(describing: normalized).contains(value))
        }
    }

    func testUnknownErrorsUseSafeFallbackRatherThanLocalizedDescription() {
        let error = NSError(domain: "private-provider", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "secret recording transcript and API key"
        ])
        XCTAssertEqual(ASRError.safeTransportError(error) as? ASRError, .transport(code: nil))
        XCTAssertFalse(ASRError.safeDescription(for: error).contains("secret recording"))
        XCTAssertFalse(ASRError.safeDescription(for: error).contains("private-provider"))
        XCTAssertFalse(ASRError.invalidWAV("secret recording transcript").localizedDescription.contains("secret recording"))
    }

    func testCancellationKeepsURLErrorContractAndDropsUserInfo() {
        let error = NSError(domain: NSURLErrorDomain, code: URLError.Code.cancelled.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "private-url-and-key"])
        let normalized = ASRError.safeTransportError(error)
        XCTAssertEqual((normalized as? URLError)?.code, .cancelled)
        XCTAssertFalse(ASRError.safeDescription(for: normalized).contains("private-url-and-key"))
    }

    func testHTTPReasonsSeparateAuthPermissionQuotaAndServerFailures() {
        XCTAssertTrue(ASRError.httpStatus(401, code: nil, requestID: nil).localizedDescription.contains("Authentication"))
        XCTAssertTrue(ASRError.httpStatus(403, code: nil, requestID: nil).localizedDescription.contains("permissions"))
        XCTAssertTrue(ASRError.httpStatus(429, code: nil, requestID: nil).localizedDescription.contains("quota"))
        XCTAssertTrue(ASRError.httpStatus(503, code: nil, requestID: nil).localizedDescription.contains("server error"))
        XCTAssertTrue(ASRError.httpStatus(302, code: nil, requestID: nil).localizedDescription.contains("redirect"))
    }
}
