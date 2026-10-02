import Foundation
import XCTest
@testable import PointAndTellCore

final class WorkflowReadinessTests: XCTestCase {
    private var ready: WorkflowReadiness {
        WorkflowReadiness(screenPermission: true, microphonePermission: true, hasDisplay: true,
                          hasMicrophone: true, hasAPIKey: true, automaticUploadConsent: true)
    }
    func testEveryPrerequisiteMustBeMetBeforeEnteringWorkspace() {
        XCTAssertTrue(ready.canEnterWorkspace)
        let conditions: [WritableKeyPath<WorkflowReadiness, Bool>] = [\.screenPermission, \.microphonePermission,
            \.hasDisplay, \.hasMicrophone, \.hasAPIKey, \.automaticUploadConsent]
        for condition in conditions {
            var state = ready; state[keyPath: condition] = false
            XCTAssertFalse(state.canEnterWorkspace)
        }
    }
    func testCredentialConfigurationRejectsBlankMultilineAndInvalidCharacters() {
        for key in ["", "  ", "test\nkey", "test key", "密钥", "key\u{0000}"] {
            XCTAssertFalse(WorkflowReadiness.validAPIKey(key))
        }
        XCTAssertTrue(WorkflowReadiness.validAPIKey("  offline-fixture-key\n"))
    }
    func testOnlyNewRecordingCanStartOneAutomaticAttempt() {
        let id = UUID()
        var gate = AutomaticTranscriptionGate()
        XCTAssertFalse(gate.consume(projectID: id, usableAudio: true, needsAudioReview: false, ready: true))
        gate.arm(projectID: id)
        XCTAssertTrue(gate.consume(projectID: id, usableAudio: true, needsAudioReview: false, ready: true))
        XCTAssertFalse(gate.consume(projectID: id, usableAudio: true, needsAudioReview: false, ready: true))
    }
    func testFailedQuietOrUnreadyRecordingDoesNotUploadOrAutomaticallyRetry() {
        for (audio, quiet, setup) in [(false, false, true), (true, true, true), (true, false, false)] {
            let id = UUID(); var gate = AutomaticTranscriptionGate(); gate.arm(projectID: id)
            XCTAssertFalse(gate.consume(projectID: id, usableAudio: audio, needsAudioReview: quiet, ready: setup))
            XCTAssertFalse(gate.consume(projectID: id, usableAudio: true, needsAudioReview: false, ready: true))
        }
    }
    func testCancellationAndStaleProjectCallbacksCannotUpload() {
        let id = UUID(); var gate = AutomaticTranscriptionGate(); gate.arm(projectID: id)
        XCTAssertFalse(gate.consume(projectID: UUID(), usableAudio: true, needsAudioReview: false, ready: true))
        gate.cancel()
        XCTAssertFalse(gate.consume(projectID: id, usableAudio: true, needsAudioReview: false, ready: true))
    }
}
