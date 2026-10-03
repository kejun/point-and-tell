#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import VideoToolbox
import PointAndTellCore

/// macOS 11-compatible screen + microphone recording. No frame arrays or unbounded
/// sample queues are kept in the application: AVFoundation streams to the movie.
/// Keep this object alive until stop's completion. All callbacks run on main.
final class RecordingEngine: NSObject {
    enum EngineError: LocalizedError {
        case busy, cancelled, notRecording, invalidDestination, destinationExists
        case screenPermission, microphonePermission, microphoneUnavailable
        case selectedMicrophoneUnavailable, microphoneConnection(String)
        case displayUnavailable, cannotConfigure(String), notEnoughDiskSpace
        case startTimedOut, finishTimedOut, transitionTimedOut, interrupted(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "A recording is already starting, running, or finishing."
            case .cancelled: return "Recording was cancelled before it started."
            case .notRecording: return "There is no recording to stop."
            case .invalidDestination: return "Choose a local .mov file for the recording."
            case .destinationExists: return "A recording already exists at that path. Choose a new file; the existing file was preserved."
            case .screenPermission: return "Allow Screen Recording for Point & Tell in System Preferences > Security & Privacy > Privacy, then quit and reopen the app if macOS requests it."
            case .microphonePermission: return "Allow Microphone access for Point & Tell in System Preferences > Security & Privacy > Privacy."
            case .microphoneUnavailable: return "No microphone is available. Connect or select a microphone in macOS Sound preferences."
            case .selectedMicrophoneUnavailable: return "The selected microphone is no longer available. Reconnect it or explicitly choose another microphone, then try again. No different microphone was selected automatically."
            case .microphoneConnection(let detail): return "The microphone connection is not ready: \(detail). Check the selected input in macOS Sound preferences. Any partial recording has been preserved."
            case .displayUnavailable: return "The selected display is no longer available. Select a connected display."
            case .cannotConfigure(let detail): return "Recording could not be configured: \(detail)"
            case .notEnoughDiskSpace: return "The recording volume needs at least 256 MB free. Existing recordings have been preserved."
            case .startTimedOut: return "The screen recorder did not start. Check Screen Recording and Microphone permissions, then reopen the app."
            case .finishTimedOut: return "The recorder did not finish closing its movie. Its partial file has been preserved; do not overwrite it."
            case .transitionTimedOut: return "暂停或恢复未在 8 秒内得到系统确认，已结束本次录制并保留文件。请检查设备和权限后重试。"
            case .interrupted(let reason): return "Recording stopped: \(reason). The existing movie has been preserved."
            }
        }
    }

    struct MicrophoneChoice {
        let uniqueID: String
        let name: String
        let isSystemDefault: Bool
    }

    /// Include external and virtual audio inputs on Big Sur as well as built-in
    /// microphones. The older media-type enumeration is deliberately used here:
    /// it remains supported on macOS 11 and does not filter out device types.
    static func microphoneChoices() -> [MicrophoneChoice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.devices(for: .audio).filter { $0.isConnected }.map {
            MicrophoneChoice(uniqueID: $0.uniqueID, name: $0.localizedName,
                             isSystemDefault: $0.uniqueID == defaultID)
        }.sorted {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    struct Status {
        let phase: String
        let elapsedSeconds: Double
        let recordedBytes: Int64
        let requestedFramesPerSecond: Int
        let videoWidth: Int
        let videoHeight: Int
        /// The preset chooses compatible encoders; hardware use is not measured.
        let encoderDescription: String
        /// The actual input resolved at start, not just the user's menu choice.
        let microphoneID: String?
        let microphoneName: String?
        let audioConnectionEnabled: Bool
        let audioConnectionActive: Bool
        /// Maximum per-channel average/peak in dBFS; nil if no valid reading.
        let microphoneAveragePowerDBFS: Float?
        let microphonePeakPowerDBFS: Float?
        /// checking / active / noSignal / unavailable / stopped. A level meter
        /// is advisory and cannot establish speech or a valid saved audio track.
        let microphoneHealth: String
        let lastError: String?
    }

    /// Configure callbacks on main, before start. onFailure is ONLY for an
    /// unexpected interruption with no start/stop completion to handle it. A
    /// recoverable movie may still have been finalized after that interruption.
    var onFailure: ((Error) -> Void)?
    var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    private typealias Phase = RecordingControl.Phase
    private let queue = DispatchQueue(label: "PointAndTell.RecordingEngine", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var control = RecordingControl()
    private var phase: Phase { control.phase }
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var boundaryController: CaptureBoundaryController?
    private var operationID: UUID { control.operationID }
    private var startCompletion: ((Result<Void, Error>) -> Void)?
    private var stopCompletions: [(Result<URL, Error>) -> Void] = []
    private var lastResult: Result<URL, Error>?
    private var destination: URL?
    private var savedElapsed = 0.0
    private var savedBytes: Int64 = 0
    private var pendingFailure: Error?
    private var lastErrorText: String?
    private var requestedFPS = 5
    private var width = 0
    private var height = 0
    private var encoderDescription = "系统协商录制格式（硬件加速未测量）"
    private var failureStage: CaptureFailure.Stage = .permissions
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var startWatchdog: DispatchWorkItem?
    private var finishWatchdog: DispatchWorkItem?
    private var transitionWatchdog: DispatchWorkItem?
    private var transitionCompletion: ((Result<Void, Error>) -> Void)?
    private var transitionTimeout: TimeInterval = 8
    /// Only injected by the offline native driver fixture; production reads AVFoundation.
    private var microphoneProbe: (() -> Bool)?
    private var transitionTrace: [String] = []
    var transitionDiagnostics: [String] { read { transitionTrace + (boundaryController?.diagnostics ?? []) } }
    private func traceTransition(_ event: String) {
        let raw = output.map { CMTimeGetSeconds($0.recordedDuration) } ?? savedElapsed
        transitionTrace.append("\(event); phase=\(phase.rawValue); nativePaused=\(output?.isRecordingPaused ?? false); nativeDuration=\(raw)")
        if transitionTrace.count > 16 { transitionTrace.removeFirst(transitionTrace.count - 16) }
    }
    private var requestedMicrophoneID: String?
    private var microphoneID: String?
    private var microphoneName: String?
    private var audioConnectionEnabled = false
    private var audioConnectionActive = false
    private var microphoneAveragePowerDBFS: Float?
    private var microphonePeakPowerDBFS: Float?
    private var microphoneHealth = "stopped"
    private var microphoneTimer: DispatchSourceTimer?
    private var movieDidStart = false
    private var audioInactiveSince: TimeInterval?
    private var quietSince: TimeInterval?

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        transitionWatchdog?.cancel()
        microphoneTimer?.cancel()
        for (center, token) in observations { center.removeObserver(token) }
        // A normal app termination should wait for stop's completion instead.
        if movieDidStart || output?.isRecording == true || output?.isRecordingPaused == true { output?.stopRecording() }
        session?.stopRunning()
    }

    var isRecording: Bool { read { phase == .recording } }
    var isBusy: Bool { read { phase != .idle } }
    var capturePhase: RecordingControl.Phase { read { phase } }
    var canStop: Bool { read { phase.canStop } }
    var screenshotToken: (operationID: UUID, epoch: UUID) { read { (operationID, control.screenshotEpoch) } }
    func allowsScreenshot(_ token: (operationID: UUID, epoch: UUID)) -> Bool {
        read { control.allowsScreenshot(operationID: token.operationID, epoch: token.epoch) }
    }
    var lastOutputURL: URL? { read { destination } }

    /// Movie-relative time, from the SAME AVFoundation output as screen and mic.
    /// This is intentionally not a Date/uptime stopwatch. It has capture-buffer
    /// granularity (up to roughly one video frame), not sample-accurate UI timing.
    /// Query immediately around a screenshot/marker capture; do not add a second
    /// start-time offset when associating transcribed audio with that marker.
    var elapsedSeconds: Double { read { currentDuration() } }

    var status: Status {
        read {
            Status(phase: phase.rawValue, elapsedSeconds: currentDuration(),
                   recordedBytes: output?.recordedFileSize ?? savedBytes,
                   requestedFramesPerSecond: requestedFPS, videoWidth: width,
                   videoHeight: height, encoderDescription: encoderDescription,
                   microphoneID: microphoneID, microphoneName: microphoneName,
                   audioConnectionEnabled: audioConnectionEnabled,
                   audioConnectionActive: audioConnectionActive,
                   microphoneAveragePowerDBFS: microphoneAveragePowerDBFS,
                   microphonePeakPowerDBFS: microphonePeakPowerDBFS,
                   microphoneHealth: microphoneHealth,
                   lastError: lastErrorText ?? pendingFailure?.localizedDescription)
        }
    }

    func start(displayID: CGDirectDisplayID, fps: Int = 5, microphoneID: String? = nil, outputURL: URL,
               completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard self.phase == .idle else {
                self.deliver { completion(.failure(EngineError.busy)) }; return
            }
            guard outputURL.isFileURL, outputURL.pathExtension.lowercased() == "mov" else {
                self.deliver { completion(.failure(EngineError.invalidDestination)) }; return
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                self.deliver { completion(.failure(EngineError.destinationExists)) }; return
            }
            self.control.begin()
            self.transitionTrace.removeAll()
            let id = self.operationID
            self.failureStage = .permissions
            self.startCompletion = completion
            self.destination = outputURL
            self.lastResult = nil
            self.savedElapsed = 0
            self.savedBytes = 0
            self.pendingFailure = nil
            self.lastErrorText = nil
            self.requestedMicrophoneID = microphoneID
            self.microphoneID = nil
            self.microphoneName = nil
            self.audioConnectionEnabled = false
            self.audioConnectionActive = false
            self.microphoneAveragePowerDBFS = nil
            self.microphonePeakPowerDBFS = nil
            self.microphoneHealth = "checking"
            self.movieDidStart = false
            self.audioInactiveSince = nil
            self.quietSince = nil
            self.width = 0
            self.height = 0
            self.requestedFPS = fps == 10 ? 10 : 5
            // Permission UI must be entered from the main thread. A Stop while
            // permission UI is open invalidates this generation before setup.
            DispatchQueue.main.async {
                guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                    self.permissionResult(.failure(EngineError.screenPermission), id: id, displayID: displayID)
                    return
                }
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    self.permissionResult(.success(()), id: id, displayID: displayID)
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        self.permissionResult(granted ? .success(()) : .failure(EngineError.microphonePermission),
                                              id: id, displayID: displayID)
                    }
                default:
                    self.permissionResult(.failure(EngineError.microphonePermission), id: id, displayID: displayID)
                }
            }
        }
    }

    /// Idempotent while stopping: each caller gets the same finalized result.
    /// After a completed run, a repeated Stop returns that run's cached result.
    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            if self.phase == .idle {
                let result = self.lastResult ?? .failure(EngineError.notRecording)
                self.deliver { completion(result) }; return
            }
            self.stopCompletions.append(completion)
            if self.phase == .permissions {
                self.failBeforeStart(EngineError.cancelled)
            } else if self.phase != .stopping {
                self.beginStopping()
            }
        }
    }

    func pause(completion: @escaping (Result<Void, Error>) -> Void) { transition(.pause, completion: completion) }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) { transition(.resume, completion: completion) }

    private func transition(_ kind: RecordingControl.Kind, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            switch self.control.request(kind) {
            case .unchanged: self.deliver { completion(.success(())) }
            case .rejected: self.deliver { completion(.failure(EngineError.busy)) }
            case .started(let ticket):
                self.traceTransition(kind == .pause ? "request pause" : "request resume")
                self.failureStage = kind == .pause ? .pausing : .resuming
                self.transitionCompletion = completion
                self.audioInactiveSince = nil; self.quietSince = nil
                self.microphoneAveragePowerDBFS = nil; self.microphonePeakPowerDBFS = nil
                self.microphoneHealth = kind == .pause ? "pausing" : "resuming"
                let watchdog = DispatchWorkItem { [weak self] in
                    guard let self = self, self.control.pending == ticket else { return }
                    self.traceTransition("transition timeout")
                    self.pendingFailure = CaptureFailure(stage: self.failureStage, underlying: EngineError.transitionTimedOut)
                    self.beginStopping()
                }
                self.transitionWatchdog = watchdog
                self.queue.asyncAfter(deadline: .now() + self.transitionTimeout, execute: watchdog)
                if let boundary = self.boundaryController { boundary.request(kind == .pause ? .pause : .resume) }
                else if kind == .pause { self.output?.pauseRecording() }
                else { self.output?.resumeRecording() }
            }
        }
    }

    private func acknowledgeTransition(_ kind: RecordingControl.Kind, output: AVCaptureFileOutput, fileURL: URL) {
        queue.async {
            self.traceTransition("delegate \(kind); sameOutput=\(self.output === output); sameURL=\(self.destination == fileURL)")
            guard self.output === output, self.destination == fileURL,
                  let ticket = self.control.pending, ticket.operationID == self.operationID,
                  ticket.kind == kind else { return }
            // Read the native boundary clock before freezing. The output delegate
            // excludes the paused PTS interval once; never subtract it here again.
            if kind == .pause { self.savedElapsed = self.currentDuration() }
            guard self.control.acknowledge(ticket) else { return }
            self.transitionWatchdog?.cancel(); self.transitionWatchdog = nil
            self.audioInactiveSince = nil; self.quietSince = nil
            self.microphoneHealth = kind == .pause ? "paused" : "checking"
            let completion = self.transitionCompletion; self.transitionCompletion = nil
            if kind == .resume { self.refreshMicrophoneStatus(); self.checkMicrophoneReadiness() }
            if self.pendingFailure == nil { self.failureStage = .recording }
            if let completion = completion {
                let result: Result<Void, Error> = self.pendingFailure.map { .failure($0) } ?? .success(())
                self.deliver { completion(result) }
            }
        }
    }

    private func cancelTransition(_ error: Error) {
        transitionWatchdog?.cancel(); transitionWatchdog = nil
        let completion = transitionCompletion; transitionCompletion = nil
        if let completion = completion { deliver { completion(.failure(error)) } }
    }

    private func permissionResult(_ result: Result<Void, Error>, id: UUID, displayID: CGDirectDisplayID) {
        queue.async {
            guard self.operationID == id, self.phase == .permissions else { return }
            switch result {
            case .failure(let error): self.failBeforeStart(error)
            case .success:
                do { try self.configureAndStart(displayID: displayID, id: id) }
                catch { self.failBeforeStart(error) }
            }
        }
    }

    private func configureAndStart(displayID: CGDirectDisplayID, id: UUID) throws {
        failureStage = .configuration
        guard CGDisplayIsActive(displayID) != 0,
              let screen = AVCaptureScreenInput(displayID: displayID) else {
            throw EngineError.displayUnavailable
        }
        failureStage = .destination
        guard let url = destination else { throw EngineError.invalidDestination }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw EngineError.destinationExists }
        let disk = try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)
        if let free = disk[.systemFreeSize] as? NSNumber, free.int64Value < 256 * 1_024 * 1_024 {
            throw EngineError.notEnoughDiskSpace
        }
        failureStage = .microphoneInput
        let availableMicrophones = AVCaptureDevice.devices(for: .audio).filter { $0.isConnected }
        let resolvedID = CaptureDiagnostics.resolveMicrophoneID(
            requested: requestedMicrophoneID,
            systemDefault: AVCaptureDevice.default(for: .audio)?.uniqueID,
            available: availableMicrophones.map(\.uniqueID))
        guard let microphone = availableMicrophones.first(where: { $0.uniqueID == resolvedID }) else {
            throw requestedMicrophoneID == nil
                ? EngineError.microphoneUnavailable : EngineError.selectedMicrophoneUnavailable
        }
        microphoneID = microphone.uniqueID
        microphoneName = microphone.localizedName
        let micInput = try AVCaptureDeviceInput(device: microphone)
        failureStage = .configuration
        let captureSession = AVCaptureSession()
        let movie = AVCaptureMovieFileOutput()
        captureSession.beginConfiguration()
        // Scale at the source, before encoding, while retaining the whole display.
        // CGDisplayMode's physical pixel dimensions also cover Retina displays.
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = max(1, mode?.pixelWidth ?? CGDisplayPixelsWide(displayID))
        let pixelHeight = max(1, mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID))
        let scale = min(1.0, min(1_920.0 / Double(pixelWidth), 1_080.0 / Double(pixelHeight)))
        width = max(2, Int((Double(pixelWidth) * scale / 2).rounded(.down)) * 2)
        height = max(2, Int((Double(pixelHeight) * scale / 2).rounded(.down)) * 2)
        screen.scaleFactor = CGFloat(scale)
        screen.minFrameDuration = CMTime(value: 1, timescale: Int32(requestedFPS))
        screen.capturesCursor = true
        screen.capturesMouseClicks = true
        guard captureSession.canAddInput(screen) else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("screen input is unavailable")
        }
        captureSession.addInput(screen)
        guard captureSession.canAddInput(micInput) else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("microphone input is unavailable")
        }
        captureSession.addInput(micInput)
        guard captureSession.canAddOutput(movie) else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("movie output is unavailable")
        }
        captureSession.addOutput(movie)
        // Use the native preset's compatible video AND audio formats. Source
        // scaling and cadence above still bound capture cost on Retina displays.
        if captureSession.canSetSessionPreset(.high) { captureSession.sessionPreset = .high }
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        movie.minFreeDiskSpaceLimit = 128 * 1_024 * 1_024 // reserve space for finalization + project metadata
        guard let video = movie.connection(with: .video), let audio = movie.connection(with: .audio) else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("video and microphone connections are required")
        }
        audio.isEnabled = true
        // Audio channels are individually mutable on macOS. Enable the selected
        // input's channels, but do not change the device's system gain or mute.
        for channel in audio.audioChannels { channel.isEnabled = true }
        // nil explicitly uses sessionPreset defaults. An EMPTY dictionary would
        // instead request passthrough. Do not force a hardware encoder, dimensions,
        // 44.1 kHz or mono on a device/OS combination that may reject them. Audio
        // is converted to the ASR format later by the existing local AudioChunker.
        movie.setOutputSettings(nil, for: video)
        movie.setOutputSettings(nil, for: audio)
        // The native encoder may buffer frames even with B frames disabled.
        // At 5 fps this presented paused-screen frames for 1.6 seconds on Intel.
        // Bound the compression window as well as disabling reordering, while
        // retaining the negotiated codec/size/bitrate and hardware selection.
        var videoSettings = movie.outputSettings(for: video)
        if videoSettings[AVVideoCodecKey] != nil {
            var compression = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            compression[AVVideoAllowFrameReorderingKey] = false
            compression[AVVideoExpectedSourceFrameRateKey] = requestedFPS
            // AVCaptureMovieFileOutput's H.264 validation accepts only 3 for
            // this VideoToolbox key; requesting 0 or 1 raises NSException.
            compression[kVTCompressionPropertyKey_MaxFrameDelayCount as String] = 3
            compression[kVTCompressionPropertyKey_RealTime as String] = true
            videoSettings[AVVideoCompressionPropertiesKey] = compression
            movie.setOutputSettings(videoSettings, for: video)
            let applied = movie.outputSettings(for: video)[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            traceTransition("encoder compression: \(applied)")
        }
        // Apply start/pause/resume/stop at the movie output's actual audio
        // sample boundary. Only scalar PTS values are observed; no samples are
        // retained, copied, re-encoded or queued by the application.
        let boundary = CaptureBoundaryController(receiver: self)
        movie.delegate = boundary
        boundaryController = boundary
        captureSession.commitConfiguration()
        session = captureSession
        output = movie
        control.configured()
        let runtimeErrors = CaptureSessionErrorLatch()
        observe(captureSession, operationID: id, runtimeErrors: runtimeErrors)
        failureStage = .sessionStart
        captureSession.startRunning() // deliberately never blocks the main thread
        guard captureSession.isRunning else {
            throw runtimeErrors.error ?? EngineError.cannotConfigure("capture session did not start")
        }
        if let error = runtimeErrors.error { throw error }
        refreshMicrophoneStatus()
        guard audioConnectionEnabled else {
            throw EngineError.microphoneConnection("the audio connection is disabled after the capture session started")
        }
        // isActive is inspected now and again at didStart. Allow at most two
        // seconds for driver settling after didStart; this is an application
        // grace period, not an AVFoundation guarantee. Never report startup
        // success before the connection is both enabled and active.
        startMicrophoneMonitoring(operationID: id)
        failureStage = .movieStart
        boundary.request(.start(url))
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.operationID == id, self.phase == .starting else { return }
            self.pendingFailure = CaptureFailure(stage: .movieStart, underlying: EngineError.startTimedOut)
            self.beginStopping()
        }
        startWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + 15, execute: watchdog)
    }

    private func observe(_ session: AVCaptureSession, operationID: UUID, runtimeErrors: CaptureSessionErrorLatch) {
        let center = NotificationCenter.default
        let runtime = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? EngineError.interrupted("capture hardware reported an error")
            // Record before hopping to our blocked serial queue. Otherwise a
            // failed startRunning() cleans up and the actual error is lost.
            runtimeErrors.record(error)
            self?.interrupt(error, id: operationID)
        }
        observations.append((center, runtime))
        let interruption = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.interrupt(EngineError.interrupted("the capture session was interrupted"), id: operationID)
        }
        observations.append((center, interruption))
        let disconnected = center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice else { return }
            let disconnectedID = device.uniqueID
            self?.queue.async { [weak self] in
                guard let self = self, self.operationID == operationID,
                      self.microphoneID == disconnectedID, self.phase != .idle else { return }
                self.pendingFailure = self.pendingFailure ?? CaptureFailure(stage: self.failureStage,
                    underlying: EngineError.interrupted("the selected microphone was disconnected"))
                self.microphoneHealth = "unavailable"
                if self.phase != .stopping { self.beginStopping() }
            }
        }
        observations.append((center, disconnected))
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.interrupt(EngineError.interrupted("the Mac is going to sleep"), id: operationID)
        }
        observations.append((workspace, sleep))
    }

    private func interrupt(_ error: Error, id: UUID) {
        queue.async {
            guard self.operationID == id, self.phase != .idle else { return }
            self.pendingFailure = self.pendingFailure ?? CaptureFailure(stage: self.failureStage, underlying: error)
            if self.phase == .permissions { self.failBeforeStart(error) }
            else if self.phase != .stopping { self.beginStopping() }
        }
    }

    private func beginStopping() {
        savedElapsed = currentDuration()
        guard control.stop() else { return }
        if pendingFailure == nil { failureStage = .finalization }
        cancelTransition(pendingFailure ?? EngineError.cancelled)
        startWatchdog?.cancel()
        stopMicrophoneMonitoring()
        if let boundary = boundaryController { boundary.request(.stop) }
        else if movieDidStart || output?.isRecording == true || output?.isRecordingPaused == true { output?.stopRecording() }
        // Do NOT stop the session until didFinishRecording: stopping it early can
        // prevent movie finalization. A bounded watchdog handles a stuck driver.
        let id = operationID
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.operationID == id, self.phase == .stopping else { return }
            let error = self.pendingFailure ?? EngineError.finishTimedOut
            self.finish(result: .failure(error), failure: error)
        }
        finishWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + 20, execute: watchdog)
    }

    private func failBeforeStart(_ error: Error) {
        finish(result: .failure(error), failure: error, notifyFinished: false)
    }

    private func finish(result: Result<URL, Error>, failure: Error?, notifyFinished: Bool = true) {
        let diagnostic = failure.map { CaptureFailure(stage: failureStage, underlying: $0) }
        let failure: Error? = diagnostic
        let result = result.mapError { CaptureFailure(stage: failureStage, underlying: $0) as Error }
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        cancelTransition(failure ?? EngineError.cancelled)
        stopMicrophoneMonitoring()
        savedElapsed = currentDuration()
        savedBytes = output?.recordedFileSize ?? savedBytes
        transitionTrace += boundaryController?.diagnostics ?? []
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        output?.delegate = nil
        boundaryController?.cancel()
        session?.stopRunning()
        session = nil
        output = nil
        boundaryController = nil
        control.finish()
        lastResult = result
        lastErrorText = diagnostic?.diagnosticText
        audioConnectionEnabled = false
        audioConnectionActive = false
        microphoneAveragePowerDBFS = nil
        microphonePeakPowerDBFS = nil
        microphoneHealth = failure == nil ? "stopped" : "unavailable"
        let starts = startCompletion
        startCompletion = nil
        let stops = stopCompletions
        stopCompletions.removeAll()
        // Start/Stop own their errors. Without this routing, a denied permission
        // or failed stop would produce two identical alerts in the app.
        let notifyFailure = starts == nil && stops.isEmpty
        deliver {
            if let starts = starts { starts(.failure(failure ?? EngineError.cancelled)) }
            if notifyFailure, let failure = failure { self.onFailure?(failure) }
            for completion in stops { completion(result) }
            if notifyFinished { self.onRecordingFinished?(result) }
        }
    }

    private func startMicrophoneMonitoring(operationID id: UUID) {
        stopMicrophoneMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200),
                       leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.operationID == id,
                  self.phase == .starting || self.phase == .recording else { return }
            self.refreshMicrophoneStatus()
            self.checkMicrophoneReadiness()
        }
        microphoneTimer = timer
        timer.resume()
    }

    private func stopMicrophoneMonitoring() {
        microphoneTimer?.setEventHandler {}
        microphoneTimer?.cancel()
        microphoneTimer = nil
    }

    /// Polling audioChannels is the AVFoundation metering API. Keep only the
    /// latest aggregate; no sample buffers, audio data output or growing history.
    private func refreshMicrophoneStatus() {
        if let probe = microphoneProbe {
            audioConnectionEnabled = probe(); audioConnectionActive = audioConnectionEnabled
            microphoneHealth = audioConnectionEnabled ? "active" : "unavailable"; return
        }
        guard let connection = output?.connection(with: .audio) else {
            audioConnectionEnabled = false
            audioConnectionActive = false
            microphoneAveragePowerDBFS = nil
            microphonePeakPowerDBFS = nil
            microphoneHealth = "unavailable"
            return
        }
        audioConnectionEnabled = connection.isEnabled
        audioConnectionActive = connection.isActive
        let levels = CaptureDiagnostics.levels(channels: connection.audioChannels
            .filter { $0.isEnabled }
            .map { (average: $0.averagePowerLevel, peak: $0.peakHoldLevel) })
        microphoneAveragePowerDBFS = levels.averageDBFS
        microphonePeakPowerDBFS = levels.peakDBFS
        guard audioConnectionEnabled, audioConnectionActive else {
            microphoneHealth = movieDidStart ? "unavailable" : "checking"
            quietSince = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // A silent room is not a hardware failure. Offer a speak/check-input
        // hint only after three seconds of low or unavailable meter readings.
        if let average = levels.averageDBFS, average > -60 {
            quietSince = nil
            microphoneHealth = "active"
        } else {
            if quietSince == nil { quietSince = now }
            microphoneHealth = now - (quietSince ?? now) >= 3 ? "noSignal" : "active"
        }
    }

    private func checkMicrophoneReadiness() {
        guard movieDidStart, phase == .starting || phase == .recording else { return }
        if !audioConnectionEnabled {
            failMicrophoneConnection("the audio connection is missing or disabled")
            return
        }
        if !audioConnectionActive {
            let now = ProcessInfo.processInfo.systemUptime
            if let since = audioInactiveSince, now - since >= 2 {
                failMicrophoneConnection("the audio connection remained inactive for two seconds")
            } else if audioInactiveSince == nil {
                audioInactiveSince = now
            }
            return
        }
        audioInactiveSince = nil
        if phase == .starting {
            startWatchdog?.cancel()
            control.started()
            failureStage = .recording
            let callback = startCompletion
            startCompletion = nil
            if let callback = callback { deliver { callback(.success(())) } }
        }
    }

    private func failMicrophoneConnection(_ detail: String) {
        pendingFailure = pendingFailure ?? CaptureFailure(stage: failureStage, underlying: EngineError.microphoneConnection(detail))
        microphoneHealth = "unavailable"
        beginStopping()
    }

    private func currentDuration() -> Double {
        guard let movie = output else { return savedElapsed }
        // On tested macOS outputs recordedDuration includes encoded preroll
        // removed by MOV edits (over two seconds after one resume). Use the
        // same output's sample-boundary PTS, not a wall clock or guessed offset.
        let seconds = boundaryController?.elapsedSeconds ?? CMTimeGetSeconds(movie.recordedDuration)
        savedElapsed = control.observeDuration(seconds)
        return savedElapsed
    }

    private func read<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return block() }
        return queue.sync(execute: block)
    }

    private func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

extension RecordingEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        acknowledgeTransition(.pause, output: output, fileURL: fileURL)
    }
    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        acknowledgeTransition(.resume, output: output, fileURL: fileURL)
    }
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            guard self.output === output, self.destination == fileURL else { return }
            if self.phase == .stopping { output.stopRecording(); return }
            guard self.phase == .starting, !self.movieDidStart else { return }
            self.boundaryController?.confirmStart()
            self.movieDidStart = true
            self.audioInactiveSince = nil
            self.refreshMicrophoneStatus()
            self.checkMicrophoneReadiness()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard self.output === output, self.destination == fileURL, self.phase != .idle else { return }
            let expectedStop = self.phase == .stopping
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let savedSuccessfully = CaptureDiagnostics.mayReportSuccessfulFinish(
                fileExists: exists, delegateReportedError: error != nil,
                hasPendingFailure: self.pendingFailure != nil, expectedStop: expectedStop)
            let failure: Error? = self.pendingFailure ?? error ??
                (!exists
                    ? EngineError.interrupted("the movie could not be finalized")
                    : (expectedStop ? nil : EngineError.interrupted("the recorder ended unexpectedly")))
            let result: Result<URL, Error> = savedSuccessfully
                ? .success(fileURL)
                : .failure(failure ?? EngineError.interrupted("the movie could not be finalized"))
            // AVErrorRecordingSuccessfullyFinishedKey means a partial movie may
            // be playable, not that this requested recording completed without
            // interruption. Never turn an error or pending interruption into
            // success merely because a file exists. Failed files are preserved.
            self.finish(result: result, failure: failure)
        }
    }
}

/// Deterministic native adapter fixture: exercises the actual serial queue,
/// delegate guards, watchdog and completion routing without capturing a device.
extension RecordingEngine {
    static func verifyPauseDriver() throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: "PointAndTell.PauseDriver", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            try require(condition(), "Native driver callback did not complete")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("fake output finalization sentinel".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingEngine()
        func prepare() -> PauseFakeMovieOutput {
            let fake = PauseFakeMovieOutput(); fake.receiver = engine; fake.url = url
            engine.queue.sync {
                engine.control.begin(); engine.control.configured(); engine.control.started()
                engine.output = fake; engine.destination = url; engine.movieDidStart = true
                engine.pendingFailure = nil; engine.lastResult = nil; engine.savedElapsed = 0
                engine.microphoneProbe = { true }; engine.transitionTimeout = 0.15
            }
            return fake
        }
        var fake = prepare(), callbacks = 0
        for _ in 0..<50 {
            engine.pause { if case .success = $0 { callbacks += 1 } }
            try require(engine.capturePhase == .pausing && engine.canStop, "Pause returned without pending state")
            engine.queue.sync { fake.paused = true; fake.emitPause() }
            let expectedPause = callbacks + 1
            try waitFor { callbacks == expectedPause }
            try require(engine.capturePhase == .paused && engine.isBusy, "Pause did not remain busy")
            engine.queue.sync { fake.emitPause() }
            engine.resume { if case .success = $0 { callbacks += 1 } }
            try require(engine.capturePhase == .resuming, "Resume was not pending")
            engine.queue.sync { fake.paused = false; fake.emitResume() }
            let expectedResume = callbacks + 1
            try waitFor { callbacks == expectedResume }
            try require(engine.capturePhase == .recording, "Resume did not restore recording")
        }
        var finishes = 0, stops = 0, cancelled = 0
        engine.onRecordingFinished = { _ in finishes += 1 }
        engine.pause { if case .failure = $0 { cancelled += 1 } }
        engine.stop { if case .success = $0 { stops += 1 } }
        engine.stop { if case .success = $0 { stops += 1 } }
        try waitFor { stops == 2 && cancelled == 1 && finishes == 1 }
        try require(fake.stopCalls == 1 && !engine.isBusy, "Stop must seal once and supersede pause")
        let old = fake; fake = prepare()
        engine.queue.sync { old.emitPause(); old.emitResume(); old.emitFinish() }
        try require(engine.isRecording, "Old output changed a new recording")
        var failures = 0, transitionErrors = 0
        engine.onFailure = { _ in failures += 1 }
        engine.pause { if case .failure = $0 { transitionErrors += 1 } }
        try waitFor { failures == 1 && transitionErrors == 1 && !engine.isBusy }
        try require(fake.stopCalls == 1 && finishes == 2, "Missing pause callback must finalize once on timeout")
        fake = prepare(); var paused = false
        engine.pause { if case .success = $0 { paused = true } }
        engine.queue.sync { fake.paused = true; fake.emitPause() }; try waitFor { paused }
        var pausedStop = false
        engine.stop { if case .success = $0 { pausedStop = true } }; try waitFor { pausedStop }
        try require(fake.stopCalls == 1, "Paused stop must close without resuming")
        fake = prepare(); paused = false
        engine.pause { if case .success = $0 { paused = true } }
        engine.queue.sync { fake.paused = true; fake.emitPause() }; try waitFor { paused }
        var resumeCancelled = false, resumeStop = false
        engine.resume { if case .failure = $0 { resumeCancelled = true } }
        engine.stop { if case .success = $0 { resumeStop = true } }
        engine.queue.sync { fake.paused = false; fake.emitResume() }
        try waitFor { resumeCancelled && resumeStop }
        try require(!engine.isBusy && fake.stopCalls == 1, "Late resume revived a stopped output")
        print("PAUSE_DRIVER_OK · 50 cycles, acknowledgements, timeout, old output, duplicate finish and Stop during pause/resume")
    }
}

private final class PauseFakeMovieOutput: AVCaptureMovieFileOutput {
    weak var receiver: RecordingEngine?
    var url = URL(fileURLWithPath: "/invalid.mov")
    var paused = false
    var open = true
    var stopCalls = 0
    override var isRecording: Bool { open && !paused }
    override var isRecordingPaused: Bool { open && paused }
    override var recordedDuration: CMTime { CMTime(seconds: 10, preferredTimescale: 600) }
    override var recordedFileSize: Int64 { 100 }
    override func pauseRecording() {}
    override func resumeRecording() {}
    override func stopRecording() { stopCalls += 1; open = false; emitFinish() }
    func emitPause() { receiver?.fileOutput(self, didPauseRecordingTo: url, from: []) }
    func emitResume() { receiver?.fileOutput(self, didResumeRecordingTo: url, from: []) }
    func emitFinish() { receiver?.fileOutput(self, didFinishRecordingTo: url, from: [], error: nil) }
}

/// macOS file-output delegate: a single pending command and scalar media clock.
/// The delegate callback has no specified queue. Its small lock never surrounds
/// AVFoundation calls and never synchronously enters the engine's serial queue.
private final class CaptureBoundaryController: NSObject, AVCaptureFileOutputDelegate {
    enum Command { case start(URL), pause, resume, stop }
    private let lock = NSLock()
    private weak var receiver: RecordingEngine?
    private var pending: Command?
    private var clock = RecordingSampleClock()
    private var latestPTS: Double?
    private var trace: [String] = []
    private var cancelled = false
    init(receiver: RecordingEngine) { self.receiver = receiver }
    var elapsedSeconds: Double { lock.lock(); defer { lock.unlock() }; return clock.duration }
    var diagnostics: [String] { lock.lock(); defer { lock.unlock() }; return trace }
    func confirmStart() {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let pts = latestPTS else { return }
        // startRecording may prepare the encoder before writing its first
        // sample, even in sample-accurate mode. The first didStart callback
        // establishes the file origin from the current media sample, not time
        // spent preparing the output. No wall-clock offset is introduced.
        trace.append("file start confirmed; pts=\(pts); preparation=\(clock.duration)")
        clock = RecordingSampleClock(); clock.beginSegment(at: pts)
    }
    func request(_ command: Command) {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { pending = command }
    }
    func cancel() { lock.lock(); cancelled = true; pending = nil; lock.unlock() }
    func fileOutputShouldProvideSampleAccurateRecordingStart(_ output: AVCaptureFileOutput) -> Bool { true }
    func fileOutput(_ output: AVCaptureFileOutput, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    from connection: AVCaptureConnection) {
        // Audio arrives without video encoder reordering latency. Both tracks
        // still share this one output and the native pause/resume operation.
        guard connection.inputPorts.contains(where: { $0.mediaType == .audio }) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
        guard pts.isFinite else { return }
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        latestPTS = pts
        let command = pending; pending = nil
        if let command = command {
            let name: String
            switch command { case .start: name = "start"; case .pause: name = "pause"; case .resume: name = "resume"; case .stop: name = "stop" }
            trace.append("sample boundary \(name); pts=\(pts); clock=\(clock.duration)")
            if trace.count > 8 { trace.removeFirst(trace.count - 8) }
        }
        switch command {
        case .start?, .resume?: clock.beginSegment(at: pts)
        case .pause?, .stop?: clock.endSegment(at: pts)
        case nil: break
        }
        clock.observe(pts: pts, sampleDuration: sampleDuration)
        lock.unlock()
        switch command {
        case .start(let url)?: if let receiver = receiver { output.startRecording(to: url, recordingDelegate: receiver) }
        case .pause?: output.pauseRecording()
        case .resume?: output.resumeRecording()
        case .stop?: output.stopRecording()
        case nil: break
        }
    }
}

#endif
