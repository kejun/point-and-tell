import XCTest
@testable import PointAndTellCore

final class CaptureDiagnosticsTests: XCTestCase {
    func testLoudestChannelLevelsWithoutLogarithmicAveraging() {
        let levels = CaptureDiagnostics.levels(channels: [
            (average: -42, peak: -18), (average: -20, peak: -8)
        ])
        XCTAssertEqual(levels.averageDBFS, -20)
        XCTAssertEqual(levels.peakDBFS, -8)
    }

    func testUnavailableMetersRemainUnavailable() {
        let empty = CaptureDiagnostics.levels(channels: [])
        XCTAssertNil(empty.averageDBFS)
        XCTAssertNil(empty.peakDBFS)
        let invalid = CaptureDiagnostics.levels(channels: [
            (average: .nan, peak: .infinity), (average: -.infinity, peak: .nan)
        ])
        XCTAssertNil(invalid.averageDBFS)
        XCTAssertNil(invalid.peakDBFS)
    }

    func testFiniteReadingsAreIndependentAndClampedForDisplay() {
        let levels = CaptureDiagnostics.levels(channels: [
            (average: -500, peak: .nan), (average: .nan, peak: 4)
        ])
        XCTAssertEqual(levels.averageDBFS, -160)
        XCTAssertEqual(levels.peakDBFS, 0)
    }

    func testExplicitMissingMicrophoneNeverFallsBack() {
        XCTAssertNil(CaptureDiagnostics.resolveMicrophoneID(
            requested: "disconnected", systemDefault: "built-in", available: ["built-in", "usb"]))
        XCTAssertEqual(CaptureDiagnostics.resolveMicrophoneID(
            requested: "usb", systemDefault: "built-in", available: ["built-in", "usb"]), "usb")
    }

    func testSystemDefaultRequiresAnAvailableDevice() {
        XCTAssertEqual(CaptureDiagnostics.resolveMicrophoneID(
            requested: nil, systemDefault: "built-in", available: ["built-in", "usb"]), "built-in")
        XCTAssertNil(CaptureDiagnostics.resolveMicrophoneID(
            requested: nil, systemDefault: nil, available: ["usb"]))
        XCTAssertNil(CaptureDiagnostics.resolveMicrophoneID(
            requested: nil, systemDefault: "disconnected", available: ["usb"]))
    }

    func testOrdinaryStopWithMovieAndNoErrorsIsTheOnlySuccessfulCombination() {
        for fileExists in [false, true] {
            for delegateError in [false, true] {
                for pendingFailure in [false, true] {
                    for expectedStop in [false, true] {
                        let actual = CaptureDiagnostics.mayReportSuccessfulFinish(
                            fileExists: fileExists, delegateReportedError: delegateError,
                            hasPendingFailure: pendingFailure, expectedStop: expectedStop)
                        XCTAssertEqual(actual, fileExists && !delegateError && !pendingFailure && expectedStop)
                    }
                }
            }
        }
    }

    func testRecoverableFileDoesNotHideDelegateErrorOrEarlierInterruption() {
        XCTAssertFalse(CaptureDiagnostics.mayReportSuccessfulFinish(
            fileExists: true, delegateReportedError: true, hasPendingFailure: false, expectedStop: true))
        XCTAssertFalse(CaptureDiagnostics.mayReportSuccessfulFinish(
            fileExists: true, delegateReportedError: false, hasPendingFailure: true, expectedStop: true))
    }
}
