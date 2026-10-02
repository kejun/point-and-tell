import Foundation

public struct ExportResult: Equatable {
    public let outputURL: URL
    public let warnings: [String]
    public init(outputURL: URL, warnings: [String] = []) {
        self.outputURL = outputURL; self.warnings = warnings
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case destinationExists, destinationInsideProject, invalidPNG, imageTooLarge, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .destinationExists: return "Choose a new folder for the export so existing files are not overwritten."
        case .destinationInsideProject: return "Choose an export location outside the project folder."
        case .invalidPNG: return "A selected image is not a PNG file."
        case .imageTooLarge: return "A selected image is too large to safely export."
        case .invalidDestination: return "The export destination must be a local file location."
        }
    }
}

/// Exports only selected screenshots and edited cards. Raw recording, audio, ASR
/// diagnostics, original paths, and credentials never enter the shareable output.
public enum ProjectExporter {
    private struct ExportImage: Codable {
        let id: UUID
        let relativePath: String
        let timestampSeconds: Double
        let kind: AnchorKind
    }
    private struct ExportCard: Codable {
        let id: UUID
        let text: String
        let startSeconds: Double?
        let endSeconds: Double?
        let timingStatus: String
        let images: [ExportImage]
        let missingImageCount: Int
    }
    private struct ExportDocument: Codable {
        let schemaVersion: Int
        let title: String
        let createdAt: Date
        let cards: [ExportCard]
    }
    private struct Prepared {
        let document: ExportDocument
        let imageData: [UUID: Data]
        let warnings: [String]
    }

    @discardableResult
    public static func exportHTML(project: ProjectManifest, store: ProjectStore, to destination: URL) throws -> ExportResult {
        try validateDestination(destination, store: store)
        let prepared = try prepare(project: project, store: store)
        let html = renderHTML(prepared)
        try Data(html.utf8).write(to: destination, options: .atomic)
        return ExportResult(outputURL: destination, warnings: prepared.warnings)
    }

    /// Writes to a sibling staging directory and renames only a fully built bundle.
    /// Existing destinations are rejected, rather than merged with stale content.
    @discardableResult
    public static func exportBundle(project: ProjectManifest, store: ProjectStore, to destination: URL) throws -> ExportResult {
        try validateDestination(destination, store: store)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw ExportError.destinationExists }
        let prepared = try prepare(project: project, store: store)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".point-and-tell-export-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let imagesURL = staging.appendingPathComponent("images", isDirectory: true)
        try manager.createDirectory(at: imagesURL, withIntermediateDirectories: false)
        for (id, bytes) in prepared.imageData {
            try bytes.write(to: imagesURL.appendingPathComponent("\(id.uuidString.lowercased()).png"), options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(prepared.document).write(to: staging.appendingPathComponent("project.json"), options: .atomic)
        try Data(renderMarkdown(prepared.document).utf8).write(to: staging.appendingPathComponent("README.md"), options: .atomic)
        try Data(renderHTML(prepared).utf8).write(to: staging.appendingPathComponent("index.html"), options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        return ExportResult(outputURL: destination, warnings: prepared.warnings)
    }

    private static func validateDestination(_ destination: URL, store: ProjectStore) throws {
        guard destination.isFileURL else { throw ExportError.invalidDestination }
        let root = store.folderURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard Array(target.prefix(root.count)) != root else { throw ExportError.destinationInsideProject }
    }

    private static func prepare(project: ProjectManifest, store: ProjectStore) throws -> Prepared {
        let cards = project.reviewCards.isEmpty
            ? FrameMatcher.suggestCards(for: project.transcripts, anchors: project.anchors) : project.reviewCards
        // Avoid Dictionary(uniqueKeysWithValues:) trapping on a malformed, unsaved project.
        var anchors: [UUID: VisualAnchor] = [:]
        for anchor in project.anchors { anchors[anchor.id] = anchor }
        var imageData: [UUID: Data] = [:]
        var warnings: [String] = []
        var exportedCards: [ExportCard] = []
        for (index, card) in cards.enumerated() {
            var images: [ExportImage] = []
            var missing = 0
            var seen = Set<UUID>()
            for frameID in card.frameIDs where seen.insert(frameID).inserted {
                guard let anchor = anchors[frameID] else {
                    missing += 1
                    warnings.append("Card \(index + 1): a selected image is no longer available.")
                    continue
                }
                let imageURL: URL
                do {
                    imageURL = try store.resolveRelativePath(anchor.imageRelativePath, requireExisting: true)
                } catch ProjectError.missingFile {
                    missing += 1
                    warnings.append("Card \(index + 1): a selected image file is missing.")
                    continue
                }
                if imageData[frameID] == nil {
                    let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true else { throw ExportError.invalidPNG }
                    guard (values.fileSize ?? 0) <= 64 * 1_024 * 1_024 else { throw ExportError.imageTooLarge }
                    let bytes = try Data(contentsOf: imageURL)
                    guard bytes.count >= 24,
                          Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
                          Array(bytes[12..<16]) == [73, 72, 68, 82] else { throw ExportError.invalidPNG }
                    imageData[frameID] = bytes
                }
                images.append(ExportImage(id: frameID,
                                          relativePath: "images/\(frameID.uuidString.lowercased()).png",
                                          timestampSeconds: anchor.timestamp, kind: anchor.kind))
            }
            exportedCards.append(ExportCard(id: card.id, text: card.text,
                                            startSeconds: card.isTimed ? card.startSeconds : nil,
                                            endSeconds: card.isTimed ? card.endSeconds : nil,
                                            timingStatus: card.isTimed ? "timed" : "untimed",
                                            images: images, missingImageCount: missing))
        }
        return Prepared(document: ExportDocument(schemaVersion: 1, title: project.title,
                                                 createdAt: project.createdAt, cards: exportedCards),
                        imageData: imageData, warnings: warnings)
    }

    private static func renderHTML(_ prepared: Prepared) -> String {
        let title = escapeHTML(prepared.document.title)
        let cards = prepared.document.cards.enumerated().map { index, card in
            let figures = card.images.compactMap { image -> String? in
                guard let bytes = prepared.imageData[image.id] else { return nil }
                return "<figure><img src=\"data:image/png;base64,\(bytes.base64EncodedString())\" alt=\"Screenshot for card \(index + 1)\"><figcaption>\(escapeHTML(timeLabel(image.timestampSeconds))) · \(image.kind.rawValue)</figcaption></figure>"
            }.joined(separator: "\n")
            let missing = card.missingImageCount > 0 ? "<p class=\"notice\">Image unavailable (\(card.missingImageCount))</p>" : ""
            let timing = timingLabel(card)
            return "<section class=\"card\"><h2>\(index + 1)</h2><p class=\"time\">\(escapeHTML(timing))</p><p class=\"transcript\">\(escapeHTML(card.text))</p>\(figures)\(missing)</section>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><title>\(title)</title>
        <style>body{margin:0;background:#f4f4f2;color:#202624;font:17px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:980px;margin:auto;padding:40px 24px}h1{line-height:1.15;overflow-wrap:anywhere}h2{font-size:15px;color:#596b62}.card{background:white;border:1px solid #dce2de;border-radius:16px;padding:24px;margin:22px 0;break-inside:avoid}.time,figcaption{font-size:13px;color:#66736c}.transcript{white-space:pre-wrap;overflow-wrap:anywhere}figure{margin:18px 0 0}img{display:block;max-width:100%;height:auto;border:1px solid #e3e7e4;border-radius:8px}.notice{color:#8c5029}footer{font-size:13px;color:#66736c}@media print{body{background:white}main{padding:0}.card{box-shadow:none}}</style></head>
        <body><main><h1>\(title)</h1>\(cards)<footer>Created with Point &amp; Tell · self-contained offline document</footer></main></body></html>
        """
    }

    private static func renderMarkdown(_ document: ExportDocument) -> String {
        var output = "# \(escapeMarkdown(document.title))\n\n"
        for (index, card) in document.cards.enumerated() {
            output += "## \(index + 1)\n\n\(timingLabel(card))\n\n\(escapeMarkdown(card.text))\n\n"
            for image in card.images {
                output += "![Screenshot for card \(index + 1)](\(image.relativePath))\n\n"
            }
            if card.missingImageCount > 0 { output += "Image unavailable (\(card.missingImageCount))\n\n" }
        }
        return output
    }

    private static func timingLabel(_ card: ExportCard) -> String {
        guard let start = card.startSeconds, let end = card.endSeconds else {
            return "Untimed transcript · choose images manually"
        }
        return "\(timeLabel(start)) – \(timeLabel(end))"
    }

    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Time unavailable" }
        return String(format: "%.2f s", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    public static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var result = escapeHTML(text)
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", "!", "|", "."] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}
