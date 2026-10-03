import Foundation

/// Presentation time from the movie output's sample boundaries. Keeps no
/// frames and never reads a wall clock. Pause excludes only the interval between
/// the acknowledged native pause/resume boundaries; gaps within a segment remain.
public struct RecordingSampleClock {
    private var segmentStart: Double?
    private var completedDuration = 0.0
    public private(set) var duration = 0.0
    public init() {}
    public mutating func beginSegment(at pts: Double) {
        guard pts.isFinite, segmentStart == nil else { return }
        segmentStart = pts
    }
    public mutating func endSegment(at pts: Double) {
        guard pts.isFinite, let start = segmentStart, pts >= start else { return }
        completedDuration += pts - start
        duration = max(duration, completedDuration)
        segmentStart = nil
    }
    public mutating func observe(pts: Double, sampleDuration: Double) {
        guard pts.isFinite, let start = segmentStart, pts >= start else { return }
        let tail = sampleDuration.isFinite ? max(0, sampleDuration) : 0
        duration = max(duration, completedDuration + pts - start + tail)
    }
}
