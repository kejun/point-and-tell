import Foundation
import XCTest
@testable import PointAndTellCore

final class ProjectTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRoundTripPreservesEditedCardsAndExactTimes() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "中文演示 🖊️")
        let anchor = VisualAnchor(timestamp: 2.75, imageRelativePath: "frames/one.png", kind: .pen,
                                  pointer: NormalizedPoint(x: 0.2, y: 0.8), endTimestamp: 4.25)
        let transcript = TranscriptSegment(text: "你好", startSeconds: 2.125, endSeconds: 4.875)
        project.anchors = [anchor]
        project.transcripts = [transcript]
        project.reviewCards = [ReviewCard(transcriptID: transcript.id, text: "User-edited 中文",
                                          frameIDs: [anchor.id], startSeconds: 2.125, endSeconds: 4.875)]
        project.recording = RecordingInfo(relativePath: "recording.mov", durationSeconds: 7.125,
                                          audioRelativePath: "audio/recording.wav", displayID: 1, fps: 12)
        project.captureState = .complete
        try store.save(project)
        let loaded = try store.load()
        XCTAssertEqual(loaded.title, project.title)
        XCTAssertEqual(loaded.recording, project.recording)
        XCTAssertEqual(loaded.anchors, project.anchors)
        XCTAssertEqual(loaded.reviewCards, project.reviewCards)
        XCTAssertEqual(loaded.transcripts, project.transcripts)
    }

    func testCrashRecoveryResetsOnlyInFlightWorkAndPersistsIt() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Recovery")
        project.captureState = .processing
        project.asrChunks = [
            ASRChunk(index: 0, relativePath: "audio/0.wav", startSeconds: 0, durationSeconds: 180, state: .complete,
                     sentences: [TranscriptSegment(text: "Done", startSeconds: 1, endSeconds: 3)]),
            ASRChunk(index: 1, relativePath: "audio/1.wav", startSeconds: 180, durationSeconds: 20, state: .transcribing),
            ASRChunk(index: 2, relativePath: "audio/2.wav", startSeconds: 200, durationSeconds: 4, state: .failed,
                     errorMessage: "Network unavailable")
        ]
        try store.save(project)
        // A stale temporary write is not treated as the manifest or erased.
        try Data("incomplete".utf8).write(to: root.appendingPathComponent(".project.json.tmp"))
        let recovered = try store.load()
        XCTAssertEqual(recovered.captureState, .interrupted)
        XCTAssertEqual(recovered.asrChunks.map(\.state), [.complete, .pending, .failed])
        XCTAssertEqual(recovered.asrChunks[0].sentences, project.asrChunks[0].sentences)
        XCTAssertEqual(try store.load(recoverInterruptedWork: false), recovered)
    }

    func testRecoveryCanBeDisabledForAnActiveOwner() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Live")
        project.captureState = .recording
        try store.save(project)
        XCTAssertEqual(try store.load(recoverInterruptedWork: false).captureState, .recording)
    }

    func testInvalidSaveDoesNotReplaceLastGoodManifest() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Good")
        project.anchors = [VisualAnchor(timestamp: -1, imageRelativePath: "frames/bad.png")]
        XCTAssertThrowsError(try store.save(project))
        XCTAssertEqual(try store.load().title, "Good")
        XCTAssertTrue(try store.load().anchors.isEmpty)
    }

    func testRelativePathsRejectTraversalAndSiblingPrefix() throws {
        let store = ProjectStore(folderURL: root)
        for path in ["../secret.png", "/tmp/secret.png", "frames/../../secret.png", "frames//a.png", "./a.png", "file:///tmp/a.png", "C:\\a.png", "frames/\na.png"] {
            XCTAssertThrowsError(try store.resolveRelativePath(path), path)
        }
        XCTAssertEqual(try store.resolveRelativePath("frames/中文.png").lastPathComponent, "中文.png")
        XCTAssertThrowsError(try store.resolveRelativePath("frames/missing.png", requireExisting: true))
    }

    func testSymlinkCannotEscapeProjectOrOverwriteExternalManifest() throws {
        let store = ProjectStore(folderURL: root.appendingPathComponent("project"))
        _ = try store.create(title: "Safe")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.folderURL.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.resolveRelativePath("escape/image.png"))
        XCTAssertThrowsError(try store.resolveRelativePath("escape/not-created/yet/image.png"))
        try FileManager.default.createSymbolicLink(at: store.folderURL.appendingPathComponent("dangling"),
                                                   withDestinationURL: outside.appendingPathComponent("not-created"))
        XCTAssertThrowsError(try store.resolveRelativePath("dangling/image.png"))
        try FileManager.default.createSymbolicLink(at: store.folderURL.appendingPathComponent("internal"),
                                                   withDestinationURL: store.folderURL.appendingPathComponent("frames"))
        XCTAssertThrowsError(try store.resolveRelativePath("internal/image.png"))
        try FileManager.default.removeItem(at: store.manifestURL)
        let secret = outside.appendingPathComponent("project.json")
        try Data("keep".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: store.manifestURL, withDestinationURL: secret)
        XCTAssertThrowsError(try store.save(ProjectManifest(title: "Do not write")))
        XCTAssertEqual(try String(contentsOf: secret), "keep")
    }

    func testErrorMessagesAreSanitizedEvenAfterDirectMutation() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Secrets")
        var chunk = ASRChunk(relativePath: "audio/chunk.wav", startSeconds: 0, durationSeconds: 1)
        chunk.errorMessage = "Bearer PRIVATE_TOKEN api_key=PRIVATE_KEY https://example.test/?token=SECRET /Users/person/private.wav sk-sensitivevalue {\"password\":\"QUOTED VALUE\"} C:\\private\\audio.wav"
        project.asrChunks = [chunk]
        try store.save(project)
        let contents = try String(contentsOf: store.manifestURL)
        for secret in ["PRIVATE_TOKEN", "PRIVATE_KEY", "example.test", "SECRET", "/Users/", "sk-sensitivevalue", "QUOTED VALUE", "private\\\\audio"] {
            XCTAssertFalse(contents.contains(secret), secret)
        }
    }

    func testCreateDoesNotOverwriteExistingProject() throws {
        let store = ProjectStore(folderURL: root)
        _ = try store.create(title: "Original")
        XCTAssertThrowsError(try store.create(title: "Replacement"))
        XCTAssertEqual(try store.load().title, "Original")
    }

    func testInvalidPenIntervalIsRejected() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Interval")
        project.anchors = [VisualAnchor(timestamp: 5, imageRelativePath: "frames/pen.png", kind: .pen, endTimestamp: 4)]
        XCTAssertThrowsError(try store.save(project))
        project.anchors[0].endTimestamp = .infinity
        XCTAssertThrowsError(try store.save(project))
    }

    func testStructuredASRDiagnosticsPreserveUUIDAndHexIDsAcrossSaveAndLoad() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Support details")
        let identifiers = ["21da954f-704d-4931-8fe5-444d8e6fe33f", "21da954f704d49318fe5444d8e6fe33f"]
        project.asrChunks = identifiers.enumerated().map { index, identifier in
            let error = ASRError.httpStatus(401, code: "InvalidApiKey", requestID: identifier)
            return ASRChunk(index: index, relativePath: "audio/\(index).wav", startSeconds: Double(index),
                            durationSeconds: 1, state: .failed, errorMessage: error.localizedDescription,
                            diagnostic: ASRDiagnostic(error: error))
        }
        try store.save(project)
        let loaded = try store.load()
        for (index, identifier) in identifiers.enumerated() {
            let diagnostic = try XCTUnwrap(loaded.asrChunks[index].diagnostic)
            XCTAssertEqual(diagnostic.stage, .http)
            XCTAssertEqual(diagnostic.httpStatus, 401)
            XCTAssertEqual(diagnostic.code, "InvalidApiKey")
            XCTAssertEqual(diagnostic.requestID, identifier)
            XCTAssertTrue(diagnostic.safeSummary.contains(identifier))
            XCTAssertTrue(diagnostic.safeSummary.contains("HTTP 401"))
            // The generic scrubber stays conservative; only structured metadata keeps IDs.
            XCTAssertFalse(loaded.asrChunks[index].errorMessage?.contains(identifier) ?? false)
        }
        XCTAssertEqual(try store.load(), loaded)
    }

    func testStructuredDiagnosticsRejectRawErrorsAndUnsafeFieldsBeforeSave() throws {
        XCTAssertNil(ASRDiagnostic(error: NSError(domain: "private", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "secret response"])))
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Safe diagnostics")
        let values = ["sk-private-credential", "private-speech-transcript", "PRIVATE_TOKEN",
                      "https://example.invalid/private", "data:audio/wav;base64,UklGRPRIVATE"]
        for value in values {
            let error = ASRError.provider(code: value, requestID: value)
            let diagnostic = try XCTUnwrap(ASRDiagnostic(error: error))
            XCTAssertNil(diagnostic.code)
            XCTAssertNil(diagnostic.requestID)
            XCTAssertFalse(diagnostic.safeSummary.contains(value))
            project.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0,
                                          durationSeconds: 1, state: .failed, diagnostic: diagnostic)]
            try store.save(project)
            XCTAssertFalse(try String(contentsOf: store.manifestURL).contains(value))
            XCTAssertNil(try store.load().asrChunks[0].diagnostic?.requestID)
        }
    }

    func testImportedMaliciousDiagnosticIsSanitizedAndRewrittenOnLoad() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Imported")
        project.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0,
                                      durationSeconds: 1, state: .failed)]
        try store.save(project)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.manifestURL)) as? [String: Any])
        var chunks = try XCTUnwrap(object["asrChunks"] as? [[String: Any]])
        chunks[0]["diagnostic"] = [
            "stage": "HTTP", "httpStatus": 900, "code": "PRIVATE_PROVIDER_ECHO",
            "requestID": "https://example.invalid/private?key=PRIVATE_CREDENTIAL",
            "message": "PRIVATE_RAW_MESSAGE"
        ]
        object["asrChunks"] = chunks
        try JSONSerialization.data(withJSONObject: object).write(to: store.manifestURL)
        let loaded = try store.load()
        let diagnostic = try XCTUnwrap(loaded.asrChunks[0].diagnostic)
        XCTAssertEqual(diagnostic.stage, .http)
        XCTAssertNil(diagnostic.httpStatus)
        XCTAssertNil(diagnostic.code)
        XCTAssertNil(diagnostic.requestID)
        let safeFile = try String(contentsOf: store.manifestURL)
        for value in ["PRIVATE_PROVIDER_ECHO", "PRIVATE_CREDENTIAL", "PRIVATE_RAW_MESSAGE", "example.invalid", "\"message\""] {
            XCTAssertFalse(safeFile.contains(value), value)
            XCTAssertFalse(diagnostic.safeSummary.contains(value), value)
        }
        XCTAssertEqual(try store.load(), loaded)
    }

    func testDiagnosticRejectsInconsistentStageMetadata() throws {
        let data = Data(#"{"stage":"Request validation","httpStatus":401,"code":"InvalidApiKey","requestID":"21da954f-704d-4931-8fe5-444d8e6fe33f"}"#.utf8)
        let diagnostic = try JSONDecoder().decode(ASRDiagnostic.self, from: data)
        XCTAssertEqual(diagnostic.stage, .requestValidation)
        XCTAssertNil(diagnostic.httpStatus)
        XCTAssertNil(diagnostic.code)
        XCTAssertNil(diagnostic.requestID)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(diagnostic), encoding: .utf8))
        XCTAssertFalse(encoded.contains("InvalidApiKey"))
        XCTAssertFalse(encoded.contains("21da954f"))
    }

    func testOldManifestWithoutDiagnosticStillLoads() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Old project")
        project.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0,
                                      durationSeconds: 1, state: .failed, errorMessage: "Network unavailable")]
        try store.save(project)
        let contents = try String(contentsOf: store.manifestURL)
        XCTAssertFalse(contents.contains("\"diagnostic\""))
        XCTAssertEqual(try store.load().asrChunks[0].errorMessage, "Network unavailable")
        XCTAssertNil(try store.load().asrChunks[0].diagnostic)
    }

    func testRecoveryClearsInFlightDiagnosticAndKeepsFailedDiagnostic() throws {
        let store = ProjectStore(folderURL: root)
        var project = try store.create(title: "Recovery diagnostics")
        let diagnostic = ASRDiagnostic(error: ASRError.httpStatus(500, code: "InternalError",
                                      requestID: "21da954f-704d-4931-8fe5-444d8e6fe33f"))
        project.asrChunks = [
            ASRChunk(index: 0, relativePath: "audio/0.wav", startSeconds: 0, durationSeconds: 1,
                     state: .transcribing, diagnostic: diagnostic),
            ASRChunk(index: 1, relativePath: "audio/1.wav", startSeconds: 1, durationSeconds: 1,
                     state: .failed, diagnostic: diagnostic)
        ]
        try store.save(project)
        let loaded = try store.load()
        XCTAssertEqual(loaded.asrChunks[0].state, .pending)
        XCTAssertNil(loaded.asrChunks[0].diagnostic)
        XCTAssertEqual(loaded.asrChunks[1].diagnostic, diagnostic)
    }

    func testHTMLAndBundleExportsExcludeStructuredASRDiagnostics() throws {
        let source = ProjectStore(folderURL: root.appendingPathComponent("source"))
        var project = try source.create(title: "Export")
        let identifier = "21da954f-704d-4931-8fe5-444d8e6fe33f"
        let error = ASRError.httpStatus(401, code: "InvalidApiKey", requestID: identifier)
        project.asrChunks = [ASRChunk(relativePath: "audio/0.wav", startSeconds: 0,
                                      durationSeconds: 1, state: .failed, diagnostic: ASRDiagnostic(error: error))]
        project.reviewCards = [ReviewCard(text: "Edited text")]
        let html = root.appendingPathComponent("export.html")
        _ = try ProjectExporter.exportHTML(project: project, store: source, to: html)
        let bundle = root.appendingPathComponent("bundle")
        _ = try ProjectExporter.exportBundle(project: project, store: source, to: bundle)
        for file in [html, bundle.appendingPathComponent("index.html"),
                     bundle.appendingPathComponent("README.md"), bundle.appendingPathComponent("project.json")] {
            let contents = try String(contentsOf: file)
            for value in [identifier, "InvalidApiKey", "diagnostic", "httpStatus", "asrChunks"] {
                XCTAssertFalse(contents.contains(value), "\(file.lastPathComponent): \(value)")
            }
        }
    }

}
