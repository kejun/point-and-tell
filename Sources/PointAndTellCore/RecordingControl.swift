import Foundation

/// Serial-queue state used by the native recorder. No wall-clock media arithmetic.
public struct RecordingControl {
    public enum Phase: String, Sendable {
        case idle, permissions, starting, recording, pausing, paused, resuming, stopping
        public var canStop: Bool { [.recording, .pausing, .paused, .resuming].contains(self) }
        public var canCapture: Bool { self == .recording }
        public var isBusy: Bool { self != .idle }
        public var freezesClock: Bool { self == .paused || self == .resuming }
    }
    public enum Kind: Equatable { case pause, resume }
    public struct Ticket: Equatable {
        public let operationID: UUID
        public let requestID: UUID
        public let kind: Kind
    }
    public enum Request: Equatable { case started(Ticket), unchanged, rejected }
    public private(set) var phase: Phase = .idle
    public private(set) var operationID = UUID()
    public private(set) var screenshotEpoch = UUID()
    public private(set) var pending: Ticket?
    public private(set) var duration = 0.0
    public init() {}

    @discardableResult public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        operationID = UUID(); screenshotEpoch = UUID(); duration = 0
        pending = nil; phase = .permissions; return true
    }
    public mutating func configured() { if phase == .permissions { phase = .starting } }
    @discardableResult public mutating func started() -> Bool {
        guard phase == .starting else { return false }; phase = .recording; return true
    }
    public mutating func request(_ kind: Kind) -> Request {
        if (kind == .pause && phase == .paused) || (kind == .resume && phase == .recording) { return .unchanged }
        guard pending == nil, (kind == .pause ? phase == .recording : phase == .paused) else { return .rejected }
        let ticket = Ticket(operationID: operationID, requestID: UUID(), kind: kind)
        pending = ticket; phase = kind == .pause ? .pausing : .resuming
        screenshotEpoch = UUID(); return .started(ticket)
    }
    @discardableResult public mutating func acknowledge(_ ticket: Ticket) -> Bool {
        guard pending == ticket, ticket.operationID == operationID,
              phase == (ticket.kind == .pause ? .pausing : .resuming) else { return false }
        pending = nil; phase = ticket.kind == .pause ? .paused : .recording; return true
    }
    @discardableResult public mutating func stop() -> Bool {
        guard phase != .idle, phase != .stopping else { return false }
        pending = nil; phase = .stopping; screenshotEpoch = UUID(); return true
    }
    public mutating func finish() { pending = nil; phase = .idle; screenshotEpoch = UUID() }
    /// Observe effective native media time only. Paused wall time never enters here.
    @discardableResult public mutating func observeDuration(_ seconds: Double) -> Double {
        if !phase.freezesClock, seconds.isFinite, seconds >= 0 { duration = max(duration, seconds) }
        return duration
    }
    public func allowsScreenshot(operationID: UUID, epoch: UUID) -> Bool {
        phase.canCapture && self.operationID == operationID && screenshotEpoch == epoch
    }
}
