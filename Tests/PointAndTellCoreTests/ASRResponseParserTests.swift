import XCTest
@testable import PointAndTellCore

final class ASRResponseParserTests: XCTestCase {
    func testJSONFixturePreservesProviderMilliseconds() throws {
        let result = try parse(ASRFixtures.json)
        XCTAssertEqual(result.requestID, "fixture-json")
        XCTAssertEqual(result.sentences, [ASRSentence(text: "Hello world.", beginTimeMilliseconds: 760,
                                                     endTimeMilliseconds: 3800, sentenceID: 1, channelID: 0)])
        XCTAssertTrue(result.sentences[0].hasCompleteTiming)
    }

    func testNestedOutputEnvelope() throws {
        let result = try parse(ASRFixtures.nestedJSON)
        XCTAssertEqual(result.sentences.first?.text, "Nested.")
        XCTAssertEqual(result.sentences.first?.beginTimeMilliseconds, 100)
    }

    func testMissingAndPartialTimingAreNeverInvented() throws {
        let missing = try parse(ASRFixtures.missingTimingJSON).sentences[0]
        XCTAssertNil(missing.beginTimeMilliseconds)
        XCTAssertNil(missing.endTimeMilliseconds)
        XCTAssertFalse(missing.hasCompleteTiming)
        let partial = try parse(ASRFixtures.partialTimingJSON).sentences[0]
        XCTAssertEqual(partial.beginTimeMilliseconds, 200)
        XCTAssertNil(partial.endTimeMilliseconds)
        XCTAssertFalse(partial.hasCompleteTiming)
    }

    func testFullNonstreamingTextIsNotDiscardedOrGivenLastSentenceTiming() throws {
        let sentence = try parse(ASRFixtures.fullTextJSON).sentences[0]
        XCTAssertEqual(sentence.text, "First. Second.")
        XCTAssertNil(sentence.beginTimeMilliseconds)
        XCTAssertNil(sentence.endTimeMilliseconds)
    }

    func testTextOnlyJSONIsExplicitlyUntimed() throws {
        let sentence = try parse(#"{"output":{"text":"Text only."}}"#).sentences[0]
        XCTAssertEqual(sentence, ASRSentence(text: "Text only."))
    }

    func testSSEOnlyKeepsFinalSentencesAndAcceptsUnicode() throws {
        let result = try ASRResponseParser.parse(data: Data(ASRFixtures.sse.utf8), contentType: "text/event-stream; charset=utf-8")
        XCTAssertEqual(result.sentences.map(\.text), ["First.", "第二句。"])
        XCTAssertEqual(result.sentences.map(\.beginTimeMilliseconds), [100, 1100])
        XCTAssertEqual(result.requestID, "fixture-sse")
    }

    func testSSECRLFAndUnterminatedLastEvent() throws {
        let payload = "id:1\r\nevent:result\r\ndata: \(ASRFixtures.json)"
        XCTAssertEqual(try parse(payload).sentences.first?.text, "Hello world.")
    }

    func testSSEMultilineData() throws {
        let payload = "data: {\"output\": {\n" +
            "data: \"sentence\": {\"sentence_end\": true, \"text\": \"Multiline\"}}}\n\n"
        XCTAssertEqual(try parse(payload).sentences.first?.text, "Multiline")
    }

    func testJSONFallbackDespiteSSEContentType() throws {
        let result = try ASRResponseParser.parse(data: Data(ASRFixtures.json.utf8), contentType: "text/event-stream")
        XCTAssertEqual(result.sentences.count, 1)
    }

    func testRepeatedFinalSentenceIsReplacedRatherThanDuplicated() throws {
        let payload = "data: \(ASRFixtures.json)\n\ndata: \(ASRFixtures.json)\n\n"
        XCTAssertEqual(try parse(payload).sentences.count, 1)
    }

    func testOnlyInterimResultIsNotAccepted() {
        let payload = #"data:{"output":{"sentence":{"sentence_end":false,"text":"partial"},"text":"partial"}}"#
        XCTAssertThrowsError(try parse(payload)) { XCTAssertEqual($0 as? ASRError, .noFinalSentences) }
    }

    func testMissingSentenceEndInSSEIsNotAcceptedAsFinal() {
        let payload = #"data:{"output":{"sentence":{"text":"not finalized"}}}"#
        XCTAssertThrowsError(try parse(payload)) { XCTAssertEqual($0 as? ASRError, .noFinalSentences) }
    }

    func testProviderErrorStopsWholeResponseEvenAfterFinalSentence() {
        let payload = "data: \(ASRFixtures.json)\n\ndata: \(ASRFixtures.providerError)\n\n"
        XCTAssertThrowsError(try parse(payload)) {
            XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidApiKey", requestID: "fixture-error"))
            XCTAssertFalse($0.localizedDescription.contains("Provider detail"))
        }
    }

    func testMalformedAndInvalidTimestampResponsesFail() {
        let values = ["", "not JSON", "data: [broken]", #"{"output":{"sentence":{"text":"Bad","sentence_end":true,"begin_time":-1}}}"#,
                      #"{"output":{"sentence":{"text":"Bad","sentence_end":true,"begin_time":20,"end_time":10}}}"#]
        for value in values { XCTAssertThrowsError(try parse(value), value) }
    }

    func testBOMIsAccepted() throws {
        XCTAssertEqual(try parse("\u{FEFF}" + ASRFixtures.json).sentences.count, 1)
    }

    private func parse(_ body: String) throws -> ASRResult {
        try ASRResponseParser.parse(data: Data(body.utf8))
    }
}
