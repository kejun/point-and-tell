import Foundation
import XCTest
@testable import PointAndTellCore

final class RecordingControlTests: XCTestCase {
    private func recording() -> RecordingControl {
        var c = RecordingControl(); XCTAssertTrue(c.begin()); c.configured(); XCTAssertTrue(c.started()); return c
    }
    private func request(_ kind: RecordingControl.Kind, _ c: inout RecordingControl) -> RecordingControl.Ticket {
        guard case .started(let ticket) = c.request(kind) else { fatalError("Expected transition") }; return ticket
    }
    func testFiftyPauseCyclesUseNativeClockAndRejectDuplicates() {
        var c = recording()
        for index in 0..<50 {
            let t = Double(index * 18)
            XCTAssertEqual(c.observeDuration(t + 10), t + 10)
            let pause = request(.pause, &c)
            XCTAssertTrue(c.phase.isBusy && c.phase.canStop && !c.phase.canCapture)
            XCTAssertEqual(c.request(.pause), .rejected)
            XCTAssertTrue(c.acknowledge(pause)); XCTAssertFalse(c.acknowledge(pause))
            XCTAssertEqual(c.request(.pause), .unchanged)
            XCTAssertEqual(c.observeDuration(t + 40), t + 10, "Never accept a drifting paused clock")
            let resume = request(.resume, &c)
            XCTAssertEqual(c.request(.resume), .rejected)
            XCTAssertEqual(c.observeDuration(t + 40), t + 10)
            XCTAssertTrue(c.acknowledge(resume)); XCTAssertFalse(c.acknowledge(resume))
            XCTAssertEqual(c.request(.resume), .unchanged)
            XCTAssertEqual(c.observeDuration(t + 12), t + 12, "No second subtraction of 30 seconds")
            XCTAssertEqual(c.observeDuration(t + 11), t + 12)
            XCTAssertEqual(c.observeDuration(t + 18), t + 18)
            XCTAssertFalse(c.started(), "Resume is not a new start")
        }
        XCTAssertEqual(c.duration, 900)
    }
    func testStopSupersedesPauseResumeAndOldRecordingCallbacks() {
        for kind in [RecordingControl.Kind.pause, .resume] {
            var c = recording()
            if kind == .resume { let pause = request(.pause, &c); XCTAssertTrue(c.acknowledge(pause)) }
            let ticket = request(kind, &c)
            XCTAssertTrue(c.stop()); XCTAssertFalse(c.stop()); XCTAssertNil(c.pending)
            XCTAssertFalse(c.acknowledge(ticket)); XCTAssertTrue(c.phase.isBusy)
            c.finish(); XCTAssertFalse(c.phase.isBusy)
            XCTAssertTrue(c.begin()); c.configured(); XCTAssertTrue(c.started())
            let next = request(.pause, &c)
            XCTAssertFalse(c.acknowledge(ticket)); XCTAssertEqual(c.pending, next)
        }
    }
    func testPausedStopAndUnacknowledgedTimeoutNeverNeedResume() {
        var c = recording(); let pause = request(.pause, &c)
        XCTAssertTrue(c.acknowledge(pause)); XCTAssertTrue(c.phase.canStop)
        XCTAssertTrue(c.stop()); c.finish()
        XCTAssertTrue(c.begin()); c.configured(); XCTAssertTrue(c.started())
        let lostCallback = request(.pause, &c)
        // The driver's watchdog takes exactly the same stop path as a user stop.
        XCTAssertTrue(c.stop()); c.finish(); XCTAssertFalse(c.acknowledge(lostCallback))
    }
    func testScreenshotEpochRejectsQueuedCaptureAfterFastPauseResumeAndNewProject() {
        var c = recording(); let id = c.operationID, epoch = c.screenshotEpoch
        XCTAssertTrue(c.allowsScreenshot(operationID: id, epoch: epoch))
        let pause = request(.pause, &c)
        XCTAssertFalse(c.allowsScreenshot(operationID: id, epoch: epoch))
        XCTAssertTrue(c.acknowledge(pause)); let resume = request(.resume, &c); XCTAssertTrue(c.acknowledge(resume))
        XCTAssertFalse(c.allowsScreenshot(operationID: id, epoch: epoch))
        XCTAssertTrue(c.allowsScreenshot(operationID: id, epoch: c.screenshotEpoch))
        c.stop(); c.finish(); c.begin(); c.configured(); c.started()
        XCTAssertFalse(c.allowsScreenshot(operationID: id, epoch: c.screenshotEpoch))
    }
    func testStartupRejectsPauseAndInvalidDurationNeverPoisonsClock() {
        var c = RecordingControl(); XCTAssertEqual(c.request(.pause), .rejected)
        c.begin(); XCTAssertEqual(c.request(.pause), .rejected)
        c.configured(); XCTAssertEqual(c.request(.pause), .rejected); c.started()
        XCTAssertEqual(c.observeDuration(5), 5)
        for invalid in [Double.nan, .infinity, -1] { XCTAssertEqual(c.observeDuration(invalid), 5) }
    }
    func testPausedCrashRecoveryAndUpdateProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(folderURL: root); var project = try store.create(title: "Paused")
        project.captureState = .paused; project.recording = RecordingInfo(relativePath: "recording.mov", durationSeconds: 10)
        try store.save(project); let loaded = try store.load()
        XCTAssertEqual(loaded.captureState, .interrupted); XCTAssertEqual(loaded.recording?.durationSeconds, 10)
        var c = recording(); let pause = request(.pause, &c); c.acknowledge(pause)
        XCTAssertTrue(c.phase.isBusy)
        var gate = AutomaticTranscriptionGate(); gate.arm(projectID: project.id)
        // No pause/resume path touches this gate; only final media validation consumes it.
        let resume = request(.resume, &c); c.acknowledge(resume); c.stop(); c.finish()
        XCTAssertTrue(gate.consume(projectID: project.id, usableAudio: true, needsAudioReview: false, ready: true))
        XCTAssertFalse(gate.consume(projectID: project.id, usableAudio: true, needsAudioReview: false, ready: true))
    }
}
