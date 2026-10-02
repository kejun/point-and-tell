/// Pure, platform-independent policy shared by capture and regression tests.
public enum CaptureDiagnostics {
    public struct Levels: Equatable {
        public let averageDBFS: Float?
        public let peakDBFS: Float?
    }

    /// Display the loudest channel, rather than incorrectly averaging logarithmic
    /// dB values. Ignore unavailable/NaN readings and clamp only the display range.
    /// This holds one aggregate, never any growing audio or metering history.
    public static func levels(channels: [(average: Float, peak: Float)]) -> Levels {
        var average: Float?
        var peak: Float?
        for channel in channels {
            if channel.average.isFinite {
                let value = min(0, max(-160, channel.average))
                average = max(average ?? value, value)
            }
            if channel.peak.isFinite {
                let value = min(0, max(-160, channel.peak))
                peak = max(peak ?? value, value)
            }
        }
        return Levels(averageDBFS: average, peakDBFS: peak)
    }

    /// A stale explicit selection must never silently route capture to a
    /// different device. Resolve the system default only for an explicit nil.
    public static func resolveMicrophoneID(requested: String?, systemDefault: String?,
                                           available: [String]) -> String? {
        guard let candidate = requested ?? systemDefault, available.contains(candidate) else { return nil }
        return candidate
    }

    /// AVErrorRecordingSuccessfullyFinishedKey may describe a recoverable partial
    /// movie. It cannot turn an interrupted recording into an unqualified success.
    public static func mayReportSuccessfulFinish(fileExists: Bool, delegateReportedError: Bool,
                                                 hasPendingFailure: Bool, expectedStop: Bool) -> Bool {
        fileExists && !delegateReportedError && !hasPendingFailure && expectedStop
    }
}
