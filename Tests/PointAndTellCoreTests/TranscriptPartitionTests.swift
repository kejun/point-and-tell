import Foundation
import XCTest
@testable import PointAndTellCore

final class TranscriptPartitionTests: XCTestCase {
    private func pictures(_ times: [Double]) -> [VisualAnchor] {
        times.map { VisualAnchor(timestamp: $0, imageRelativePath: "frames/\(UUID()).png", kind: .bookmark) }
    }

    private func assertComplete(_ cards: [ReviewCard], sources: [TranscriptSegment], file: StaticString = #filePath, line: UInt = #line) {
        let passages = cards.flatMap { $0.passages ?? [] }
        var observedIDs: [UUID] = []
        for passage in passages {
            if observedIDs.last != passage.transcriptID, let id = passage.transcriptID { observedIDs.append(id) }
        }
        XCTAssertEqual(observedIDs, sources.filter { !$0.text.isEmpty }.map(\.id), file: file, line: line)
        for source in sources {
            let parts = passages.filter { $0.transcriptID == source.id }
            XCTAssertEqual(parts.map(\.text).joined(), source.text, file: file, line: line)
            var cursor = 0
            for part in parts {
                XCTAssertEqual(part.sourceUTF16Start, cursor, file: file, line: line)
                cursor += part.text.utf16.count
                XCTAssertEqual(part.sourceUTF16End, cursor, file: file, line: line)
            }
            XCTAssertEqual(cursor, source.text.utf16.count, file: file, line: line)
        }
        for card in cards {
            XCTAssertEqual(card.text, ReviewPassage.joinedText(card.passages ?? []), file: file, line: line)
            XCTAssertNotEqual(card.association?.status, .needsReview, file: file, line: line)
            if !card.text.isEmpty { XCTAssertEqual(card.association?.status, .matched, file: file, line: line) }
        }
    }

    func testThreeSentencesCrossingOldMidpointsProduceThreeCompleteCards() {
        let sources = [TranscriptSegment(text: "第一张完整的说明。", startSeconds: 9, endSeconds: 16),
            TranscriptSegment(text: "第二张完整的说明。", startSeconds: 16.3, endSeconds: 24),
            TranscriptSegment(text: "第三张完整的说明。", startSeconds: 24.2, endSeconds: 31)]
        let cards = ScreenshotCardMatcher.cards(anchors: pictures([10, 20, 30]), transcripts: sources)
        XCTAssertEqual(cards.map(\.text), sources.map(\.text))
        XCTAssertEqual(cards.map(\.startSeconds), [9, 16.3, 24.2])
        assertComplete(cards, sources: sources)
    }

    func testAllSpeechBeforeAfterOrFarFromScreenshotsStillBelongsToCards() {
        let sources = [TranscriptSegment(text: "截图之前的说明。", startSeconds: 0, endSeconds: 2),
            TranscriptSegment(text: "持续很久的说明，不截掉后半段。", startSeconds: 80, endSeconds: 130),
            TranscriptSegment(text: "最后很远的一段。", startSeconds: 220, endSeconds: 270)]
        let cards = ScreenshotCardMatcher.cards(anchors: pictures([30, 40, 50]), transcripts: sources)
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.allSatisfy { !$0.text.isEmpty })
        assertComplete(cards, sources: sources)
    }

    func testUnequalParagraphLengthsAndActualPausesDoNotForceEqualThirds() {
        let parts: [(String, Double, Double)] = [("短。", 2, 3), ("这里是第二张的长说明。", 20, 28),
            ("继续解释同一张。", 28.1, 33), ("还需要补充很多细节。", 33.1, 40), ("最后。", 60, 61)]
        let source = TranscriptSegment(text: parts.map { $0.0 }.joined(), startSeconds: 2, endSeconds: 61,
            words: parts.map { TranscriptWord(text: $0.0, startSeconds: $0.1, endSeconds: $0.2) })
        let cards = ScreenshotCardMatcher.cards(anchors: pictures([3, 30, 60]), transcripts: [source])
        XCTAssertEqual(cards.map(\.text), [parts[0].0, parts[1...3].map { $0.0 }.joined(), parts[4].0])
        assertComplete(cards, sources: [source])
    }

    func testUntimedAndPunctuationMismatchesRetainExactUnicodeSourceSpans() {
        let sources = [TranscriptSegment(text: "  第一段，包含👩🏽‍💻和 e\u{301}。\n第二段，不丢标点！  "),
            TranscriptSegment(text: "Third sentence, with punctuation.", startSeconds: 5, endSeconds: 9,
                words: [TranscriptWord(text: "Third sentence with punctuation", startSeconds: 5, endSeconds: 9)])]
        let cards = ScreenshotCardMatcher.cards(anchors: pictures([1, 1, 1]), transcripts: sources)
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.allSatisfy { !$0.text.isEmpty })
        assertComplete(cards, sources: sources)
        XCTAssertTrue(cards.contains { !$0.isTimed })
    }

    func testLongUnpunctuatedTextStillPartitionsWithoutFabricatedTiming() {
        let source = TranscriptSegment(text: "没有标点的中文讲话也必须全部放到这些截图卡片里面方便后续手动整理", startSeconds: 4, endSeconds: 40)
        let cards = ScreenshotCardMatcher.cards(anchors: pictures([5, 15, 30]), transcripts: [source])
        XCTAssertTrue(cards.allSatisfy { !$0.text.isEmpty && $0.startSeconds == 4 && $0.endSeconds == 40 })
        assertComplete(cards, sources: [source])
    }

    func testVeryLittleTextKeepsAllPicturesWithoutDuplication() {
        let sources = [TranscriptSegment(text: "好")]
        let anchors = pictures([1, 2, 3])
        let cards = ScreenshotCardMatcher.cards(anchors: anchors, transcripts: sources)
        XCTAssertEqual(cards.map(\.id), anchors.map(\.id))
        XCTAssertEqual(cards.filter { !$0.text.isEmpty }.count, 1)
        assertComplete(cards, sources: sources)
        XCTAssertTrue(cards.filter { $0.text.isEmpty }.allSatisfy { $0.association?.summary == "可补充讲解" })
    }

    func testManyCountAndTimingCombinationsHaveExactCoverageAndDeterministicResults() {
        let sources = [TranscriptSegment(text: "开头一句。Next words without timing. 第二句，补充。"),
            TranscriptSegment(text: "再一段。结束。", startSeconds: 90, endSeconds: 100)]
        for count in 1...24 {
            for spacing in [0.0, 1, 60] {
                let anchors = pictures((0..<count).map { Double($0) * spacing })
                let cards = ScreenshotCardMatcher.cards(anchors: anchors, transcripts: sources)
                XCTAssertEqual(cards.count, count)
                assertComplete(cards, sources: sources)
                XCTAssertEqual(cards, ScreenshotCardMatcher.cards(anchors: anchors, transcripts: sources))
            }
        }
    }

    func testLongTranscriptRetainsEveryWordAcrossManyCards() {
        let words = (0..<4000).map { TranscriptWord(text: "词\($0)。", startSeconds: Double($0), endSeconds: Double($0) + 0.5) }
        let source = TranscriptSegment(text: words.map(\.text).joined(), startSeconds: 0, endSeconds: 4000, words: words)
        let cards = ScreenshotCardMatcher.cards(anchors: pictures((0..<40).map { Double($0 * 100) }), transcripts: [source])
        XCTAssertEqual(cards.count, 40)
        XCTAssertTrue(cards.allSatisfy { !$0.text.isEmpty })
        assertComplete(cards, sources: [source])
    }

    func testOldAmbiguousPlaceholdersUpgradeLocallyWithoutRetranscription() {
        let anchors = pictures([3, 10, 16])
        let source = TranscriptSegment(text: "第一句。第二句。第三句。", startSeconds: 1, endSeconds: 19)
        var project = ProjectManifest(title: "Old", anchors: anchors, transcripts: [source], screenshotCardVersion: 1)
        project.reviewCards = anchors.map {
            var card = ReviewCard(id: $0.id, text: "", frameIDs: [$0.id], sourceAnchorID: $0.id,
                association: ScreenshotAssociation(status: .needsReview, screenshotSeconds: $0.timestamp,
                    matches: [], reasons: ["旧关联有歧义"]))
            card.generatedContent = ReviewCardContent(card)
            return card
        }
        XCTAssertTrue(project.reconcileScreenshotCards())
        XCTAssertEqual(project.reviewCards.map(\.text), ["第一句。", "第二句。", "第三句。"])
        XCTAssertEqual(project.transcripts, [source])
        XCTAssertFalse(project.reconcileScreenshotCards())
    }

    func testBoundaryMovesPreserveTextImagesAndManualTimingAcrossSaveAndReopen() throws {
        let source = TranscriptSegment(text: "甲。乙。丙。", startSeconds: 1, endSeconds: 9)
        var project = ProjectManifest(title: "Moves", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchors: pictures([2, 5, 8]), transcripts: [source], screenshotCardVersion: 1)
        project.reconcileScreenshotCards()
        let original = project.reviewCards
        XCTAssertFalse(project.moveBoundaryPassage(cardID: original[0].id, toPrevious: true))
        XCTAssertFalse(project.moveBoundaryPassage(cardID: original[2].id, toPrevious: false))
        project.reviewCards[0].startSeconds = 0.25; project.reviewCards[0].endSeconds = 0.5
        project.reviewCards[0].userEdited = true
        XCTAssertTrue(project.moveBoundaryPassage(cardID: original[1].id, toPrevious: true))
        XCTAssertEqual(project.reviewCards.map(\.text), ["甲。乙。", "", "丙。"])
        XCTAssertEqual(project.reviewCards[0].startSeconds, 0.25)
        XCTAssertEqual(project.reviewCards[0].endSeconds, 0.5)
        XCTAssertTrue(project.moveBoundaryPassage(cardID: original[0].id, toPrevious: false))
        XCTAssertEqual(project.reviewCards.map(\.text), original.map(\.text))
        XCTAssertEqual(project.reviewCards.map(\.frameIDs), original.map(\.frameIDs))
        XCTAssertEqual(project.transcripts, [source])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(folderURL: root); _ = try store.create(title: "Moves")
        try store.save(project)
        var reopened = try store.load()
        XCTAssertEqual(reopened, project)
        XCTAssertFalse(reopened.reconcileScreenshotCards())
        XCTAssertEqual(reopened.cardsForExport, project.reviewCards)
        assertComplete(reopened.reviewCards, sources: [source])
    }

    func testMovingEditedTextUsesCurrentTextInsteadOfStaleSourcePassages() {
        var project = ProjectManifest(title: "Edited", anchors: pictures([2, 7]),
            transcripts: [TranscriptSegment(text: "原甲。原乙。")], screenshotCardVersion: 1)
        project.reconcileScreenshotCards()
        project.reviewCards[0].text = "手动新写第一句。手动新写第二句。"
        project.reviewCards[0].userEdited = true
        XCTAssertTrue(project.moveBoundaryPassage(cardID: project.reviewCards[0].id, toPrevious: false))
        XCTAssertEqual(project.reviewCards.map(\.text), ["手动新写第一句。", "手动新写第二句。原乙。"])
        XCTAssertNil(project.reviewCards[1].passages?.first?.transcriptID)
        XCTAssertNil(project.reviewCards[1].passages?.first?.startSeconds)
        let edited = project.reviewCards
        project.reconcileScreenshotCards()
        XCTAssertEqual(project.reviewCards, edited)
    }
}
