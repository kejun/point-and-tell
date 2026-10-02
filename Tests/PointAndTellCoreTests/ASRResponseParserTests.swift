import XCTest
@testable import PointAndTellCore

final class ASRResponseParserTests: XCTestCase {
    func testJSONFixturePreservesProviderMilliseconds() throws {
        let result = try parse(ASRFixtures.json)
        XCTAssertEqual(result.requestID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(result.sentences, [ASRSentence(text: "Hello world.", beginTimeMilliseconds: 760,
                                                     endTimeMilliseconds: 3800, sentenceID: 1, channelID: 0,
                                                     words: [ASRWord(text: "Hello", beginTimeMilliseconds: 760, endTimeMilliseconds: 1400),
                                                             ASRWord(text: "world.", beginTimeMilliseconds: 1500, endTimeMilliseconds: 3800)])])
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
        let sentences = try parse(ASRFixtures.fullTextJSON).sentences
        XCTAssertEqual(sentences.map(\.text).joined(), "First. Second.")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertNil(sentences[0].beginTimeMilliseconds)
        XCTAssertNil(sentences[0].endTimeMilliseconds)
        XCTAssertEqual(sentences[1].text, "Second.")
        XCTAssertTrue(sentences[1].hasCompleteTiming)
    }

    func testTextOnlyJSONIsExplicitlyUntimed() throws {
        let sentence = try parse(#"{"output":{"text":"Text only."}}"#).sentences[0]
        XCTAssertEqual(sentence, ASRSentence(text: "Text only."))
    }

    func testSSEOnlyKeepsFinalSentencesAndAcceptsUnicode() throws {
        let result = try ASRResponseParser.parse(data: Data(ASRFixtures.sse.utf8), contentType: "text/event-stream; charset=utf-8")
        XCTAssertEqual(result.sentences.map(\.text), ["First.", "第二句。"])
        XCTAssertEqual(result.sentences.map(\.beginTimeMilliseconds), [100, 1100])
        XCTAssertEqual(result.requestID, "44444444-4444-4444-8444-444444444444")
    }

    func testSSECRLFAndUnterminatedLastEvent() throws {
        let payload = "id:1\r\nevent:result\r\ndata: \(ASRFixtures.json)"
        XCTAssertEqual(try parse(payload).sentences.first?.text, "Hello world.")
    }

    func testSSEFullTextMustBeCoveredByAllFinalSentences() throws {
        let finalText = "data:{\"output\":{\"text\":\"First. 第二句。\"}}\n\n"
        let complete = ASRFixtures.sse.replacingOccurrences(of: "data:[DONE]", with: finalText)
        XCTAssertEqual(try parse(complete).validatedSentences().count, 2)
        let omittedSentence = "data: \(ASRFixtures.json)\n\ndata:{\"output\":{\"text\":\"Missing. Hello world.\"}}\n\n"
        XCTAssertThrowsError(try parse(omittedSentence)) { XCTAssertEqual($0 as? ASRError, .incompleteTimestamps) }
    }

    func testSSEUnfinishedTailCannotCompleteAfterAnEarlierFinalSentence() throws {
        let tail = #"data:{"output":{"sentence":{"sentence_id":2,"sentence_end":false,"text":"Unfinished"}}}"#
        XCTAssertThrowsError(try parse("data: \(ASRFixtures.json)\n\n" + tail)) {
            XCTAssertEqual($0 as? ASRError, .incompleteTimestamps)
        }
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
            XCTAssertEqual($0 as? ASRError, .provider(code: "InvalidApiKey", requestID: "55555555-5555-4555-8555-555555555555"))
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

    func testWordTimestampsPunctuationAndFinalSSEReplacementArePreserved() throws {
        let json = #"{"output":{"sentence":{"text":"Hello, 世界。","begin_time":101,"end_time":2999,"sentence_end":true,"sentence_id":1,"words":[{"text":"Hello","punctuation":",","begin_time":101,"end_time":1001,"fixed":true},{"text":"世界","punctuation":"。","begin_time":2001,"end_time":2999,"fixed":true}]}}}"#
        let words = try parse(json).sentences[0].words!
        XCTAssertEqual(words.map(\.text), ["Hello,", "世界。"])
        XCTAssertEqual(words.map(\.beginTimeMilliseconds), [101, 2001])
        let replacement = json.replacingOccurrences(of: "2001", with: "2123")
        let result = try parse("data: \(json)\n\ndata: \(replacement)\n\n")
        XCTAssertEqual(result.sentences.count, 1)
        XCTAssertEqual(result.sentences[0].words?[1].beginTimeMilliseconds, 2123)
        for invalid in [json.replacingOccurrences(of: "2001", with: "-1"),
                        json.replacingOccurrences(of: "\"fixed\":true", with: "\"fixed\":false")] {
            XCTAssertNil(try parse(invalid).sentences[0].words)
            XCTAssertTrue(try parse(invalid).sentences[0].hasCompleteTiming)
        }
    }

    func testSentenceArrayPreservesEverySentenceTime() throws {
        let json = #"{"output":{"text":"甲。乙。","sentences":[{"text":"甲。","begin_time":100,"end_time":200,"sentence_end":true},{"text":"乙。","begin_time":301,"end_time":402,"sentence_end":true}]}}"#
        let sentences = try parse(json).sentences
        XCTAssertEqual(sentences.map(\.text), ["甲。", "乙。"])
        XCTAssertEqual(sentences.map(\.beginTimeMilliseconds), [100, 301])
    }

    private func parse(_ body: String) throws -> ASRResult {
        try ASRResponseParser.parse(data: Data(body.utf8))
    }
}
