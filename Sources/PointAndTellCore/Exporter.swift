import Foundation

public struct ExportResult: Equatable {
    public let outputURL: URL
    public let warnings: [String]
    public init(outputURL: URL, warnings: [String] = []) {
        self.outputURL = outputURL; self.warnings = warnings
    }
}

/// Conservative budgets keep self-contained HTML preparation bounded on 8 GB Macs.
/// Callers may choose smaller limits; source media is preserved if a limit is reached.
public struct ExportLimits {
    public var maximumImageBytes: Int
    public var maximumHTMLBytes: Int
    public init(maximumImageBytes: Int = 256 * 1_024 * 1_024, maximumHTMLBytes: Int = 512 * 1_024 * 1_024) {
        self.maximumImageBytes = maximumImageBytes; self.maximumHTMLBytes = maximumHTMLBytes
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case destinationExists, destinationInsideProject, invalidPNG, imageTooLarge, exportTooLarge, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .destinationExists: return "Choose a new folder for the export so existing files are not overwritten."
        case .destinationInsideProject: return "Choose an export location outside the project folder."
        case .invalidPNG: return "A selected image is not a PNG file."
        case .imageTooLarge: return "A selected image is too large to safely export."
        case .exportTooLarge: return "This export exceeds the memory-safe image budget. Use fewer or smaller screenshots and try again. The project has been preserved."
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
        let endTimestampSeconds: Double?
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
    public static func exportHTML(project: ProjectManifest, store: ProjectStore, to destination: URL,
                                  limits: ExportLimits = ExportLimits()) throws -> ExportResult {
        try validateDestination(destination, store: store)
        let prepared = try prepare(project: project, store: store, limits: limits)
        let html = renderHTML(prepared)
        try Data(html.utf8).write(to: destination, options: .atomic)
        return ExportResult(outputURL: destination, warnings: prepared.warnings)
    }

    /// Writes to a sibling staging directory and renames only a fully built bundle.
    /// Existing destinations are rejected, rather than merged with stale content.
    @discardableResult
    public static func exportBundle(project: ProjectManifest, store: ProjectStore, to destination: URL,
                                    limits: ExportLimits = ExportLimits()) throws -> ExportResult {
        try validateDestination(destination, store: store)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw ExportError.destinationExists }
        let prepared = try prepare(project: project, store: store, limits: limits)
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

    private static func prepare(project: ProjectManifest, store: ProjectStore, limits: ExportLimits) throws -> Prepared {
        let cards = project.reviewCards.isEmpty
            ? FrameMatcher.suggestCards(for: project.transcripts, anchors: project.anchors) : project.reviewCards
        // Avoid Dictionary(uniqueKeysWithValues:) trapping on a malformed, unsaved project.
        var anchors: [UUID: VisualAnchor] = [:]
        for anchor in project.anchors { anchors[anchor.id] = anchor }
        var imageData: [UUID: Data] = [:]
        var imageBytes = 0
        var estimatedHTMLBytes = 4_096
        func addHTMLBudget(_ count: Int) throws {
            guard count >= 0, estimatedHTMLBytes <= limits.maximumHTMLBytes,
                  count <= limits.maximumHTMLBytes - estimatedHTMLBytes else { throw ExportError.exportTooLarge }
            estimatedHTMLBytes += count
        }
        func textBudget(_ text: String) throws {
            let count = text.utf8.count
            guard count <= Int.max / 6 else { throw ExportError.exportTooLarge }
            try addHTMLBudget(count * 6) // HTML escaping expands a quote to at most six bytes.
        }
        try textBudget(project.title)
        try textBudget(project.title) // The title appears in both <title> and the visible heading.
        var warnings: [String] = []
        var exportedCards: [ExportCard] = []
        for (index, card) in cards.enumerated() {
            try textBudget(card.text)
            try addHTMLBudget(1_024)
            if card.frameIDs.isEmpty {
                warnings.append("Card \(index + 1): No screenshot selected.")
            }
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
                    guard let fileSize = values.fileSize, fileSize >= 0,
                          imageBytes <= limits.maximumImageBytes,
                          fileSize <= limits.maximumImageBytes - imageBytes else { throw ExportError.exportTooLarge }
                    let bytes = try Data(contentsOf: imageURL)
                    guard bytes.count <= 64 * 1_024 * 1_024 else { throw ExportError.imageTooLarge }
                    guard bytes.count <= limits.maximumImageBytes - imageBytes else { throw ExportError.exportTooLarge }
                    guard validPNG(bytes) else { throw ExportError.invalidPNG }
                    imageData[frameID] = bytes
                    imageBytes += bytes.count
                }
                // Count every image occurrence: a single image can be selected on many cards.
                if let bytes = imageData[frameID] { try addHTMLBudget(4 * ((bytes.count + 2) / 3) + 512) }
                images.append(ExportImage(id: frameID,
                                          relativePath: "images/\(frameID.uuidString.lowercased()).png",
                                          timestampSeconds: anchor.timestamp, endTimestampSeconds: anchor.endTimestamp,
                                          kind: anchor.kind))
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
            let unselected = card.images.isEmpty && card.missingImageCount == 0
                ? "<p class=\"notice\">No screenshot selected</p>" : ""
            let timing = timingLabel(card)
            return "<section class=\"card\"><h2>\(index + 1)</h2><p class=\"time\">\(escapeHTML(timing))</p><p class=\"transcript\">\(escapeHTML(card.text))</p>\(figures)\(missing)\(unselected)</section>"
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

    private static let pngCRCTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    /// Validate structure, dimensions and chunk checksums without platform image frameworks.
    /// This catches interrupted/truncated screenshot writes before making a broken document.
    private static func validPNG(_ data: Data) -> Bool {
        guard data.count >= 45, Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return false }
        func u32(_ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
        var offset = 8
        var hasHeader = false
        var hasImageData = false
        while offset <= data.count - 12 {
            let length = Int(u32(offset))
            guard length <= data.count - offset - 12 else { return false }
            let type = u32(offset + 4)
            if !hasHeader {
                guard type == 0x49484452, length == 13 else { return false } // IHDR
                let width = u32(offset + 8), height = u32(offset + 12)
                guard width > 0, height > 0, UInt64(width) * UInt64(height) <= 40_000_000 else { return false }
                hasHeader = true
            } else if type == 0x49484452 { return false }
            var crc: UInt32 = 0xffffffff
            for byte in data[(offset + 4)..<(offset + 8 + length)] {
                crc = pngCRCTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
            guard (crc ^ 0xffffffff) == u32(offset + 8 + length) else { return false }
            if type == 0x49444154, length > 0 { hasImageData = true } // IDAT
            offset += 12 + length
            if type == 0x49454e44 { return length == 0 && hasImageData && offset == data.count } // IEND
        }
        return false
    }

    private static func renderMarkdown(_ document: ExportDocument) -> String {
        var output = "# \(escapeMarkdown(document.title))\n\n"
        for (index, card) in document.cards.enumerated() {
            output += "## \(index + 1)\n\n\(timingLabel(card))\n\n\(escapeMarkdown(card.text))\n\n"
            for image in card.images {
                output += "![Screenshot for card \(index + 1)](\(image.relativePath))\n\n"
            }
            if card.missingImageCount > 0 { output += "Image unavailable (\(card.missingImageCount))\n\n" }
            if card.images.isEmpty && card.missingImageCount == 0 { output += "No screenshot selected\n\n" }
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
