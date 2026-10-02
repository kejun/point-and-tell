import XCTest
@testable import PointAndTellCore

final class UpdateSafetyTests: XCTestCase {
    func testEveryBusyStateDefersOfferAndNeverSavesOrLocks() {
        let states = [
            UpdateActivity(recordingBusy: true), // includes starting and finishing
            UpdateActivity(processingBusy: true), // transcription and export
            UpdateActivity(screenshotPending: true),
            UpdateActivity(annotationOpen: true),
            UpdateActivity(modalOpen: true)
        ]
        for state in states {
            let gate = UpdateSessionGate()
            XCTAssertFalse(gate.begin(activity: state) { XCTFail("Saved during active work"); return true })
            XCTAssertFalse(gate.blocksWork)
        }
    }

    func testFailedSaveLeavesEditsAvailableAndCanBeRetried() {
        let gate = UpdateSessionGate()
        XCTAssertFalse(gate.begin(activity: UpdateActivity()) { false })
        XCTAssertFalse(gate.blocksWork)
        XCTAssertTrue(gate.begin(activity: UpdateActivity()) { true })
        XCTAssertTrue(gate.blocksWork)
        gate.finish()
        XCTAssertFalse(gate.blocksWork)
        XCTAssertTrue(gate.begin(activity: UpdateActivity()) { true })
    }

    func testDuplicatePresentationDoesNotSaveAgain() {
        let gate = UpdateSessionGate()
        XCTAssertTrue(gate.begin(activity: UpdateActivity()) { true })
        XCTAssertFalse(gate.begin(activity: UpdateActivity()) { XCTFail("Duplicate save"); return true })
    }

    func testTerminationRechecksWorkAndPersistenceAfterDownload() {
        XCTAssertFalse(UpdateSessionGate.mayTerminate(activity: UpdateActivity(recordingBusy: true)) {
            XCTFail("Must not save unfinished recording"); return true
        })
        XCTAssertFalse(UpdateSessionGate.mayTerminate(activity: UpdateActivity()) { false })
        XCTAssertTrue(UpdateSessionGate.mayTerminate(activity: UpdateActivity()) { true })
    }
}
