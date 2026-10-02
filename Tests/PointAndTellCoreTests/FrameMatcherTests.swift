import XCTest
@testable import PointAndTellCore

final class FrameMatcherTests: XCTestCase {
    func testPenWinsOverBookmarkAndDefaultFrame() {
        let segment = TranscriptSegment(text: "Here", startSeconds: 10, endSeconds: 20)
        let frame = VisualAnchor(timestamp: 15, imageRelativePath: "frame.png")
        let bookmark = VisualAnchor(timestamp: 14, imageRelativePath: "bookmark.png", kind: .bookmark)
        let pen = VisualAnchor(timestamp: 19, imageRelativePath: "pen.png", kind: .pen)
        let outside = VisualAnchor(timestamp: 25, imageRelativePath: "outside.png", kind: .pen)
        XCTAssertEqual(FrameMatcher.matchingFrameIDs(for: segment, anchors: [outside, frame, bookmark, pen]), [pen.id])
        XCTAssertEqual(FrameMatcher.matchingFrameIDs(for: segment, anchors: [frame, bookmark]), [bookmark.id])
    }

    func testLongUtteranceUsesMultipleDistributedFramesAndAnchorPriority() {
        let segment = TranscriptSegment(text: "A long explanation", startSeconds: 30, endSeconds: 90)
        let frames = [35.0, 50, 65, 80].map { VisualAnchor(timestamp: $0, imageRelativePath: "\($0).png") }
        let pen = VisualAnchor(timestamp: 58, imageRelativePath: "pen.png", kind: .pen)
        let selected = FrameMatcher.matchingFrameIDs(for: segment, anchors: frames + [pen])
        XCTAssertEqual(selected, [frames[0].id, pen.id, frames[2].id, frames[3].id])
    }

    func testMissingPartialAndInvalidTimingNeverGuessFrames() {
        let anchor = VisualAnchor(timestamp: 0, imageRelativePath: "image.png")
        let segments = [TranscriptSegment(text: "No timing"),
                        TranscriptSegment(text: "Partial", startSeconds: 0),
                        TranscriptSegment(text: "Reversed", startSeconds: 2, endSeconds: 1),
                        TranscriptSegment(text: "Nonfinite", startSeconds: .nan, endSeconds: 1)]
        for segment in segments {
            XCTAssertTrue(FrameMatcher.matchingFrameIDs(for: segment, anchors: [anchor]).isEmpty)
        }
    }

    func testNoOutOfSegmentFallbackAndBoundaryAnchorsAreIncluded() {
        let segment = TranscriptSegment(text: "Only this interval", startSeconds: 10, endSeconds: 12)
        let outside = VisualAnchor(timestamp: 9.99, imageRelativePath: "before.png", kind: .pen)
        XCTAssertTrue(FrameMatcher.matchingFrameIDs(for: segment, anchors: [outside]).isEmpty)
        let boundary = VisualAnchor(timestamp: 12, imageRelativePath: "boundary.png")
        XCTAssertEqual(FrameMatcher.matchingFrameIDs(for: segment, anchors: [boundary]), [boundary.id])
    }

    func testChunkOffsetIsExactAndMissingTimingStaysMissing() {
        let local = TranscriptSegment(text: "Second chunk", startSeconds: 1.125, endSeconds: 3.5)
        let global = local.offset(by: 180)
        XCTAssertEqual(global.startSeconds, 181.125)
        XCTAssertEqual(global.endSeconds, 183.5)
        XCTAssertEqual(global.id, local.id)
        let anchor = VisualAnchor(timestamp: 182, imageRelativePath: "image.png")
        XCTAssertEqual(FrameMatcher.matchingFrameIDs(for: global, anchors: [anchor]), [anchor.id])
        XCTAssertFalse(TranscriptSegment(text: "No time").offset(by: 180).isTimed)
        XCTAssertNil(TranscriptSegment(text: "No time").offset(by: 180).startSeconds)
    }

    func testSuggestedCardsKeepTextTimingAndReference() {
        let transcript = TranscriptSegment(text: "中文 & emoji 🦊", startSeconds: 1, endSeconds: 2)
        let anchor = VisualAnchor(timestamp: 1.5, imageRelativePath: "frame.png")
        let cards = FrameMatcher.suggestCards(for: [transcript], anchors: [anchor])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].text, transcript.text)
        XCTAssertEqual(cards[0].transcriptID, transcript.id)
        XCTAssertEqual(cards[0].frameIDs, [anchor.id])
        XCTAssertEqual(cards[0].startSeconds, 1)
    }
}
