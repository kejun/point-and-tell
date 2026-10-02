import Foundation
import XCTest
@testable import PointAndTellCore

final class ReviewCardDeletionTests: XCTestCase {
    private func segment(_ text: String, start: Double = 1) -> TranscriptSegment {
        TranscriptSegment(text: text, startSeconds: start, endSeconds: start + 1,
            words: [TranscriptWord(text: text, startSeconds: start, endSeconds: start + 1)])
    }

    func testDeletingOneSplitCardPreservesSiblingAndOriginalMedia() {
        let source = segment("原始转写")
        let anchor = VisualAnchor(timestamp: 1, imageRelativePath: "frames/shared.png")
        let removed = ReviewCard(transcriptID: source.id, text: "删除的卡片", frameIDs: [anchor.id])
        let kept = ReviewCard(transcriptID: source.id, text: "保留的卡片", frameIDs: [anchor.id])
        var project = ProjectManifest(title: "Delete", anchors: [anchor], transcripts: [source], reviewCards: [removed, kept])
        XCTAssertTrue(project.deleteReviewCard(id: removed.id))
        project.appendSuggestedReviewCards(for: [source])
        XCTAssertEqual(project.reviewCards, [kept])
        XCTAssertEqual(project.cardsForExport, [kept])
        XCTAssertEqual(project.transcripts, [source])
        XCTAssertEqual(project.anchors, [anchor])
        let saved = project
        XCTAssertFalse(project.deleteReviewCard(id: removed.id))
        XCTAssertEqual(project, saved)
    }

    func testDeletingLastCardSurvivesReopenAndEmptyHTMLAndBundleExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(folderURL: root.appendingPathComponent("project"))
        var project = try store.create(title: "Delete all")
        let source = segment("这段内容已被删除")
        project.transcripts = [source]
        project.appendSuggestedReviewCards(for: [source])
        XCTAssertTrue(project.deleteReviewCard(id: project.reviewCards[0].id))
        try store.save(project)
        var reopened = try store.load()
        reopened.groupReviewCards()
        reopened.appendSuggestedReviewCards(for: [source])
        XCTAssertTrue(reopened.reviewCards.isEmpty)
        XCTAssertFalse(reopened.hasExportableCards)
        let htmlURL = root.appendingPathComponent("empty.html")
        try ProjectExporter.exportHTML(project: reopened, store: store, to: htmlURL)
        XCTAssertFalse(try String(contentsOf: htmlURL).contains(source.text))
        let bundle = root.appendingPathComponent("bundle")
        try ProjectExporter.exportBundle(project: reopened, store: store, to: bundle)
        XCTAssertFalse(try String(contentsOf: bundle.appendingPathComponent("README.md")).contains(source.text))
        let exported = try JSONSerialization.jsonObject(with: Data(contentsOf: bundle.appendingPathComponent("project.json"))) as! [String: Any]
        XCTAssertEqual((exported["cards"] as? [Any])?.count, 0)
    }

    func testLegacyTranscriptOnlyProjectRetainsExportFallback() throws {
        let source = segment("旧项目原文")
        let project = ProjectManifest(title: "Legacy", transcripts: [source])
        let data = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("reviewEdits"))
        let loaded = try JSONDecoder().decode(ProjectManifest.self, from: data)
        XCTAssertNil(loaded.reviewEdits)
        XCTAssertTrue(loaded.hasExportableCards)
        XCTAssertEqual(loaded.cardsForExport.map(\.text), [source.text])
    }

    func testDeletingManualCardAlsoKeepsEmptyReviewAuthoritative() {
        var project = ProjectManifest(title: "Manual", transcripts: [segment("原始内容")],
            reviewCards: [ReviewCard(text: "人工整理")])
        project.deleteReviewCard(id: project.reviewCards[0].id)
        project.appendSuggestedReviewCards(for: project.transcripts)
        XCTAssertNotNil(project.reviewEdits)
        XCTAssertTrue(project.cardsForExport.isEmpty)
        XCTAssertFalse(project.hasExportableCards)
    }

    func testRetryKeepsDeletionWhileAllowingNewChunks() throws {
        let old = segment("已经删除")
        let untouched = segment("保留内容", start: 3)
        var project = ProjectManifest(title: "Retry", transcripts: [old, untouched], asrChunks: [
            ASRChunk(index: 0, relativePath: "audio/0.wav", startSeconds: 0, durationSeconds: 5,
                state: .complete, sentences: [old, untouched])
        ])
        project.appendSuggestedReviewCards(for: project.transcripts)
        project.deleteReviewCard(id: project.reviewCards[0].id)
        try project.acceptTranscription([segment(old.text), segment(untouched.text, start: 3)], forChunkAt: 0)
        project.appendSuggestedReviewCards(for: project.transcripts)
        XCTAssertEqual(project.reviewCards.map(\.text), [untouched.text])
        // A corrected/resegmented deleted sentence must not silently reappear.
        try project.acceptTranscription([segment("已经删除的修正内容"), segment(untouched.text, start: 3)], forChunkAt: 0)
        project.appendSuggestedReviewCards(for: project.transcripts)
        XCTAssertEqual(project.reviewCards.map(\.text), [untouched.text])
        project.appendSuggestedReviewCards(for: [segment("新的片段", start: 10)])
        XCTAssertEqual(project.reviewCards.map(\.text), [untouched.text, "新的片段"])
    }
}
