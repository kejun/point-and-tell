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
    public var captureStartSeconds: Double?
    public var captureEndSeconds: Double?
    public var annotationStartSeconds: Double?
    public var annotationEndSeconds: Double?
    public var matches: [SpeechMatch]
    public var reasons: [String]
    public var includesUntimedText: Bool? = nil

    public var precision: String {
        var values = Set(matches.map(\.precision))
        if includesUntimedText == true { values.insert("untimed") }
        if values.count > 1 { return "mixed" }
        return values.first ?? "untimed"
    }

    public var summary: String {
        switch status {
        case .matched: return "已按卡片分段 · 可直接编辑"
        case .needsReview: return "讲解可手动整理"
        case .unmatched: return "可补充讲解"
        }
    }
}

public extension ReviewCard {
    var isAutomaticallyManaged: Bool {
        sourceAnchorID != nil && userEdited != true && generatedContent == ReviewCardContent(self)
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
