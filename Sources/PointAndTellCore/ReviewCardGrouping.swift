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
    /// Delete the review card only. Shared anchors, source text and media remain
    /// available, but automatic retries must not recreate the deleted passage.
    @discardableResult mutating func deleteReviewCard(id: UUID) -> Bool {
        guard let index = reviewCards.firstIndex(where: { $0.id == id }) else { return false }
        let card = reviewCards.remove(at: index)
        if reviewEdits == nil { reviewEdits = ReviewEdits() }
        if let transcriptID = card.transcriptID,
           reviewEdits?.suppressedTranscriptIDs.contains(transcriptID) == false {
            reviewEdits?.suppressedTranscriptIDs.append(transcriptID)
        }
        if reviewCards.isEmpty {
            // This also covers the final manual/detached card, whose source ID
            // may no longer be known after a provider changed sentence bounds.
            for source in transcripts where reviewEdits?.suppressedTranscriptIDs.contains(source.id) == false {
                reviewEdits?.suppressedTranscriptIDs.append(source.id)
            }
        }
        return true
    }

    var hasExportableCards: Bool {
        !reviewCards.isEmpty || (reviewEdits == nil && !transcripts.isEmpty)
    }

    var cardsForExport: [ReviewCard] {
        if reviewCards.isEmpty {
            return reviewEdits == nil ? FrameMatcher.suggestCards(for: transcripts, anchors: anchors) : []
        }
        return ReviewCardGrouping.cards(from: reviewCards, transcripts: transcripts, anchors: anchors)
    }

    mutating func appendSuggestedReviewCards(for segments: [TranscriptSegment]) {
        let represented = Set(reviewCards.compactMap(\.transcriptID))
            .union(reviewEdits?.suppressedTranscriptIDs ?? [])
        reviewCards.append(contentsOf: FrameMatcher.suggestCards(
            for: segments.filter { !represented.contains($0.id) }, anchors: anchors))
        groupReviewCards()
    }

    /// Idempotent migration for old single-card projects. Edited text/times and
    /// manual selections stay intact; no transcription request is needed.
    @discardableResult mutating func groupReviewCards() -> Bool {
        let grouped = ReviewCardGrouping.cards(from: reviewCards, transcripts: transcripts, anchors: anchors)
        guard grouped != reviewCards else { return false }
        reviewCards = grouped
        return true
    }
}
