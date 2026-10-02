import Foundation
import XCTest
@testable import PointAndTellCore

final class ReviewCardGroupingTests: XCTestCase {
    private func fixture() -> (TranscriptSegment, [VisualAnchor], ReviewCard) {
        let transcript = TranscriptSegment(text: "  打开设置。\n确认保存。  ", startSeconds: 180, endSeconds: 240,
            words: [TranscriptWord(text: "打开设置。", startSeconds: 181.125, endSeconds: 182.234),
                    TranscriptWord(text: "确认保存。", startSeconds: 225.456, endSeconds: 226.789)])
        let anchors = [VisualAnchor(timestamp: 181.5, imageRelativePath: "frames/a.png"),
                       VisualAnchor(timestamp: 230, imageRelativePath: "frames/b.png")]
        let card = ReviewCard(transcriptID: transcript.id, text: transcript.text, frameIDs: anchors.map(\.id),
                              startSeconds: transcript.startSeconds, endSeconds: transcript.endSeconds)
        return (transcript, anchors, card)
    }

    func testOneProviderSentenceCreatesOneCardPerExportMoment() {
        let (transcript, anchors, original) = fixture()
        let expected = TranscriptAlignment.moments(card: original, transcript: transcript, anchors: anchors)
        let cards = FrameMatcher.suggestCards(for: [transcript], anchors: anchors)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.map(\.text), expected.map(\.text))
        XCTAssertEqual(cards.map(\.text).joined(), transcript.text)
        XCTAssertEqual(cards.map(\.frameIDs), expected.map(\.imageIDs))
        XCTAssertEqual(cards.map(\.startSeconds), [181.125, 225.456])
        XCTAssertEqual(cards.map(\.endSeconds), [182.234, 226.789])
        XCTAssertEqual(Set(cards.map(\.transcriptID)), [transcript.id])
    }

    func testGeneratedExcerptsExportIdenticallyEvenWhenScreenshotFallsOutsideWordInterval() {
        let (transcript, anchors, original) = fixture()
        let expected = TranscriptAlignment.moments(card: original, transcript: transcript, anchors: anchors)
        let cards = ReviewCardGrouping.cards(from: original, transcript: transcript, anchors: anchors)
        let actual = cards.flatMap { TranscriptAlignment.moments(card: $0, transcript: transcript, anchors: anchors) }
        XCTAssertEqual(actual, expected)
        XCTAssertGreaterThan(anchors[1].timestamp, cards[1].endSeconds!)
        XCTAssertEqual(actual.map(\.timingPrecision), ["word", "word"])
    }

    func testLegacyMigrationIsIdempotentAndSurvivesSaveReopenWithoutReupload() throws {
        let (transcript, anchors, original) = fixture()
        var project = ProjectManifest(title: "Existing", anchors: anchors, transcripts: [transcript], reviewCards: [original])
        XCTAssertTrue(project.groupReviewCards())
        XCTAssertEqual(project.reviewCards.first?.id, original.id)
        XCTAssertEqual(Set(project.reviewCards.map(\.id)).count, 2)
        let cards = project.reviewCards
        XCTAssertFalse(project.groupReviewCards())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProjectStore(folderURL: folder); try store.save(project)
        var reopened = try store.load()
        XCTAssertEqual(reopened.reviewCards, cards)
        XCTAssertFalse(reopened.groupReviewCards())
        XCTAssertEqual(reopened.transcripts, [transcript])
        XCTAssertTrue(reopened.asrChunks.isEmpty)
    }

    func testManualEditsAndMissingWordTimesAreNotRewritten() {
        let (transcript, anchors, original) = fixture()
        var edited = original; edited.text = "校对过的文字"
        XCTAssertEqual(ReviewCardGrouping.cards(from: edited, transcript: transcript, anchors: anchors), [edited])
        edited = original; edited.startSeconds = 180.5
        XCTAssertEqual(ReviewCardGrouping.cards(from: edited, transcript: transcript, anchors: anchors), [edited])
        var untimedWords = transcript; untimedWords.words = nil
        XCTAssertEqual(ReviewCardGrouping.cards(from: original, transcript: untimedWords, anchors: anchors), [original])
        var incomplete = transcript; incomplete.words?.removeLast()
        XCTAssertEqual(ReviewCardGrouping.cards(from: original, transcript: incomplete, anchors: anchors), [original])
    }

    func testEditingASplitCardKeepsTheOtherCardAndStopsClaimingWordAlignment() {
        let (transcript, anchors, original) = fixture()
        var cards = ReviewCardGrouping.cards(from: original, transcript: transcript, anchors: anchors)
        cards[0].text = "手工修订"
        let expected = cards
        cards = ReviewCardGrouping.cards(from: cards, transcripts: [transcript], anchors: anchors)
        XCTAssertEqual(cards, expected)
        XCTAssertEqual(TranscriptAlignment.moments(card: cards[0], transcript: transcript, anchors: anchors).first?.timingPrecision, "manual")
        XCTAssertEqual(TranscriptAlignment.moments(card: cards[1], transcript: transcript, anchors: anchors).first?.timingPrecision, "word")
    }

    func testMissingImagesAreKeptForRepair() {
        let (transcript, anchors, original) = fixture()
        var card = original; let missingID = UUID(); card.frameIDs.append(missingID)
        XCTAssertEqual(ReviewCardGrouping.cards(from: card, transcript: transcript, anchors: anchors), [card])
    }

    func testScreenshotOnlyAndEqualTimeGroupsArePreservedWithoutInventingSpeechTime() {
        let word = TranscriptWord(text: "稍后说明。", startSeconds: 8, endSeconds: 9)
        let source = TranscriptSegment(text: word.text, startSeconds: 0, endSeconds: 10, words: [word])
        let anchors = [VisualAnchor(timestamp: 1, imageRelativePath: "frames/a.png"),
                       VisualAnchor(timestamp: 8, imageRelativePath: "frames/b.png"),
                       VisualAnchor(timestamp: 8, imageRelativePath: "frames/c.png")]
        let card = ReviewCard(transcriptID: source.id, text: source.text, frameIDs: anchors.map(\.id), startSeconds: 0, endSeconds: 10)
        let expected = TranscriptAlignment.moments(card: card, transcript: source, anchors: anchors)
        let cards = ReviewCardGrouping.cards(from: card, transcript: source, anchors: anchors)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].text, ""); XCTAssertNil(cards[0].startSeconds)
        XCTAssertEqual(cards[1].frameIDs, expected[1].imageIDs)
        XCTAssertEqual(cards.flatMap { TranscriptAlignment.moments(card: $0, transcript: source, anchors: anchors) }, expected)
    }
}
