import Foundation
import XCTest
@testable import PointAndTellCore

final class ASRProjectUpdatesTests: XCTestCase {
    private func timed(_ text: String = "Hello world.") -> TranscriptSegment {
        TranscriptSegment(text: text, startSeconds: 180.760, endSeconds: 183.800,
            words: [TranscriptWord(text: text, startSeconds: 180.760, endSeconds: 183.800)])
    }
    private func project(old: TranscriptSegment) -> ProjectManifest {
        ProjectManifest(title: "Old project", transcripts: [old],
            reviewCards: [ReviewCard(transcriptID: old.id, text: old.text,
                                    startSeconds: old.startSeconds, endSeconds: old.endSeconds)],
            asrChunks: [ASRChunk(relativePath: "audio/chunk.wav", startSeconds: 180,
                                durationSeconds: 10, state: .complete, sentences: [old])])
    }

    func testOnlyIncompleteCompletedChunksAreQueuedAndOldResultsRemain() throws {
        let old = TranscriptSegment(text: "Hello world.")
        var source = project(old: old)
        source.asrChunks.append(ASRChunk(index: 1, relativePath: "audio/good.wav", startSeconds: 200,
                                       durationSeconds: 10, state: .complete, sentences: [timed()]))
        XCTAssertTrue(source.asrChunks[0].needsTimestampRetry)
        XCTAssertFalse(source.asrChunks[1].needsTimestampRetry)
        let cards = source.reviewCards
        source.queueIncompleteTimestampChunks()
        XCTAssertEqual(source.asrChunks.map(\.state), [.pending, .complete])
        XCTAssertEqual(source.asrChunks[0].sentences, [old])
        XCTAssertEqual(source.transcripts, [old])
        XCTAssertEqual(source.reviewCards, cards)
        // A failed repair cannot delete the prior speech or editing.
        source.asrChunks[0].state = .failed
        XCTAssertEqual(source.asrChunks[0].sentences, [old])
    }

    func testSuccessfulRepairRebuildsUntouchedCardsAndPreservesSentenceIdentity() throws {
        let old = TranscriptSegment(text: "Hello world.")
        var source = project(old: old)
        source.queueIncompleteTimestampChunks()
        try source.acceptTranscription([timed()], forChunkAt: 0)
        XCTAssertTrue(source.reviewCards.isEmpty) // Recreated after actual local frame extraction.
        XCTAssertEqual(source.transcripts.first?.id, old.id)
        XCTAssertTrue(source.transcripts[0].hasCompleteWordTiming)
        XCTAssertEqual(source.asrChunks[0].state, .complete)
        XCTAssertFalse(source.asrChunks[0].needsTimestampRetry)
    }

    func testSelectedFramesAndEditedTextSurviveRepair() throws {
        let old = TranscriptSegment(text: "Hello world.")
        var source = project(old: old)
        let image = UUID()
        source.reviewCards[0].frameIDs = [image]
        source.reviewCards.append(ReviewCard(transcriptID: old.id, text: "User edit", startSeconds: 1, endSeconds: 2))
        try source.acceptTranscription([timed()], forChunkAt: 0)
        XCTAssertEqual(source.reviewCards[0].frameIDs, [image])
        XCTAssertEqual(source.reviewCards[0].startSeconds, 180.760)
        XCTAssertEqual(source.reviewCards[1].text, "User edit")
        XCTAssertEqual(source.reviewCards[1].startSeconds, 1)
        XCTAssertEqual(source.reviewCards[1].endSeconds, 2)
    }

    func testChangedSentenceBoundariesRetainReviewedCardWithoutInventingTiming() throws {
        let old = TranscriptSegment(text: "Hello world.")
        var source = project(old: old)
        source.reviewCards[0].text = "Hand reviewed"
        try source.acceptTranscription([timed("Hello."), timed("World.")], forChunkAt: 0)
        XCTAssertEqual(source.reviewCards[0].text, "Hand reviewed")
        XCTAssertNil(source.reviewCards[0].transcriptID)
        XCTAssertNil(source.reviewCards[0].startSeconds)
        XCTAssertEqual(source.transcripts.map(\.text), ["Hello.", "World."])
    }

    func testInvalidReplacementIsAtomicAndDoesNotDiscardTheOldResult() {
        let old = TranscriptSegment(text: "Hello world.")
        var source = project(old: old)
        let original = source
        XCTAssertThrowsError(try source.acceptTranscription([old], forChunkAt: 0)) {
            XCTAssertEqual($0 as? ASRError, .incompleteTimestamps)
        }
        XCTAssertEqual(source, original)
    }

    func testCompleteTimingRejectsMissingTokensOutOfRangeAndReversedWords() {
        var valid = timed()
        XCTAssertTrue(valid.hasCompleteWordTiming)
        valid.words = [TranscriptWord(text: "Hello", startSeconds: 180.760, endSeconds: 183.800)]
        XCTAssertFalse(valid.hasCompleteWordTiming)
        valid.words = [TranscriptWord(text: valid.text, startSeconds: 0, endSeconds: 183.800)]
        XCTAssertFalse(valid.hasCompleteWordTiming)
        valid.words = [TranscriptWord(text: valid.text, startSeconds: 183.800, endSeconds: 180.760)]
        XCTAssertFalse(valid.hasCompleteWordTiming)
    }

    func testProviderWordsRoundTripFromFinalJSONToRecordingClock() throws {
        let sentences = try ASRResponseParser.parse(data: Data(ASRFixtures.json.utf8)).validatedSentences()
        let segments = sentences.map { $0.transcriptSegment(chunkOffset: 180) }
        var source = project(old: TranscriptSegment(text: "Hello world."))
        try source.acceptTranscription(segments, forChunkAt: 0)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let restored = try decoder.decode(ProjectManifest.self, from: encoder.encode(source))
        XCTAssertEqual(restored.transcripts[0].words![0].startSeconds, 180.760, accuracy: 0.000001)
        XCTAssertEqual(restored.transcripts[0].words![1].endSeconds, 183.800, accuracy: 0.000001)
        XCTAssertFalse(restored.asrChunks[0].needsTimestampRetry)
    }
}
