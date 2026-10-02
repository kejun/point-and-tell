import Foundation

/// A passage and its selected screenshots on the recording clock. Speech times
/// always come from the provider (or an explicit card edit), never interpolation.
public struct TranscriptMoment: Codable, Equatable {
    public let text: String
    public let startSeconds: Double?
    public let endSeconds: Double?
    public let imageIDs: [UUID]
    public let timingPrecision: String
}

public enum TranscriptAlignment {
    public static func moments(card: ReviewCard, transcript: TranscriptSegment?,
                               anchors: [VisualAnchor]) -> [TranscriptMoment] {
        var seen = Set<UUID>()
        let selected = anchors.filter { card.frameIDs.contains($0.id) && seen.insert($0.id).inserted }
            .sorted { $0.timestamp == $1.timestamp
                ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp }
        func fallback(_ precision: String) -> [TranscriptMoment] {
            [TranscriptMoment(text: card.text, startSeconds: card.isTimed ? card.startSeconds : nil,
                              endSeconds: card.isTimed ? card.endSeconds : nil,
                              imageIDs: card.frameIDs.filter { id in selected.contains { $0.id == id } }
                                .reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } },
                              timingPrecision: precision)]
        }
        if card.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !selected.isEmpty {
            return fallback("screenshot-only")
        }
        guard card.isTimed else { return fallback("untimed") }
        guard let transcript = transcript else { return fallback("manual") }
        guard transcript.text == card.text, transcript.startSeconds == card.startSeconds,
              transcript.endSeconds == card.endSeconds else {
            // A generated card holds an exact word-timed excerpt. Do not call
            // it an edit or split it again using its now shorter time interval:
            // the selected snapshot may lie just outside those spoken words.
            if isExactExcerpt(card: card, transcript: transcript) { return fallback("word") }
            return fallback("manual")
        }
        guard let words = transcript.words, !words.isEmpty, !selected.isEmpty,
              let start = card.startSeconds, let end = card.endSeconds,
              selected.allSatisfy({ $0.timestamp.isFinite && $0.timestamp >= start && $0.timestamp <= end }),
              let slices = exactSlices(text: card.text, words: words, start: start, end: end) else {
            return fallback("sentence")
        }

        // Equal-time screenshots share a passage. Otherwise ownership changes at
        // the exact midpoint between selected snapshots. A word crossing a boundary
        // stays whole; its midpoint chooses the nearest snapshot, ties go later.
        var groups: [[VisualAnchor]] = []
        for anchor in selected {
            if groups.last?.first?.timestamp == anchor.timestamp { groups[groups.count - 1].append(anchor) }
            else { groups.append([anchor]) }
        }
        var texts = Array(repeating: "", count: groups.count)
        var starts = Array<Double?>(repeating: nil, count: groups.count)
        var ends = starts
        var group = 0
        for (index, word) in words.enumerated() {
            let midpoint = word.startSeconds + (word.endSeconds - word.startSeconds) / 2
            while group + 1 < groups.count {
                let left = groups[group][0].timestamp, right = groups[group + 1][0].timestamp
                guard midpoint >= left + (right - left) / 2 else { break }
                group += 1
            }
            texts[group] += slices[index]
            if starts[group] == nil { starts[group] = word.startSeconds }
            ends[group] = word.endSeconds
        }
        return groups.indices.map {
            TranscriptMoment(text: texts[$0], startSeconds: starts[$0], endSeconds: ends[$0],
                             imageIDs: groups[$0].map(\.id),
                             timingPrecision: texts[$0].isEmpty ? "screenshot-only" : "word")
        }
    }

    private static func isExactExcerpt(card: ReviewCard, transcript: TranscriptSegment) -> Bool {
        guard let words = transcript.words, !words.isEmpty,
              let start = transcript.startSeconds, let end = transcript.endSeconds,
              let slices = exactSlices(text: transcript.text, words: words, start: start, end: end) else { return false }
        for lower in words.indices where words[lower].startSeconds == card.startSeconds {
            for upper in lower..<words.count where words[upper].endSeconds == card.endSeconds {
                if slices[lower...upper].joined() == card.text { return true }
            }
        }
        return false
    }

    /// Match the entire original text. Only whitespace may be absent from provider
    /// tokens; preserve it in the slices. Edits, missing tokens and punctuation
    /// mismatches deliberately fall back to sentence-level timing.
    private static func exactSlices(text: String, words: [TranscriptWord], start: Double, end: Double) -> [String]? {
        var cursor = text.startIndex
        var slices: [String] = []
        var previousStart = start, previousEnd = start
        for word in words {
            guard word.startSeconds.isFinite, word.endSeconds.isFinite,
                  word.startSeconds >= previousStart, word.endSeconds >= previousEnd,
                  word.endSeconds >= word.startSeconds, word.endSeconds <= end else { return nil }
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, let range = text.range(of: token, range: cursor..<text.endIndex),
                  text[cursor..<range.lowerBound].allSatisfy({ $0.isWhitespace }) else { return nil }
            slices.append(String(text[cursor..<range.upperBound]))
            cursor = range.upperBound
            previousStart = word.startSeconds; previousEnd = word.endSeconds
        }
        guard text[cursor...].allSatisfy({ $0.isWhitespace }) else { return nil }
        slices[slices.count - 1] += text[cursor...]
        return slices
    }
}
