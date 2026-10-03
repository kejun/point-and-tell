import Foundation

public extension ProjectManifest {
    /// Called only after upload consent. Old results survive cancellation/failure.
    mutating func queueIncompleteTimestampChunks() {
        for index in asrChunks.indices where asrChunks[index].needsTimestampRetry {
            asrChunks[index].state = .pending
            asrChunks[index].errorMessage = nil
            asrChunks[index].diagnostic = nil
        }
    }

    /// Replace only a successfully validated chunk. Preserve reviewed text and
    /// selected screenshots while allowing untouched placeholders to be rebuilt.
    mutating func acceptTranscription(_ segments: [TranscriptSegment], forChunkAt index: Int) throws {
        guard asrChunks.indices.contains(index) else { throw ProjectError.invalidManifest("missing ASR chunk") }
        guard !segments.isEmpty else { throw ASRError.noFinalSentences }
        if screenshotCardVersion == nil && !segments.allSatisfy(\.hasCompleteWordTiming) {
            throw ASRError.incompleteTimestamps
        }
        let previous = asrChunks[index].sentences
        var used = Set<UUID>()
        let replacements = segments.map { incoming -> TranscriptSegment in
            var segment = incoming
            if let old = previous.first(where: { $0.text == incoming.text && !used.contains($0.id) }) {
                segment.id = old.id; used.insert(old.id)
            }
            return segment
        }
        if screenshotCardVersion != nil {
            asrChunks[index].sentences = replacements
            asrChunks[index].state = .complete
            asrChunks[index].errorMessage = nil
            asrChunks[index].diagnostic = nil
            transcripts = asrChunks.sorted { $0.index < $1.index }.flatMap(\.sentences)
            reconcileScreenshotCards()
            return
        }
        // If a deleted sentence's boundary/text changed, its new identity cannot
        // be matched safely. Suppress unmatched replacements in that same chunk
        // rather than silently restoring content the user removed. Matched other
        // sentences and completely new chunks remain eligible for suggestions.
        let suppressed = Set(reviewEdits?.suppressedTranscriptIDs ?? [])
        if previous.contains(where: { suppressed.contains($0.id) && !used.contains($0.id) }) {
            let oldIDs = Set(previous.map(\.id))
            for replacement in replacements where !oldIDs.contains(replacement.id)
                && !suppressed.contains(replacement.id) {
                reviewEdits?.suppressedTranscriptIDs.append(replacement.id)
            }
        }
        reviewCards = reviewCards.compactMap { original -> ReviewCard? in
            guard let old = previous.first(where: { $0.id == original.transcriptID }) else { return original }
            let unchanged = original.text == old.text && original.startSeconds == old.startSeconds
                && original.endSeconds == old.endSeconds
            // Let buildReviewFrames regenerate untouched automatic placeholders
            // after extracting screenshots at the new provider times.
            if unchanged && original.frameIDs.isEmpty { return nil }
            var card = original
            if let replacement = replacements.first(where: { $0.id == old.id }) {
                if unchanged { card.startSeconds = replacement.startSeconds; card.endSeconds = replacement.endSeconds }
            } else {
                // A changed sentence boundary must not assign new timing to an
                // edited passage. Keep that reviewed card as a manual card.
                card.transcriptID = nil
            }
            return card
        }
        asrChunks[index].sentences = replacements
        asrChunks[index].state = .complete
        asrChunks[index].errorMessage = nil
        asrChunks[index].diagnostic = nil
        transcripts = asrChunks.sorted { $0.index < $1.index }.flatMap(\.sentences)
    }
}
