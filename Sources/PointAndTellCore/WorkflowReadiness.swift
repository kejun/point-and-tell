import Foundation

public struct WorkflowReadiness: Equatable {
    public var screenPermission: Bool
    public var microphonePermission: Bool
    public var hasDisplay: Bool
    public var hasMicrophone: Bool
    public var hasAPIKey: Bool
    public var automaticUploadConsent: Bool

    public init(screenPermission: Bool, microphonePermission: Bool, hasDisplay: Bool,
                hasMicrophone: Bool, hasAPIKey: Bool, automaticUploadConsent: Bool) {
        self.screenPermission = screenPermission; self.microphonePermission = microphonePermission
        self.hasDisplay = hasDisplay; self.hasMicrophone = hasMicrophone
        self.hasAPIKey = hasAPIKey; self.automaticUploadConsent = automaticUploadConsent
    }
    public var canEnterWorkspace: Bool {
        screenPermission && microphonePermission && hasDisplay && hasMicrophone && hasAPIKey && automaticUploadConsent
    }
    public static func validAPIKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
}

/// A new recording arms one automatic attempt. Opening projects, duplicate stop
/// callbacks, cancellation and failure must never silently resend billed audio.
public struct AutomaticTranscriptionGate {
    private var recordingID: UUID?
    public init() {}
    public mutating func arm(projectID: UUID) { recordingID = projectID }
    public mutating func cancel() { recordingID = nil }
    public mutating func consume(projectID: UUID, usableAudio: Bool, needsAudioReview: Bool, ready: Bool) -> Bool {
        guard recordingID == projectID else { return false }
        recordingID = nil
        return usableAudio && !needsAudioReview && ready
    }
}
