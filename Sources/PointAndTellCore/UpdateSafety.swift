/// One snapshot covers capture startup/finalization as well as recording.
/// Evaluate again at termination: an earlier successful check is not permission
/// to discard later work. This contains no updater/network/platform code.
public struct UpdateActivity: Equatable, Sendable {
    public var recordingBusy: Bool
    public var processingBusy: Bool
    public var screenshotPending: Bool
    public var annotationOpen: Bool
    public var modalOpen: Bool

    public init(recordingBusy: Bool = false, processingBusy: Bool = false,
                screenshotPending: Bool = false, annotationOpen: Bool = false,
                modalOpen: Bool = false) {
        self.recordingBusy = recordingBusy; self.processingBusy = processingBusy
        self.screenshotPending = screenshotPending; self.annotationOpen = annotationOpen
        self.modalOpen = modalOpen
    }
    public var hasActiveWork: Bool {
        recordingBusy || processingBusy || screenshotPending || annotationOpen
    }
    public var canPresentUpdate: Bool { !hasActiveWork && !modalOpen }
}

/// Main-thread owned by the macOS controller. An interactive update temporarily
/// locks new work; cancelling/failing it restores editing immediately.
public final class UpdateSessionGate {
    public private(set) var blocksWork = false
    public init() {}

    @discardableResult
    public func begin(activity: UpdateActivity, save: () -> Bool) -> Bool {
        guard !blocksWork, activity.canPresentUpdate, save() else { return false }
        blocksWork = true
        return true
    }
    public func finish() { blocksWork = false }

    public static func mayTerminate(activity: UpdateActivity, save: () -> Bool) -> Bool {
        guard !activity.hasActiveWork else { return false }
        return save()
    }
}
