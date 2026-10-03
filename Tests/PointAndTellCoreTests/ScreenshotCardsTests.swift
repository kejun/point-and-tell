import Foundation
import XCTest
@testable import PointAndTellCore

final class ScreenshotCardsTests: XCTestCase {
    private func picture(_ time: Double, end: Double? = nil) -> VisualAnchor {
        VisualAnchor(timestamp: time, imageRelativePath: "frames/\(UUID().uuidString).png",
            kind: end == nil ? .bookmark : .pen, endTimestamp: end)
    }
    private func speech(_ parts: [(String, Double, Double)]) -> TranscriptSegment {
        TranscriptSegment(text: parts.map { $0.0 }.joined(),
            startSeconds: parts.first?.1, endSeconds: parts.last?.2,
            words: parts.map { TranscriptWord(text: $0.0, startSeconds: $0.1, endSeconds: $0.2) })
    }
    private func project(_ pictures: [VisualAnchor], _ segments: [TranscriptSegment] = []) -> ProjectManifest {
        ProjectManifest(title: "Screenshot first", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchors: pictures, transcripts: segments, screenshotCardVersion: 1)
    }

    func testTwoPenSessionsAndBookmarkExistBeforeASRAndReceiveOneLongParagraph() {
        let a = picture(10, end: 12), b = picture(20, end: 24), c = picture(30)
        var p = project([])
        for anchor in [a, b, c] { XCTAssertTrue(p.registerRecordingAnchor(anchor)) }
        XCTAssertEqual(p.reviewCards.map(\.sourceAnchorID), [a.id, b.id, c.id])
        XCTAssertTrue(p.reviewCards.allSatisfy { $0.text.isEmpty && $0.startSeconds == nil })
        XCTAssertFalse(p.registerRecordingAnchor(a), "Repeated save of one drawing session is not a new event")
        let ids = p.reviewCards.map(\.id)
        p.transcripts = [speech([("先讲第一张。", 8, 9), ("绘制第一张。", 10.5, 11.5),
            ("绘制第二张。", 21, 23), ("第三张的后续讲解。", 31, 32)])]
        p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.map(\.id), ids)
        XCTAssertEqual(p.reviewCards.map(\.text), ["先讲第一张。绘制第一张。", "绘制第二张。", "第三张的后续讲解。"])
        XCTAssertEqual(p.reviewCards[0].startSeconds, 8)
        XCTAssertEqual(p.reviewCards[2].association?.matches.first?.offsetSeconds, 1)
        XCTAssertEqual(p.reviewCards[1].association?.annotationEndSeconds, 24)
        XCTAssertFalse(p.reconcileScreenshotCards())
    }

    func testSentenceOnlyAcrossImagesIsFullyAssignedWithoutInventingTimes() {
        let images = [picture(3), picture(10), picture(16)]
        let sentence = TranscriptSegment(text: "整句只有真实句级时间，不能平均拆分。", startSeconds: 1, endSeconds: 19)
        var p = project(images, [sentence]); p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.count, 3)
        XCTAssertTrue(p.reviewCards.allSatisfy { !$0.text.isEmpty && $0.association?.status == .matched })
        XCTAssertEqual(p.reviewCards.map(\.text).joined(), sentence.text)
        XCTAssertEqual(p.transcripts, [sentence])
        XCTAssertTrue(p.reviewCards.allSatisfy { $0.startSeconds == 1 && $0.endSeconds == 19 })
        XCTAssertTrue(p.reviewCards.allSatisfy { $0.association?.precision == "sentence" })
    }

    func testSentenceOnlyUniqueAssociationRetainsSentencePrecisionAndWholeText() {
        let sentence = TranscriptSegment(text: "完整的一句。", startSeconds: 1, endSeconds: 4)
        var p = project([picture(2)], [sentence]); p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.first?.text, sentence.text)
        XCTAssertEqual(p.reviewCards.first?.association?.precision, "sentence")
        XCTAssertEqual(p.reviewCards.first?.startSeconds, 1)
        XCTAssertFalse(ASRChunk(relativePath: "audio/a.wav", startSeconds: 0, durationSeconds: 5,
            state: .complete, sentences: [sentence]).needsTimestampRetry)
    }

    func testUntimedSourceSurvivesAcceptanceWhilePicturesRemainIndependent() throws {
        var p = project([picture(1), picture(2)])
        p.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0, durationSeconds: 10)]
        let source = TranscriptSegment(text: "没有时间戳也保留这段原始转写。")
        p.reconcileScreenshotCards()
        try p.acceptTranscription([source], forChunkAt: 0)
        XCTAssertEqual(p.transcripts, [source])
        XCTAssertTrue(p.asrChunks[0].needsTimestampRetry)
        XCTAssertEqual(p.reviewCards.count, 2)
        XCTAssertEqual(p.reviewCards.map(\.text).joined(), source.text)
        XCTAssertTrue(p.reviewCards.allSatisfy { !$0.text.isEmpty && $0.association?.status == .matched && !$0.isTimed })
    }

    func testEqualTimeEventsStaySeparateStableAndDoNotDuplicateSpeech() {
        let a = picture(5), b = picture(5)
        var p = project([a, b], [speech([("无法区分归属。", 4, 6)])])
        p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.map(\.frameIDs), [[a.id], [b.id]])
        XCTAssertEqual(p.reviewCards.map(\.text).joined(), "无法区分归属。")
        XCTAssertTrue(p.reviewCards.allSatisfy { !$0.text.isEmpty && $0.association?.status == .matched })
        let saved = p; p.reconcileScreenshotCards(); XCTAssertEqual(p, saved)
    }

    func testMoreThanSixScreenshotsHaveNoCandidateTruncation() {
        let images = (1...12).map { picture(Double($0) * 3) }
        let parts: [(String, Double, Double)] = (1...12).map { index in
            let time = Double(index) * 3.0
            return ("第\(index)张。", time - 0.2, time + 0.2)
        }
        var p = project(images, [speech(parts)]); p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.count, 12)
        XCTAssertEqual(p.reviewCards.map(\.text), parts.map { $0.0 })
    }

    func testPauseBoundaryUsesActualUnitsAndDoesNotInterpolateTimes() {
        let source = speech([("前一张的讲解。", 6, 11), ("后一张的讲解。", 14, 16)])
        var p = project([picture(5), picture(15)], [source]); p.reconcileScreenshotCards()
        XCTAssertEqual(p.reviewCards.map(\.startSeconds), [6, 14])
        XCTAssertEqual(p.reviewCards.map(\.endSeconds), [11, 16])
        XCTAssertTrue(p.reviewCards[0].association!.reasons.contains("分界参考真实语音停顿"))
    }

    func testChunkOffsetsAreAddedOnceAndPenIntervalSpansChunks() throws {
        let a = ASRSentence(text: "前半。", beginTimeMilliseconds: 1500, endTimeMilliseconds: 2500,
            words: [ASRWord(text: "前半。", beginTimeMilliseconds: 1500, endTimeMilliseconds: 2500)])
        let b = ASRSentence(text: "后半。", beginTimeMilliseconds: 0, endTimeMilliseconds: 1000,
            words: [ASRWord(text: "后半。", beginTimeMilliseconds: 0, endTimeMilliseconds: 1000)])
        var p = project([picture(180.5, end: 184)])
        p.asrChunks = [ASRChunk(index: 0, relativePath: "audio/0.wav", startSeconds: 180, durationSeconds: 3),
            ASRChunk(index: 1, relativePath: "audio/1.wav", startSeconds: 183, durationSeconds: 3)]
        try p.acceptTranscription([a.transcriptSegment(chunkOffset: 180)], forChunkAt: 0)
        try p.acceptTranscription([b.transcriptSegment(chunkOffset: 183)], forChunkAt: 1)
        XCTAssertEqual(p.reviewCards.count, 1)
        XCTAssertEqual(p.reviewCards[0].text, "前半。\n后半。")
        XCTAssertEqual(p.reviewCards[0].startSeconds, 181.5)
        XCTAssertEqual(p.reviewCards[0].endSeconds, 184)
        XCTAssertEqual(p.reviewCards[0].association?.matches.map(\.offsetSeconds), [1, 2.5])
    }

    func testManualEditsAndAnchorDeletionSurviveChangedASRSentenceIDs() throws {
        let images = [picture(2), picture(10), picture(20)]
        let first = speech([("原甲。", 1, 3), ("原乙。", 9, 11), ("原丙。", 19, 21)])
        var p = project(images, [first]); p.reconcileScreenshotCards()
        p.reviewCards[0].text = "用户改写"; p.reviewCards[0].startSeconds = 0.75
        p.reviewCards[0].frameIDs = [images[2].id]
        let edited = p.reviewCards[0]
        p.deleteReviewCard(id: p.reviewCards[1].id)
        p.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0, durationSeconds: 25)]
        let retry = speech([("新甲。", 1, 3), ("新乙。", 9, 11), ("新丙。", 19, 21)])
        try p.acceptTranscription([retry], forChunkAt: 0)
        XCTAssertEqual(p.reviewCards.count, 2)
        XCTAssertEqual(p.reviewCards[0], edited)
        XCTAssertEqual(p.reviewCards[1].text, "新丙。")
        XCTAssertFalse(p.reviewCards.contains { $0.sourceAnchorID == images[1].id })
        XCTAssertFalse(p.reviewCards.contains { $0.text.contains("新乙") })
    }

    func testNoAutomaticOrManualExtractionAnchorsBecomeRecordingCards() {
        let automatic = VisualAnchor(timestamp: 2, imageRelativePath: "frames/old.png")
        let manual = VisualAnchor(timestamp: 3, imageRelativePath: "frames/manual.png", source: .manualExtraction)
        var p = project([automatic, manual], [speech([("没有主动标记。", 1, 4)])])
        p.reconcileScreenshotCards()
        XCTAssertTrue(p.reviewCards.isEmpty)
        XCTAssertTrue(p.cardsForExport.isEmpty)
        XCTAssertFalse(p.hasExportableCards)
        XCTAssertEqual(p.anchors, [automatic, manual])
        XCTAssertEqual(p.transcripts.count, 1)
    }

    func testLegacyAdoptionPreservesReviewedContentAndDeletionDecisions() {
        let a = picture(3), b = picture(8)
        let old = ReviewCard(text: "历史手工讲解", frameIDs: [a.id], startSeconds: 0.25, endSeconds: 6)
        var p = ProjectManifest(title: "Legacy", anchors: [a, b], reviewCards: [old], reviewEdits: ReviewEdits())
        p.enableScreenshotCards()
        XCTAssertEqual(p.reviewCards.map { ReviewCardContent($0) }, [ReviewCardContent(old)])
        XCTAssertEqual(p.reviewCards[0].id, old.id)
        XCTAssertEqual(p.reviewEdits?.suppressedAnchorIDs, [b.id])
        p.reconcileScreenshotCards(); XCTAssertEqual(p.reviewCards.count, 1)
    }

    func testPersistReopenAndExportUseExactlyTheEditorCards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(folderURL: root.appendingPathComponent("project"))
        _ = try store.create(title: "Screenshots")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        let a = picture(2), b = picture(7)
        for anchor in [a, b] { try png.write(to: store.resolveRelativePath(anchor.imageRelativePath)) }
        var p = project([a, b], [speech([("甲。", 1, 3), ("乙。", 6, 8)])]); p.reconcileScreenshotCards()
        p.reviewCards[1].text = "人工改写乙。"
        try store.save(p)
        var reopened = try store.load(); reopened.reconcileScreenshotCards()
        XCTAssertEqual(reopened, p)
        XCTAssertEqual(reopened.cardsForExport, p.reviewCards)
        let bundle = root.appendingPathComponent("bundle")
        try ProjectExporter.exportBundle(project: reopened, store: store, to: bundle)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("project.json"))) as! [String: Any]
        let cards = json["cards"] as! [[String: Any]]
        XCTAssertEqual(cards.count, p.reviewCards.count)
        XCTAssertEqual(cards.map { $0["text"] as! String }, p.reviewCards.map(\.text))
        XCTAssertEqual(cards.map { $0["id"] as! String }, p.reviewCards.map { $0.id.uuidString })
        XCTAssertEqual(cards.map { ($0["moments"] as! [Any]).count }, [1, 1])
        XCTAssertEqual(reopened.anchors.count, 2, "Export and reopen must not extract frames")
    }
}
