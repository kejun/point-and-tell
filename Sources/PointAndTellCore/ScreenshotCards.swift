import Foundation

public struct ReviewCardContent: Codable, Equatable, Sendable {
    public var text: String
    public var frameIDs: [UUID]
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(_ card: ReviewCard) {
        text = card.text; frameIDs = card.frameIDs
        startSeconds = card.startSeconds; endSeconds = card.endSeconds
    }
}

public struct SpeechMatch: Codable, Equatable, Sendable {
    public var transcriptID: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var firstWordIndex: Int?
    public var lastWordIndex: Int?
    public var precision: String
    /// Signed distance from the screenshot to the beginning of the spoken passage.
    public var offsetSeconds: Double
}

public struct ScreenshotAssociation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case matched, needsReview, unmatched }
    public var status: Status
    public var screenshotSeconds: Double
    public var annotationEndSeconds: Double?
    public var matches: [SpeechMatch]
    public var reasons: [String]

    public var precision: String {
        let values = Set(matches.map(\.precision))
        if values.count > 1 { return "mixed" }
        return values.first ?? "untimed"
    }

    public var summary: String {
        switch status {
        case .matched: return precision == "word" ? "按词时间关联 · 请校对" : "按句时间关联 · 请校对"
        case .needsReview: return "关联有歧义 · 需校对"
        case .unmatched: return "未关联讲解 · 可手动补充"
        }
    }
}

public extension ReviewCard {
    var isAutomaticallyManaged: Bool {
        sourceAnchorID != nil && userEdited != true && generatedContent == ReviewCardContent(self)
    }
}

/// A screenshot always owns a card. Real speech units are assigned at most once.
/// Candidate distance is only a retrieval limit: annotation overlap, adjacent
/// screenshot cells and real speech pauses decide ownership. No semantic claim
/// is made, and neither word times nor sentence subdivisions are synthesized.
public enum ScreenshotCardMatcher {
    private struct Unit {
        let transcriptID: UUID
        let text: String
        let start: Double
        let end: Double
        let wordIndex: Int?
        let order: Int
        var precision: String { wordIndex == nil ? "sentence" : "word" }
        var midpoint: Double { start + (end - start) / 2 }
    }

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
        var units: [Unit] = []
        for transcript in transcripts where transcript.isTimed {
            let start = transcript.startSeconds!, end = transcript.endSeconds!
            if transcript.hasCompleteWordTiming, let words = transcript.words,
               let slices = TranscriptAlignment.exactSlices(text: transcript.text, words: words, start: start, end: end) {
                for (index, word) in words.enumerated() {
                    units.append(Unit(transcriptID: transcript.id, text: slices[index], start: word.startSeconds,
                        end: word.endSeconds, wordIndex: index, order: units.count))
                }
            } else if !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                units.append(Unit(transcriptID: transcript.id, text: transcript.text,
                    start: start, end: end, wordIndex: nil, order: units.count))
            }
        }
        units.sort { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        func activeEnd(_ anchor: VisualAnchor) -> Double {
            anchor.kind == .pen ? max(anchor.timestamp, anchor.endTimestamp ?? anchor.timestamp) : anchor.timestamp
        }
        // Find a real silence between adjacent images when possible. These
        // decision boundaries NEVER become stored speech timestamps.
        var boundaries: [Double] = []
        var boundaryReasons: [String] = []
        for index in pictures.indices.dropLast() {
            let lower = activeEnd(pictures[index]), upper = pictures[index + 1].timestamp
            let center = lower + (upper - lower) / 2
            var chosen = center, longest = 0.6
            if lower < upper {
                for pair in zip(units, units.dropFirst()) {
                    let gapStart = pair.0.end, gapEnd = pair.1.start
                    let gap = gapEnd - gapStart
                    if gapStart >= lower && gapEnd <= upper && gap > longest {
                        longest = gap; chosen = gapStart + gap / 2
                    }
                }
            }
            boundaries.append(max(pictures[index].timestamp, min(upper, chosen)))
            boundaryReasons.append(longest > 0.6 ? "相邻截图间的真实语音停顿" : "相邻截图顺序边界，保留完整词")
        }
        var assigned = Array(repeating: [Unit](), count: pictures.count)
        var ambiguous = Set<Int>()
        var evidence = Array(repeating: Set<String>(), count: pictures.count)
        for unit in units {
            let candidates = pictures.indices.filter { index in
                let picture = pictures[index]
                let distance = max(0, max(picture.timestamp - unit.end, unit.start - activeEnd(picture)))
                return distance <= 12
            }
            guard !candidates.isEmpty else { continue }
            let overlapping = candidates.filter {
                pictures[$0].timestamp <= unit.end && activeEnd(pictures[$0]) >= unit.start
            }
            let cellCandidates = candidates.filter {
                let lower = $0 == 0 ? 0 : boundaries[$0 - 1]
                let upper = $0 == pictures.count - 1 ? Double.infinity : boundaries[$0]
                return unit.wordIndex == nil
                    ? unit.end >= lower && unit.start <= upper
                    : unit.midpoint >= lower && unit.midpoint <= upper
            }
            let owners: [Int]
            let reason: String
            if overlapping.count > 1 {
                owners = overlapping; reason = "同一语音单位覆盖多张截图，无法唯一归属"
            } else if unit.wordIndex == nil && cellCandidates.count > 1 {
                owners = cellCandidates; reason = "仅有句级时间，跨截图的整句不能拆分"
            } else if let index = overlapping.first {
                owners = [index]
                reason = pictures[index].kind == .pen ? "真实语音与画笔持续区间重叠" : "真实语音覆盖截图时刻"
            } else {
                owners = cellCandidates; reason = "按相邻截图边界关联截图前后讲解"
            }
            guard owners.count == 1, let owner = owners.first else {
                for index in owners { ambiguous.insert(index); evidence[index].insert(reason) }
                continue
            }
            let equalTime = pictures.indices.filter { pictures[$0].timestamp == pictures[owner].timestamp }
            guard equalTime.count == 1 else {
                for index in equalTime {
                    ambiguous.insert(index); evidence[index].insert("不同截图事件时间相同，保留独立卡片供人工判断")
                }
                continue
            }
            assigned[owner].append(unit); evidence[owner].insert(reason)
            if owner > 0 { evidence[owner].insert(boundaryReasons[owner - 1]) }
            if owner < boundaryReasons.count { evidence[owner].insert(boundaryReasons[owner]) }
        }
        return pictures.indices.map { index in
            let picture = pictures[index], selected = assigned[index]
            var text = "", matches: [SpeechMatch] = []
            var previous: Unit?
            for unit in selected {
                if let previous = previous, previous.transcriptID != unit.transcriptID
                    || (previous.wordIndex != nil && unit.wordIndex != previous.wordIndex.map { $0 + 1 }) {
                    text += "\n"
                }
                text += unit.text
                if let last = matches.last, last.transcriptID == unit.transcriptID,
                   let word = unit.wordIndex, last.lastWordIndex == word - 1 {
                    matches[matches.count - 1].endSeconds = unit.end
                    matches[matches.count - 1].lastWordIndex = word
                } else {
                    matches.append(SpeechMatch(transcriptID: unit.transcriptID, startSeconds: unit.start,
                        endSeconds: unit.end, firstWordIndex: unit.wordIndex, lastWordIndex: unit.wordIndex,
                        precision: unit.precision, offsetSeconds: unit.start - picture.timestamp))
                }
                previous = unit
            }
            if selected.isEmpty {
                evidence[index].insert(transcripts.contains { !$0.isTimed }
                    ? "部分源转写没有真实时间戳，请在原始转写中校对" : "没有可唯一关联的讲解，截图已保留")
            }
            let association = ScreenshotAssociation(
                status: ambiguous.contains(index) ? .needsReview : (selected.isEmpty ? .unmatched : .matched),
                screenshotSeconds: picture.timestamp, annotationEndSeconds: picture.endTimestamp,
                matches: matches, reasons: evidence[index].sorted())
            var card = ReviewCard(id: picture.id,
                transcriptID: Set(matches.map(\.transcriptID)).count == 1 ? matches.first?.transcriptID : nil,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), frameIDs: [picture.id],
                startSeconds: selected.first?.start, endSeconds: selected.last?.end,
                sourceAnchorID: picture.id, association: association)
            card.generatedContent = ReviewCardContent(card)
            return card
        }
    }
}

public extension ProjectManifest {
    /// Adopt screenshot ownership without rewriting any stored legacy card.
    /// Old deletion provenance is ambiguous, so unrepresented old images remain
    /// suppressed when a legacy project already records a deletion.
    mutating func enableScreenshotCards() {
        guard screenshotCardVersion == nil else { return }
        screenshotCardVersion = 1
        if reviewEdits != nil {
            let represented = Set(reviewCards.flatMap(\.frameIDs))
            reviewEdits?.suppressedAnchorIDs = anchors.filter {
                $0.isRecordingScreenshot && !represented.contains($0.id)
            }.map(\.id)
        }
        for index in reviewCards.indices { reviewCards[index].userEdited = true }
        reconcileScreenshotCards()
    }

    @discardableResult mutating func registerRecordingAnchor(_ anchor: VisualAnchor) -> Bool {
        guard anchor.isRecordingScreenshot, !anchors.contains(where: { $0.id == anchor.id }) else { return false }
        anchors.append(anchor)
        if screenshotCardVersion == nil { enableScreenshotCards() }
        reconcileScreenshotCards()
        return true
    }

    /// Recompute only untouched generated text. Image choices, manual timing,
    /// edits and deletion tombstones survive retries and source ID changes.
    @discardableResult mutating func reconcileScreenshotCards() -> Bool {
        guard screenshotCardVersion != nil else { return false }
        let before = reviewCards
        let suggestions = ScreenshotCardMatcher.cards(anchors: anchors, transcripts: transcripts)
        let byAnchor = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.sourceAnchorID!, $0) })
        for index in reviewCards.indices {
            let original = reviewCards[index]
            guard let source = original.sourceAnchorID, original.isAutomaticallyManaged,
                  var replacement = byAnchor[source] else { continue }
            replacement.id = original.id
            reviewCards[index] = replacement
        }
        var represented = Set(reviewCards.compactMap(\.sourceAnchorID))
        represented.formUnion(reviewCards.filter { $0.sourceAnchorID == nil }.flatMap(\.frameIDs))
        let suppressed = Set(reviewEdits?.suppressedAnchorIDs ?? [])
        let ranks = Dictionary(uniqueKeysWithValues: suggestions.enumerated().map { ($0.element.sourceAnchorID!, $0.offset) })
        for suggestion in suggestions {
            let source = suggestion.sourceAnchorID!
            guard !represented.contains(source), !suppressed.contains(source) else { continue }
            let insertion = reviewCards.firstIndex { card in
                guard let id = card.sourceAnchorID, let rank = ranks[id] else { return false }
                return rank > ranks[source]!
            } ?? reviewCards.endIndex
            reviewCards.insert(suggestion, at: insertion); represented.insert(source)
        }
        return before != reviewCards
    }
}
