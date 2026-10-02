import XCTest
@testable import PointAndTellCore

final class CaptureFailureTests: XCTestCase {
    func testGenericAVErrorRetainsUnderlyingCodeAndStage() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -12780)
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: underlying
        ])
        let failure = CaptureFailure(stage: .movieStart, underlying: error)
        XCTAssertEqual(failure.errorDescription, "启动录屏文件写入失败")
        XCTAssertTrue(failure.diagnosticText.contains("AVFoundationErrorDomain (-11800)"))
        XCTAssertTrue(failure.diagnosticText.contains("NSOSStatusErrorDomain (-12780)"))
        XCTAssertTrue(failure.diagnosticText.contains("[movieStart]"))
    }

    func testCleanupPreservesOriginalStageAndFailureReason() {
        let error = NSError(domain: "CaptureTest", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Cannot start", NSLocalizedFailureReasonErrorKey: "No device"
        ])
        let first = CaptureFailure(stage: .microphoneInput, underlying: error)
        let cleanup = CaptureFailure(stage: .finalization, underlying: first)
        XCTAssertEqual(cleanup.stage, .microphoneInput)
        XCTAssertEqual(cleanup.diagnosticText, first.diagnosticText)
        XCTAssertTrue(cleanup.failureReason?.contains("No device") == true)
    }

    func testReportDoesNotDumpUnrelatedUserInfoAndBoundsDeepChains() {
        var error = NSError(domain: "CaptureTest", code: 0, userInfo: ["secret": "private-key", "path": "/private/recording.mov"])
        for index in 1...12 { error = NSError(domain: "CaptureTest", code: index, userInfo: [NSUnderlyingErrorKey: error]) }
        let failure = CaptureFailure(stage: .sessionStart, underlying: error)
        XCTAssertEqual(failure.details.count, 8)
        XCTAssertFalse(failure.diagnosticText.contains("private-key"))
        XCTAssertFalse(failure.diagnosticText.contains("/private/recording.mov"))
    }

    func testSynchronousStartFailureSurvivesQueuedCleanupError() {
        let latch = CaptureSessionErrorLatch()
        XCTAssertNil(latch.error)
        let runtime = NSError(domain: "AVFoundationErrorDomain", code: -11819)
        // Runtime notifications may arrive on an AVFoundation-owned thread while
        // the engine's serial queue is still blocked inside startRunning().
        DispatchQueue.global().sync { latch.record(runtime) }
        latch.record(NSError(domain: "Cleanup", code: 1))
        XCTAssertEqual(latch.error.map { ($0 as NSError).domain }, runtime.domain)
        XCTAssertEqual(latch.error.map { ($0 as NSError).code }, runtime.code)
        XCTAssertNil(CaptureSessionErrorLatch().error)
    }
}
