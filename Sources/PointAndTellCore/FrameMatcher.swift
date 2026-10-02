import Foundation

public enum FrameMatcher {
    /// All comparisons use recording-relative seconds supplied by capture and ASR.
    /// Untimed speech receives no automatic images and stays available for manual review.
    public static func matchingFrameIDs(for segment: TranscriptSegment, anchors: [VisualAnchor],
                                        longUtteranceThreshold: Double = 20,
                                        frameInterval: Double = 15,
                                        maximumFrames: Int = 6) -> [UUID] {
        guard segment.isTimed, let start = segment.startSeconds, let end = segment.endSeconds,
              maximumFrames > 0 else { return [] }
        func activeEnd(_ anchor: VisualAnchor) -> Double {
            guard anchor.kind == .pen, let end = anchor.endTimestamp,
                  end.isFinite, end >= anchor.timestamp else { return anchor.timestamp }
            return end
        }
        let candidates = anchors.filter {
            $0.timestamp.isFinite && $0.timestamp >= 0 && $0.timestamp <= end && activeEnd($0) >= start
        }
        guard !candidates.isEmpty else { return [] }
        let duration = end - start
        let midpoint = start + duration / 2
        func best(_ options: [VisualAnchor], around center: Double) -> VisualAnchor? {
            options.sorted {
                if $0.kind.matchingPriority != $1.kind.matchingPriority {
                    return $0.kind.matchingPriority > $1.kind.matchingPriority
                }
                func distance(_ anchor: VisualAnchor) -> Double {
                    if center < anchor.timestamp { return anchor.timestamp - center }
                    if center > activeEnd(anchor) { return center - activeEnd(anchor) }
                    return 0
                }
                let lhsDistance = distance($0), rhsDistance = distance($1)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            }.first
        }
        guard longUtteranceThreshold.isFinite, duration > max(0, longUtteranceThreshold),
              frameInterval.isFinite, frameInterval > 0 else {
            return best(candidates, around: midpoint).map { [$0.id] } ?? []
        }
        // Evenly distribute bounded windows across long speech, including its final moments.
        // Do not let many early annotations consume every slot in a long utterance.
        let proposedCount = ceil(duration / frameInterval)
        let count = proposedCount >= Double(maximumFrames) ? maximumFrames : max(2, Int(proposedCount))
        let window = duration / Double(count)
        var selected: [VisualAnchor] = []
        for index in 0..<count {
            let lower = start + Double(index) * window
            let upper = index == count - 1 ? end : start + Double(index + 1) * window
            let options = candidates.filter { anchor in
                activeEnd(anchor) >= lower && (index == count - 1 ? anchor.timestamp <= upper : anchor.timestamp < upper)
                    && !selected.contains(where: { $0.id == anchor.id })
            }
            if let anchor = best(options, around: lower + (upper - lower) / 2),
               !selected.contains(where: { $0.id == anchor.id }) {
                selected.append(anchor)
            }
        }
        return selected.sorted { $0.timestamp < $1.timestamp }.map(\.id)
    }

    public static func suggestCards(for transcripts: [TranscriptSegment], anchors: [VisualAnchor]) -> [ReviewCard] {
        transcripts.map { segment in
            ReviewCard(transcriptID: segment.id, text: segment.text,
                       frameIDs: matchingFrameIDs(for: segment, anchors: anchors),
                       startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)
        }
    }
}
