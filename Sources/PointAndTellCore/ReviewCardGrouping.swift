import Foundation

/// Materialize exactly the passages used by HTML/Markdown as editable cards.
/// Provider sentences can cover an entire recording; they are not UI cards.
public enum ReviewCardGrouping {
    public static func cards(from card: ReviewCard, transcript: TranscriptSegment?,
                             anchors: [VisualAnchor]) -> [ReviewCard] {
        // Keep missing selections visible for repair rather than dropping them.
        let available = Set(anchors.map(\.id))
        guard card.frameIDs.allSatisfy({ available.contains($0) }) else { return [card] }
        let moments = TranscriptAlignment.moments(card: card, transcript: transcript, anchors: anchors)
        guard moments.count > 1 else { return [card] }
        return moments.enumerated().map { index, moment in
            ReviewCard(id: index == 0 ? card.id : UUID(), transcriptID: card.transcriptID,
                       text: moment.text, frameIDs: moment.imageIDs,
                       startSeconds: moment.startSeconds, endSeconds: moment.endSeconds)
        }
    }

    public static func cards(from cards: [ReviewCard], transcripts: [TranscriptSegment],
                             anchors: [VisualAnchor]) -> [ReviewCard] {
        cards.flatMap { card in
            self.cards(from: card, transcript: transcripts.first { $0.id == card.transcriptID }, anchors: anchors)
        }
    }
}

public extension ProjectManifest {
    /// Idempotent migration for old single-card projects. Edited text/times and
    /// manual selections stay intact; no transcription request is needed.
    @discardableResult mutating func groupReviewCards() -> Bool {
        let grouped = ReviewCardGrouping.cards(from: reviewCards, transcripts: transcripts, anchors: anchors)
        guard grouped != reviewCards else { return false }
        reviewCards = grouped
        return true
    }
}
