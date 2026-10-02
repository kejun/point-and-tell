import Foundation
import XCTest
@testable import PointAndTellCore

final class ExporterTests: XCTestCase {
    private var root: URL!
    private var store: ProjectStore!
    // A small real PNG, not a text file named .png.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProjectStore(folderURL: root.appendingPathComponent("source"))
        _ = try store.create(title: "Export")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func project(text: String = "An explanation", title: String = "Demo") throws -> ProjectManifest {
        let anchor = VisualAnchor(timestamp: 1.5, imageRelativePath: "frames/original-private-name.png", kind: .pen)
        try png.write(to: store.resolveRelativePath(anchor.imageRelativePath))
        return ProjectManifest(title: title,
                               recording: RecordingInfo(relativePath: "private-recording.mov", durationSeconds: 3),
                               anchors: [anchor],
                               reviewCards: [ReviewCard(text: text, frameIDs: [anchor.id], startSeconds: 1, endSeconds: 2)])
    }

    func testHTMLEscapesMaliciousTextAndEmbedsOnlyOfflineAssets() throws {
        let attack = "</title><script>alert('x')</script><img src=https://evil.example/x onerror=alert(1)> & 中文 🖊️"
        let source = try project(text: attack, title: attack)
        let destination = root.appendingPathComponent("export.html")
        let result = try ProjectExporter.exportHTML(project: source, store: store, to: destination)
        let html = try String(contentsOf: destination)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(html.contains("data:image/png;base64," + png.base64EncodedString()))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp; 中文 🖊️"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<img src=https:"))
        XCTAssertFalse(html.contains("src=\"https:"))
        XCTAssertFalse(html.contains("private-recording.mov"))
        XCTAssertFalse(html.contains("original-private-name.png"))
        XCTAssertFalse(html.contains(store.folderURL.path))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<link"))
    }

    func testBundleContainsPNGsMarkdownAndSanitizedSchema() throws {
        let source = try project(text: "Edited <script>bad()</script> [link](https://evil.example)")
        let destination = root.appendingPathComponent("bundle")
        _ = try ProjectExporter.exportBundle(project: source, store: store, to: destination)
        let markdown = try String(contentsOf: destination.appendingPathComponent("README.md"))
        let json = try String(contentsOf: destination.appendingPathComponent("project.json"))
        let imageName = source.anchors[0].id.uuidString.lowercased() + ".png"
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("images").appendingPathComponent(imageName)), png)
        XCTAssertTrue(markdown.contains("&lt;script&gt;"))
        XCTAssertTrue(markdown.contains("\\[link\\]\\("))
        XCTAssertTrue(markdown.contains("images/" + imageName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("index.html").path))
        XCTAssertFalse(json.contains("private-recording.mov"))
        XCTAssertFalse(json.contains("original-private-name"))
        XCTAssertFalse(json.contains("asrChunks"))
        XCTAssertFalse(json.contains(store.folderURL.path))
        XCTAssertTrue(json.contains("timed"))
    }

    func testExportRespectsManuallyChosenFramesAndEditedText() throws {
        var source = try project(text: "Edited words")
        let different = VisualAnchor(timestamp: 1.4, imageRelativePath: "frames/not-chosen.png", kind: .pen)
        // This file is deliberately invalid: unused anchors must not be exported/read.
        try Data("secret text".utf8).write(to: store.resolveRelativePath(different.imageRelativePath))
        source.anchors.append(different)
        source.transcripts = [TranscriptSegment(text: "Original words", startSeconds: 1, endSeconds: 2)]
        let destination = root.appendingPathComponent("chosen.html")
        _ = try ProjectExporter.exportHTML(project: source, store: store, to: destination)
        let html = try String(contentsOf: destination)
        XCTAssertTrue(html.contains("Edited words"))
        XCTAssertFalse(html.contains("Original words"))
        XCTAssertEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 1)
    }

    func testMissingImagesProduceHonestPlaceholderAndWarnings() throws {
        var source = try project()
        try FileManager.default.removeItem(at: store.resolveRelativePath(source.anchors[0].imageRelativePath))
        source.reviewCards[0].frameIDs.append(UUID())
        let destination = root.appendingPathComponent("missing.html")
        let result = try ProjectExporter.exportHTML(project: source, store: store, to: destination)
        XCTAssertEqual(result.warnings.count, 2)
        let html = try String(contentsOf: destination)
        XCTAssertTrue(html.contains("Image unavailable (2)"))
        XCTAssertFalse(html.contains("No screenshot selected"))
        XCTAssertFalse(html.contains("data:image/png"))
    }

    func testUnsafePathsAndSymlinksAbortWithoutOutput() throws {
        var source = try project()
        let destination = root.appendingPathComponent("unsafe.html")
        source.anchors[0].imageRelativePath = "../outside.png"
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let external = root.appendingPathComponent("outside.png")
        try png.write(to: external)
        try FileManager.default.createSymbolicLink(at: store.folderURL.appendingPathComponent("frames/link.png"), withDestinationURL: external)
        source.anchors[0].imageRelativePath = "frames/link.png"
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExistingBundleIsNeverMixedWithNewOrStaleFiles() throws {
        let source = try project()
        let destination = root.appendingPathComponent("bundle")
        _ = try ProjectExporter.exportBundle(project: source, store: store, to: destination)
        let stale = destination.appendingPathComponent("old-sensitive.txt")
        try Data("keep".utf8).write(to: stale)
        XCTAssertThrowsError(try ProjectExporter.exportBundle(project: source, store: store, to: destination)) {
            XCTAssertEqual($0 as? ExportError, .destinationExists)
        }
        XCTAssertEqual(try String(contentsOf: stale), "keep")
    }

    func testExportsCannotOverwriteSourceMedia() throws {
        let source = try project()
        let sourceImage = try store.resolveRelativePath(source.anchors[0].imageRelativePath)
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store, to: sourceImage))
        XCTAssertEqual(try Data(contentsOf: sourceImage), png)
        XCTAssertThrowsError(try ProjectExporter.exportBundle(project: source, store: store,
                                                             to: store.folderURL.appendingPathComponent("export")))
    }

    func testNonPNGFileIsRejected() throws {
        let source = try project()
        try Data("credential-like text, not a PNG".utf8).write(to: store.resolveRelativePath(source.anchors[0].imageRelativePath))
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store,
                                                           to: root.appendingPathComponent("not-png.html"))) {
            XCTAssertEqual($0 as? ExportError, .invalidPNG)
        }
    }

    func testTruncatedAndCorruptPNGsAreRejected() throws {
        let source = try project()
        let image = try store.resolveRelativePath(source.anchors[0].imageRelativePath)
        var corrupt = png
        corrupt[corrupt.count - 1] ^= 1
        for bytes in [Data(png.prefix(24)), Data(png.dropLast(12)), corrupt] {
            try bytes.write(to: image)
            XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store,
                                                               to: root.appendingPathComponent("corrupt.html"))) {
                XCTAssertEqual($0 as? ExportError, .invalidPNG)
            }
        }
    }

    func testUntimedTranscriptIsExplicitAndNeverAssignedArbitraryImage() throws {
        var source = try project()
        source.reviewCards = []
        source.transcripts = [TranscriptSegment(text: "No provider timing")]
        let destination = root.appendingPathComponent("untimed.html")
        let result = try ProjectExporter.exportHTML(project: source, store: store, to: destination)
        let html = try String(contentsOf: destination)
        XCTAssertTrue(html.contains("Untimed transcript"))
        XCTAssertTrue(html.contains("No screenshot selected"))
        XCTAssertEqual(result.warnings, ["Card 1: No screenshot selected."])
        XCTAssertFalse(html.contains("data:image/png"))
    }

    func testUnselectedScreenshotsAreExplicitForTimedAndManualCardsInBundle() throws {
        var source = try project()
        source.reviewCards = [ReviewCard(text: "Timed but no image", startSeconds: 1, endSeconds: 2),
                              ReviewCard(text: "Manual untimed card")]
        let destination = root.appendingPathComponent("unselected-bundle")
        let result = try ProjectExporter.exportBundle(project: source, store: store, to: destination)
        XCTAssertEqual(result.warnings, ["Card 1: No screenshot selected.", "Card 2: No screenshot selected."])
        let html = try String(contentsOf: destination.appendingPathComponent("index.html"))
        let markdown = try String(contentsOf: destination.appendingPathComponent("README.md"))
        for document in [html, markdown] {
            XCTAssertEqual(document.components(separatedBy: "No screenshot selected").count - 1, 2)
            XCTAssertFalse(document.contains("Image unavailable"))
        }
        XCTAssertFalse(html.contains("data:image/png"))
    }

    func testExportBudgetsRejectOversizeBeforeWritingAndCountRepeatedImages() throws {
        var source = try project()
        let destination = root.appendingPathComponent("limited.html")
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store, to: destination,
                                                            limits: ExportLimits(maximumImageBytes: 1))) {
            XCTAssertEqual($0 as? ExportError, .exportTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        source.reviewCards = (0..<10).map { _ in ReviewCard(text: "", frameIDs: [source.anchors[0].id]) }
        XCTAssertThrowsError(try ProjectExporter.exportHTML(project: source, store: store, to: destination,
                                                            limits: ExportLimits(maximumHTMLBytes: 6_000))) {
            XCTAssertEqual($0 as? ExportError, .exportTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
