import Foundation
import XCTest
@testable import PointAndTellCore

final class TranscriptAlignmentTests: XCTestCase {
    private func fixture() -> (TranscriptSegment, ReviewCard, [VisualAnchor]) {
        let words = [TranscriptWord(text: "打开", startSeconds: 180.101, endSeconds: 181.205),
                     TranscriptWord(text: "设置。", startSeconds: 181.205, endSeconds: 182.006),
                     TranscriptWord(text: "点击", startSeconds: 188.345, endSeconds: 189.001),
                     TranscriptWord(text: "保存。", startSeconds: 189.001, endSeconds: 190.999)]
        let transcript = TranscriptSegment(text: "打开设置。点击保存。", startSeconds: 180.101,
                                           endSeconds: 190.999, words: words)
        let anchors = [VisualAnchor(timestamp: 189.5, imageRelativePath: "frames/b.png"),
                       VisualAnchor(timestamp: 181.5, imageRelativePath: "frames/a.png")]
        let card = ReviewCard(transcriptID: transcript.id, text: transcript.text,
                              frameIDs: anchors.map(\.id), startSeconds: transcript.startSeconds,
                              endSeconds: transcript.endSeconds)
        return (transcript, card, anchors)
    }

    func testRealWordTimesGroupTextBesideChronologicalScreenshotsWithoutLoss() {
        let (transcript, card, anchors) = fixture()
        let moments = TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors)
        XCTAssertEqual(moments.map(\.text), ["打开设置。", "点击保存。"])
        XCTAssertEqual(moments.map(\.text).joined(), card.text)
        XCTAssertEqual(moments.map(\.imageIDs), [[anchors[1].id], [anchors[0].id]])
        XCTAssertEqual(moments.map(\.startSeconds), [180.101, 188.345])
        XCTAssertEqual(moments.map(\.endSeconds), [182.006, 190.999])
        XCTAssertEqual(moments.map(\.timingPrecision), ["word", "word"])
    }

    func testExactBoundaryWordGoesToLaterSnapshotOnceAndEqualTimeImagesShareText() {
        let word = TranscriptWord(text: "边界。", startSeconds: 4, endSeconds: 6)
        let transcript = TranscriptSegment(text: word.text, startSeconds: 0, endSeconds: 10, words: [word])
        let anchors = [VisualAnchor(timestamp: 2, imageRelativePath: "a"),
                       VisualAnchor(timestamp: 8, imageRelativePath: "b"),
                       VisualAnchor(timestamp: 8, imageRelativePath: "c")]
        let card = ReviewCard(text: word.text, frameIDs: anchors.map(\.id), startSeconds: 0, endSeconds: 10)
        let moments = TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors)
        XCTAssertEqual(moments.map(\.text), ["", "边界。"])
        XCTAssertNil(moments[0].startSeconds)
        XCTAssertEqual(moments[1].imageIDs.count, 2)
        XCTAssertEqual(moments[1].startSeconds, 4)
        XCTAssertEqual(moments[1].endSeconds, 6)
    }

    func testEditsAndMissingOrInvalidWordTimingNeverGetSyntheticWordAlignment() {
        let (transcript, originalCard, anchors) = fixture()
        var card = originalCard
        card.text = "Edited text"
        XCTAssertEqual(TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors).first?.timingPrecision, "manual")
        card = originalCard; card.startSeconds = 180
        XCTAssertEqual(TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors).count, 1)
        let cases: [[TranscriptWord]?] = [nil, [], Array(transcript.words!.dropLast()),
            [TranscriptWord(text: transcript.text, startSeconds: 0, endSeconds: 300)],
            [TranscriptWord(text: transcript.text, startSeconds: .nan, endSeconds: 190)]]
        for words in cases {
            var source = transcript; source.words = words
            let moments = TranscriptAlignment.moments(card: originalCard, transcript: source, anchors: anchors)
            XCTAssertEqual(moments.count, 1)
            XCTAssertEqual(moments.first?.text, originalCard.text)
            XCTAssertEqual(moments.first?.timingPrecision, "sentence")
        }
    }

    func testWhitespacePunctuationAndEmojiRemainExactlyOnce() {
        let words = [TranscriptWord(text: "Hello,", startSeconds: 0, endSeconds: 1),
                     TranscriptWord(text: "世界👋。", startSeconds: 8, endSeconds: 9)]
        let transcript = TranscriptSegment(text: "  Hello,\n世界👋。  ", startSeconds: 0, endSeconds: 10, words: words)
        let anchors = [VisualAnchor(timestamp: 0, imageRelativePath: "a"), VisualAnchor(timestamp: 10, imageRelativePath: "b")]
        let card = ReviewCard(text: transcript.text, frameIDs: anchors.map(\.id), startSeconds: 0, endSeconds: 10)
        let moments = TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors)
        XCTAssertEqual(moments.map(\.text), ["  Hello,", "\n世界👋。  "])
    }

    func testChunkOffsetAndRoundTripPreserveMillisecondsAndOldProjectsDecode() throws {
        let sentence = ASRSentence(text: "Hi", beginTimeMilliseconds: 101, endTimeMilliseconds: 205,
            words: [ASRWord(text: "Hi", beginTimeMilliseconds: 101, endTimeMilliseconds: 205)])
        let transcript = sentence.transcriptSegment(chunkOffset: 180)
        XCTAssertEqual(transcript.startSeconds!, 180.101, accuracy: 0.0000001)
        XCTAssertEqual(transcript.words![0].endSeconds, 180.205, accuracy: 0.0000001)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded, transcript)
        let old = "{\"id\":\"\(UUID().uuidString)\",\"text\":\"Old\",\"startSeconds\":1,\"endSeconds\":2}"
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8)).words)
    }
}
