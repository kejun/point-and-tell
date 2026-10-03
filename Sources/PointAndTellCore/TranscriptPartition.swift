import Foundation

/// An exact source slice. Sentence-only slices retain the enclosing sentence's
/// actual interval; subdividing text never invents more precise speech times.
public struct ReviewPassage: Codable, Equatable, Sendable {
    public var text: String
    public var transcriptID: UUID?
    public var sourceUTF16Start: Int?
    public var sourceUTF16End: Int?
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var firstWordIndex: Int?
    public var lastWordIndex: Int?

    public var precision: String {
        startSeconds == nil ? "untimed" : (firstWordIndex == nil ? "sentence" : "word")
    }

    public static func joinedText(_ passages: [ReviewPassage]) -> String {
        var text = "", previous: UUID?
        for passage in passages {
            if !text.isEmpty, let old = previous, let next = passage.transcriptID, old != next {
                text += "\n"
            }
            text += passage.text; previous = passage.transcriptID
        }
        return text
    }
}

/// Fixed-count, ordered partitioning. Every input slice is assigned exactly
/// once. Time and punctuation rank complete drafts, never reject their text.
/// Additive slice/boundary costs let the dynamic program run in O(cards * slices).
public enum ScreenshotCardMatcher {
    public static func orderedAnchors(_ anchors: [VisualAnchor]) -> [VisualAnchor] {
        var seen = Set<UUID>()
        return anchors.enumerated().filter { $0.element.isRecordingScreenshot && seen.insert($0.element.id).inserted }
            .sorted { $0.element.timestamp == $1.element.timestamp
                ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }
            .map(\.element)
    }

    public static func cards(anchors: [VisualAnchor], transcripts: [TranscriptSegment]) -> [ReviewCard] {
        let pictures = orderedAnchors(anchors)
        guard !pictures.isEmpty else { return [] }
        // The provider/chunk order is authoritative, including untimed passages.
        // Sorting by optional timestamps would move or drop part of the original.
        var units = transcripts.flatMap { slices($0) }
        if units.count < pictures.count {
            // Some providers put a whole sentence in a single "word" token.
            // Allow textual cuts while honestly falling back to sentence timing.
            units = transcripts.flatMap { slices($0, useWords: false) }
        }
        let ranges = partition(units, pictures: pictures)
        return pictures.indices.map { index in
            let picture = pictures[index]
            let passages = grouped(Array(units[ranges[index]]))
            let matches = speechMatches(passages, screenshot: picture.timestamp)
            var reasons = ["按截图数量连续分段，全文按原顺序分配；时间只辅助选择分界"]
            if passages.contains(where: { $0.precision == "sentence" }) {
                reasons.append("句级时间表示原句范围，文字分段不会生成新的词级时间")
            }
            if passages.contains(where: { $0.precision == "untimed" }) {
                reasons.append("无时间戳文字也按顺序保留，可直接编辑")
            }
            if ranges[index].upperBound < units.count, ranges[index].upperBound > 0,
               pause(at: ranges[index].upperBound, in: units) > 0.6 {
                reasons.append("分界参考真实语音停顿")
            }
            let association = ScreenshotAssociation(status: passages.isEmpty ? .unmatched : .matched,
                screenshotSeconds: picture.timestamp, captureStartSeconds: picture.captureStartSeconds,
                captureEndSeconds: picture.captureEndSeconds, annotationStartSeconds: picture.annotationStartSeconds,
                annotationEndSeconds: picture.endTimestamp, matches: matches, reasons: reasons,
                includesUntimedText: passages.contains { $0.precision == "untimed" })
            let timing = bounds(passages)
            let ids = Set(passages.compactMap(\.transcriptID))
            var card = ReviewCard(id: picture.id, transcriptID: ids.count == 1 ? ids.first : nil,
                text: ReviewPassage.joinedText(passages), frameIDs: [picture.id],
                startSeconds: timing.0, endSeconds: timing.1, sourceAnchorID: picture.id,
                association: association, passages: passages)
            card.generatedContent = ReviewCardContent(card)
            return card
        }
    }

    private static func slices(_ source: TranscriptSegment, useWords: Bool = true) -> [ReviewPassage] {
        let start = source.isTimed ? source.startSeconds : nil
        let end = source.isTimed ? source.endSeconds : nil
        var offset = 0
        if useWords, source.hasCompleteWordTiming, let words = source.words,
           let texts = TranscriptAlignment.exactSlices(text: source.text, words: words, start: start!, end: end!) {
            return texts.enumerated().map { index, text in
                let lower = offset; offset += text.utf16.count
                return ReviewPassage(text: text, transcriptID: source.id, sourceUTF16Start: lower,
                    sourceUTF16End: offset, startSeconds: words[index].startSeconds,
                    endSeconds: words[index].endSeconds, firstWordIndex: index, lastWordIndex: index)
            }
        }
        // Keep whitespace/punctuation verbatim. CJK graphemes are fallback cut
        // positions; Latin words and composed emoji remain whole. Natural clause
        // and sentence boundaries have much lower costs than these fallback cuts.
        var pieces: [ReviewPassage] = []
        for character in source.text {
            let text = String(character), lower = offset
            offset += text.utf16.count
            let punctuation = character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            let append = !pieces.isEmpty && (character.isWhitespace || punctuation
                || (westernWord(character) && pieces.last!.text.last.map(westernWord) == true)
                || pieces.last!.text.allSatisfy { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) } })
            if append {
                pieces[pieces.count - 1].text += text
                pieces[pieces.count - 1].sourceUTF16End = offset
            } else {
                pieces.append(ReviewPassage(text: text, transcriptID: source.id, sourceUTF16Start: lower,
                    sourceUTF16End: offset, startSeconds: start, endSeconds: end,
                    firstWordIndex: nil, lastWordIndex: nil))
            }
        }
        return pieces
    }

    private static func westernWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && !((0x2E80...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x323AF).contains($0.value))
        }
    }

    private static func ending(_ text: String) -> Character? {
        text.last { !$0.isWhitespace && !"”’\"'）)]】》」』".contains($0) }
    }

    private static func sentenceEnd(_ text: String) -> Bool {
        text.contains("\n") || ending(text).map { "。！？!?；;.".contains($0) } == true
    }

    private static func pause(at index: Int, in units: [ReviewPassage]) -> Double {
        guard index > 0, index < units.count, let left = units[index - 1].endSeconds,
              let right = units[index].startSeconds else { return 0 }
        return max(0, right - left)
    }

    private static func partition(_ units: [ReviewPassage], pictures: [VisualAnchor]) -> [Range<Int>] {
        let n = units.count, k = pictures.count
        guard n > 0 else { return Array(repeating: 0..<0, count: k) }
        let counts = units.map { max(1, $0.text.filter { !$0.isWhitespace }.count) }
        var mass = [0]
        for count in counts { mass.append(mass.last! + count) }
        let total = Double(mass[n])
        var previous = Array(repeating: Double.infinity, count: n + 1); previous[0] = 0
        var parents = Array(repeating: Array(repeating: -1, count: n + 1), count: k)
        for card in pictures.indices {
            let picture = pictures[card]
            let last = picture.kind == .pen ? max(picture.timestamp, picture.endTimestamp ?? picture.timestamp) : picture.timestamp
            let leftGap = card > 0 ? picture.timestamp - pictures[card - 1].timestamp : 0
            let rightGap = card + 1 < k ? pictures[card + 1].timestamp - picture.timestamp : 0
            let scale = max(2, min(20, max(leftGap, rightGap) / 2))
            var prefix = [0.0]
            for (index, unit) in units.enumerated() {
                var cost = 0.0
                if let start = unit.startSeconds, let end = unit.endSeconds {
                    let distance = max(0, max(picture.timestamp - end, start - last))
                    cost = min(3, distance / scale) * Double(counts[index]) / total * Double(k) * 2
                }
                prefix.append(prefix.last! + cost)
            }
            var next = Array(repeating: Double.infinity, count: n + 1)
            if n < k {
                // Only genuinely insufficient text can leave a card empty.
                // Use every slice on a distinct card, with deterministic ties.
                for end in 0...n {
                    if previous[end].isFinite { next[end] = previous[end]; parents[card][end] = end }
                    if end > 0, previous[end - 1].isFinite {
                        let cost = previous[end - 1] + prefix[end] - prefix[end - 1]
                        if cost < next[end] {
                            next[end] = cost; parents[card][end] = end - 1
                        }
                    }
                }
            } else {
                var best = Double.infinity, bestStart = -1
                for end in 1...n {
                    let start = end - 1
                    if previous[start].isFinite {
                        var boundary = 0.0
                        if card > 0, start > 0 {
                            let left = units[start - 1], right = units[start]
                            if sentenceEnd(left.text) { boundary = 0 }
                            else if left.transcriptID != right.transcriptID { boundary = 0.5 }
                            else if ending(left.text).map({ "，,、：:".contains($0) }) == true { boundary = 2 }
                            else if left.text.last?.isWhitespace == true || right.text.first?.isWhitespace == true { boundary = 4 }
                            else { boundary = 8 }
                            boundary -= min(1, pause(at: start, in: units) / 2) * 0.75
                            // A weak tie-break only; unequal-length explanations are normal.
                            boundary += abs(Double(mass[start]) / total - Double(card) / Double(k)) * 0.04
                        }
                        let cost = previous[start] - prefix[start] + boundary
                        if cost < best { best = cost; bestStart = start }
                    }
                    if bestStart >= 0 { next[end] = prefix[end] + best; parents[card][end] = bestStart }
                }
            }
            previous = next
        }
        var result = Array(repeating: 0..<0, count: k), end = n
        for card in pictures.indices.reversed() {
            let start = parents[card][end]
            precondition(start >= 0, "A complete ordered partition always exists")
            result[card] = start..<end; end = start
        }
        return result
    }

    static func grouped(_ units: [ReviewPassage]) -> [ReviewPassage] {
        var passages: [ReviewPassage] = []
        for unit in units {
            if let last = passages.last, last.transcriptID == unit.transcriptID,
               last.sourceUTF16End == unit.sourceUTF16Start, !sentenceEnd(last.text) {
                let index = passages.count - 1
                passages[index].text += unit.text
                passages[index].sourceUTF16End = unit.sourceUTF16End
                passages[index].lastWordIndex = unit.lastWordIndex
                if let start = last.startSeconds, let next = unit.startSeconds,
                   let end = last.endSeconds, let nextEnd = unit.endSeconds {
                    passages[index].startSeconds = min(start, next)
                    passages[index].endSeconds = max(end, nextEnd)
                } else { passages[index].startSeconds = nil; passages[index].endSeconds = nil }
            } else { passages.append(unit) }
        }
        return passages
    }

    static func editablePassages(_ card: ReviewCard) -> [ReviewPassage] {
        if let passages = card.passages, ReviewPassage.joinedText(passages) == card.text { return passages }
        return grouped(slices(TranscriptSegment(text: card.text))).map {
            var passage = $0
            passage.transcriptID = nil; passage.sourceUTF16Start = nil; passage.sourceUTF16End = nil
            return passage
        }
    }

    static func bounds(_ passages: [ReviewPassage]) -> (Double?, Double?) {
        guard !passages.isEmpty, passages.allSatisfy({ $0.startSeconds != nil && $0.endSeconds != nil }) else { return (nil, nil) }
        return (passages.compactMap(\.startSeconds).min(), passages.compactMap(\.endSeconds).max())
    }

    static func speechMatches(_ passages: [ReviewPassage], screenshot: Double) -> [SpeechMatch] {
        var matches: [SpeechMatch] = []
        for passage in passages {
            guard let id = passage.transcriptID, let start = passage.startSeconds, let end = passage.endSeconds else { continue }
            if let last = matches.last, last.transcriptID == id, last.precision == passage.precision,
               (last.lastWordIndex.map { $0 + 1 } == passage.firstWordIndex) {
                matches[matches.count - 1].startSeconds = min(last.startSeconds, start)
                matches[matches.count - 1].endSeconds = max(last.endSeconds, end)
                matches[matches.count - 1].lastWordIndex = passage.lastWordIndex
            } else {
                matches.append(SpeechMatch(transcriptID: id, startSeconds: start, endSeconds: end,
                    firstWordIndex: passage.firstWordIndex, lastWordIndex: passage.lastWordIndex,
                    precision: passage.precision, offsetSeconds: start - screenshot))
            }
        }
        return matches
    }
}

public extension ProjectManifest {
    /// Move only a boundary passage, keeping source order and both screenshot IDs.
    /// Callers persist a copy before replacing their visible project.
    @discardableResult mutating func moveBoundaryPassage(cardID: UUID, toPrevious: Bool) -> Bool {
        guard let source = reviewCards.firstIndex(where: { $0.id == cardID }) else { return false }
        let target = source + (toPrevious ? -1 : 1)
        guard reviewCards.indices.contains(target) else { return false }
        var from = ScreenshotCardMatcher.editablePassages(reviewCards[source])
        var to = ScreenshotCardMatcher.editablePassages(reviewCards[target])
        guard !from.isEmpty else { return false }
        if toPrevious { to.append(from.removeFirst()) }
        else { to.insert(from.removeLast(), at: 0) }
        for (index, passages) in [(source, from), (target, to)] {
            let old = reviewCards[index]
            let oldBounds = ScreenshotCardMatcher.bounds(old.passages ?? [])
            // Explicitly edited timing stays authoritative; automatic ranges follow the text.
            if old.isAutomaticallyManaged || (old.passages != nil && old.startSeconds == oldBounds.0 && old.endSeconds == oldBounds.1) {
                let timing = ScreenshotCardMatcher.bounds(passages)
                reviewCards[index].startSeconds = timing.0; reviewCards[index].endSeconds = timing.1
            }
            reviewCards[index].passages = passages
            reviewCards[index].text = ReviewPassage.joinedText(passages)
            reviewCards[index].userEdited = true
            let ids = Set(passages.compactMap(\.transcriptID))
            reviewCards[index].transcriptID = ids.count == 1 ? ids.first : nil
            if let association = old.association {
                reviewCards[index].association?.matches = ScreenshotCardMatcher.speechMatches(passages, screenshot: association.screenshotSeconds)
                reviewCards[index].association?.status = passages.isEmpty ? .unmatched : .matched
                reviewCards[index].association?.includesUntimedText = passages.contains { $0.precision == "untimed" }
                reviewCards[index].association?.reasons = ["已手动调整相邻卡片的讲解分界"]
            }
        }
        return true
    }
}
