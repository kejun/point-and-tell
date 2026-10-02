import Foundation

public enum CaptureState: String, Codable, Sendable {
    case idle, recording, paused, finishing, processing, complete, interrupted, failed
}

public enum AnchorKind: String, Codable, Sendable {
    case frame, bookmark, pen

    var matchingPriority: Int {
        switch self {
        case .pen: return 2
        case .bookmark: return 1
        case .frame: return 0
        }
    }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct RecordingInfo: Codable, Equatable, Sendable {
    public var relativePath: String
    public var durationSeconds: Double
    public var audioRelativePath: String?
    public var displayID: UInt32?
    public var fps: Int?

    public init(relativePath: String, durationSeconds: Double, audioRelativePath: String? = nil,
                displayID: UInt32? = nil, fps: Int? = nil) {
        self.relativePath = relativePath
        self.durationSeconds = durationSeconds
        self.audioRelativePath = audioRelativePath
        self.displayID = displayID
        self.fps = fps
    }
}

public struct VisualAnchor: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Double
    public var imageRelativePath: String
    public var kind: AnchorKind
    public var pointer: NormalizedPoint?
    /// For pen anchors, the annotation remains relevant while this interval is active.
    /// timestamp remains the source screenshot's recording time.
    public var endTimestamp: Double?

    public init(id: UUID = UUID(), timestamp: Double, imageRelativePath: String,
                kind: AnchorKind = .frame, pointer: NormalizedPoint? = nil, endTimestamp: Double? = nil) {
        self.id = id; self.timestamp = timestamp; self.imageRelativePath = imageRelativePath
        self.kind = kind; self.pointer = pointer; self.endTimestamp = endTimestamp
    }
}

/// Times are seconds on the recording clock, never response-arrival times.
/// Missing or invalid timing is deliberately not replaced by an estimate.
public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var startSeconds: Double?
    public var endSeconds: Double?
    /// Optional for compatibility with projects saved before word timing was retained.
    public var words: [TranscriptWord]?

    public init(id: UUID = UUID(), text: String, startSeconds: Double? = nil, endSeconds: Double? = nil,
                words: [TranscriptWord]? = nil) {
        self.id = id; self.text = text; self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.words = words
    }

    public var isTimed: Bool {
        guard let start = startSeconds, let end = endSeconds else { return false }
        return start.isFinite && end.isFinite && start >= 0 && end >= start
    }

    public var hasCompleteWordTiming: Bool {
        guard isTimed, let words = words, !words.isEmpty,
              words.map(\.text).joined().filter({ !$0.isWhitespace }) == text.filter({ !$0.isWhitespace }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var previousStart = startSeconds!, previousEnd = startSeconds!
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.startSeconds.isFinite, word.endSeconds.isFinite,
                  word.startSeconds >= previousStart, word.endSeconds >= previousEnd,
                  word.endSeconds >= word.startSeconds, word.endSeconds <= endSeconds! else { return false }
            previousStart = word.startSeconds; previousEnd = word.endSeconds
        }
        return true
    }

    /// Use exactly once when converting a chunk-relative ASR result to recording time.
    public func offset(by seconds: Double) -> TranscriptSegment {
        guard seconds.isFinite, seconds >= 0 else {
            return TranscriptSegment(id: id, text: text)
        }
        return TranscriptSegment(id: id, text: text,
                                 startSeconds: startSeconds.map { $0 + seconds },
                                 endSeconds: endSeconds.map { $0 + seconds },
                                 words: words?.map { TranscriptWord(text: $0.text,
                                     startSeconds: $0.startSeconds + seconds, endSeconds: $0.endSeconds + seconds) })
    }
}

public struct ReviewCard: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var transcriptID: UUID?
    public var text: String
    /// Ordered, editable selections. Export respects these rather than rematching.
    public var frameIDs: [UUID]
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(id: UUID = UUID(), transcriptID: UUID? = nil, text: String,
                frameIDs: [UUID] = [], startSeconds: Double? = nil, endSeconds: Double? = nil) {
        self.id = id; self.transcriptID = transcriptID; self.text = text
        self.frameIDs = frameIDs; self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }

    public var isTimed: Bool {
        TranscriptSegment(text: text, startSeconds: startSeconds, endSeconds: endSeconds).isTimed
    }
}

public enum ASRChunkState: String, Codable, Sendable {
    case pending, transcribing, complete, failed
}

public struct ASRChunk: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var index: Int
    public var relativePath: String
    public var startSeconds: Double
    public var durationSeconds: Double
    public var state: ASRChunkState
    public var sentences: [TranscriptSegment]
    public var errorMessage: String?
    public var diagnostic: ASRDiagnostic?

    public var needsTimestampRetry: Bool {
        state == .complete && (sentences.isEmpty || sentences.contains { !$0.hasCompleteWordTiming })
    }

    public init(id: UUID = UUID(), index: Int = 0, relativePath: String, startSeconds: Double,
                durationSeconds: Double, state: ASRChunkState = .pending,
                sentences: [TranscriptSegment] = [], errorMessage: String? = nil,
                diagnostic: ASRDiagnostic? = nil) {
        self.id = id; self.index = index; self.relativePath = relativePath
        self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
        self.state = state; self.sentences = sentences
        self.errorMessage = Self.sanitizedError(errorMessage)
        self.diagnostic = diagnostic?.sanitized
    }

    /// Persist a short diagnostic, never raw response bodies, keys, URLs or local paths.
    public static func sanitizedError(_ message: String?) -> String? {
        guard let message = message, !message.isEmpty else { return nil }
        var safe = message
        let patterns = [
            "(?i)bearer\\s+[^\\s,;]+",
            "(?i)[\"']?(?:api[_-]?key|authorization|token|secret|password)[\"']?\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s,;}]+)",
            "(?i)sk-[a-z0-9_-]+",
            "(?i)https?://[^\\s<>]+",
            "(?i)[a-z]:\\\\[^\\s,;]+",
            "[A-Za-z0-9_+-]{32,}(?:\\.[A-Za-z0-9_+-]+)*",
            "(?:file://)?/(?:[^\\s/]+/)*[^\\s,;]+"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                safe = regex.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe),
                                                      withTemplate: "[redacted]")
            }
        }
        safe = safe.components(separatedBy: .controlCharacters).joined(separator: " ")
        return String(safe.prefix(500))
    }
}

/// Present after a user deletes a card. An explicitly empty review is different
/// from a legacy project that has not materialized transcript cards yet.
public struct ReviewEdits: Codable, Equatable, Sendable {
    public var suppressedTranscriptIDs: [UUID]
    public init(suppressedTranscriptIDs: [UUID] = []) {
        self.suppressedTranscriptIDs = suppressedTranscriptIDs
    }
}

public struct ProjectManifest: Codable, Equatable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var recording: RecordingInfo?
    public var captureState: CaptureState
    public var anchors: [VisualAnchor]
    public var transcripts: [TranscriptSegment]
    public var reviewCards: [ReviewCard]
    public var asrChunks: [ASRChunk]
    public var reviewEdits: ReviewEdits?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), recording: RecordingInfo? = nil,
                captureState: CaptureState = .idle, anchors: [VisualAnchor] = [],
                transcripts: [TranscriptSegment] = [], reviewCards: [ReviewCard] = [], asrChunks: [ASRChunk] = [],
                reviewEdits: ReviewEdits? = nil) {
        self.schemaVersion = 1; self.id = id; self.title = title; self.createdAt = createdAt
        self.recording = recording; self.captureState = captureState; self.anchors = anchors
        self.transcripts = transcripts; self.reviewCards = reviewCards; self.asrChunks = asrChunks
        self.reviewEdits = reviewEdits
    }
}

public enum ProjectError: Error, LocalizedError, Equatable {
    case invalidRelativePath, pathEscapesProject, symbolicLinkNotAllowed, missingFile, invalidManifest(String), projectAlreadyExists
    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath: return "A project file has an invalid relative path."
        case .pathEscapesProject: return "A project file points outside the project folder."
        case .symbolicLinkNotAllowed: return "Symbolic links are not allowed in project file paths."
        case .missingFile: return "A project file is missing."
        case .invalidManifest(let reason): return "The project is invalid: \(reason)"
        case .projectAlreadyExists: return "A project already exists in this folder."
        }
    }
}

/// One manifest plus local media. Call from one serial owner to avoid lost updates.
public final class ProjectStore {
    public let folderURL: URL
    public var manifestURL: URL { folderURL.appendingPathComponent("project.json") }
    private let fileManager: FileManager

    public init(folderURL: URL, fileManager: FileManager = .default) {
        self.folderURL = folderURL.standardizedFileURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func create(title: String) throws -> ProjectManifest {
        guard !fileManager.fileExists(atPath: manifestURL.path) else { throw ProjectError.projectAlreadyExists }
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for directory in ["frames", "audio"] {
            try fileManager.createDirectory(at: folderURL.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let project = ProjectManifest(title: title)
        try save(project)
        return project
    }

    public func save(_ project: ProjectManifest) throws {
        try validate(project)
        var sanitized = project
        sanitized.asrChunks = project.asrChunks.map { chunk in
            var copy = chunk
            copy.errorMessage = ASRChunk.sanitizedError(copy.errorMessage)
            copy.diagnostic = copy.diagnostic?.sanitized
            return copy
        }
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Atomic replacement keeps the previous manifest readable until the new one is complete.
        let safeManifestURL = try resolveRelativePath("project.json")
        try encoder.encode(sanitized).write(to: safeManifestURL, options: .atomic)
    }

    public func load(recoverInterruptedWork: Bool = true) throws -> ProjectManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let safeManifestURL = try resolveRelativePath("project.json", requireExisting: true)
        var project = try decoder.decode(ProjectManifest.self, from: Data(contentsOf: safeManifestURL))
        try validate(project)
        let original = project
        for index in project.asrChunks.indices {
            project.asrChunks[index].errorMessage = ASRChunk.sanitizedError(project.asrChunks[index].errorMessage)
            project.asrChunks[index].diagnostic = project.asrChunks[index].diagnostic?.sanitized
        }
        if recoverInterruptedWork {
            if [.recording, .paused, .finishing, .processing].contains(project.captureState) {
                project.captureState = .interrupted
            }
            for index in project.asrChunks.indices where project.asrChunks[index].state == .transcribing {
                project.asrChunks[index].state = .pending
                project.asrChunks[index].errorMessage = nil
                project.asrChunks[index].diagnostic = nil
            }
        }
        if project != original { try save(project) }
        return project
    }

    /// Reject traversal, absolute paths, URL strings, and symbolic links within
    /// project-relative paths. Checking EVERY component also protects writes to
    /// missing leaves beneath a symlink, which resolvingSymlinksInPath alone
    /// does not reliably resolve on macOS. The project root itself may be an alias.
    public func resolveRelativePath(_ path: String, requireExisting: Bool = false) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProjectError.invalidRelativePath
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectError.invalidRelativePath
        }
        let root = folderURL.resolvingSymlinksInPath().standardizedFileURL
        var target = root
        for part in parts {
            target.appendPathComponent(String(part))
            // destinationOfSymbolicLink also detects dangling symbolic links.
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                throw ProjectError.symbolicLinkNotAllowed
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: target.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw ProjectError.symbolicLinkNotAllowed
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                // A missing path is valid for an imminent atomic write. Existing
                // ancestors have already been checked one component at a time.
            }
        }
        target = target.standardizedFileURL
        let rootParts = root.pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count > rootParts.count,
              Array(targetParts.prefix(rootParts.count)) == rootParts else {
            throw ProjectError.pathEscapesProject
        }
        if requireExisting && !fileManager.fileExists(atPath: target.path) { throw ProjectError.missingFile }
        return target
    }

    private func validate(_ project: ProjectManifest) throws {
        guard project.schemaVersion == 1 else { throw ProjectError.invalidManifest("unsupported format version") }
        func time(_ value: Double) throws {
            guard value.isFinite && value >= 0 else { throw ProjectError.invalidManifest("invalid timestamp") }
        }
        func timing(_ start: Double?, _ end: Double?) throws {
            if let start = start { try time(start) }
            if let end = end { try time(end) }
            if let start = start, let end = end, end < start {
                throw ProjectError.invalidManifest("timestamps are reversed")
            }
        }
        func unique(_ ids: [UUID]) throws {
            if Set(ids).count != ids.count { throw ProjectError.invalidManifest("duplicate identifiers") }
        }
        try unique(project.anchors.map(\.id)); try unique(project.transcripts.map(\.id))
        try unique(project.reviewCards.map(\.id)); try unique(project.asrChunks.map(\.id))
        try unique(project.reviewEdits?.suppressedTranscriptIDs ?? [])
        if Set(project.asrChunks.map(\.index)).count != project.asrChunks.count {
            throw ProjectError.invalidManifest("duplicate chunk indices")
        }
        if let recording = project.recording {
            _ = try resolveRelativePath(recording.relativePath)
            if let audio = recording.audioRelativePath { _ = try resolveRelativePath(audio) }
            try time(recording.durationSeconds)
            if let fps = recording.fps, fps <= 0 { throw ProjectError.invalidManifest("invalid frame rate") }
        }
        for anchor in project.anchors {
            _ = try resolveRelativePath(anchor.imageRelativePath)
            try time(anchor.timestamp)
            if let end = anchor.endTimestamp {
                try time(end)
                if end < anchor.timestamp { throw ProjectError.invalidManifest("anchor interval is reversed") }
            }
            if let point = anchor.pointer,
               !point.x.isFinite || !point.y.isFinite || !(0...1).contains(point.x) || !(0...1).contains(point.y) {
                throw ProjectError.invalidManifest("pointer must be normalized")
            }
        }
        for segment in project.transcripts {
            try timing(segment.startSeconds, segment.endSeconds)
            for word in segment.words ?? [] { try timing(word.startSeconds, word.endSeconds) }
        }
        for card in project.reviewCards { try timing(card.startSeconds, card.endSeconds); try unique(card.frameIDs) }
        for chunk in project.asrChunks {
            _ = try resolveRelativePath(chunk.relativePath)
            try time(chunk.startSeconds); try time(chunk.durationSeconds)
            if chunk.index < 0 { throw ProjectError.invalidManifest("invalid chunk index") }
            try unique(chunk.sentences.map(\.id))
            for segment in chunk.sentences {
                try timing(segment.startSeconds, segment.endSeconds)
                for word in segment.words ?? [] { try timing(word.startSeconds, word.endSeconds) }
            }
        }
    }
}
