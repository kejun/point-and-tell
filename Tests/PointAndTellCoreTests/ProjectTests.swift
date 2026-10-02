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
}
