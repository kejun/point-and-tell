#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
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
        case startTimedOut, finishTimedOut, interrupted(String)

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

    private enum Phase: String { case idle, permissions, starting, recording, stopping }
    private let queue = DispatchQueue(label: "PointAndTell.RecordingEngine", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var phase: Phase = .idle
    private var session: AVCaptureSession?
    private var output: AVCaptureMovieFileOutput?
    private var operationID = UUID()
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
        microphoneTimer?.cancel()
        for (center, token) in observations { center.removeObserver(token) }
        // A normal app termination should wait for stop's completion instead.
        if output?.isRecording == true { output?.stopRecording() }
        session?.stopRunning()
    }

    var isRecording: Bool { read { phase == .recording } }
    var isBusy: Bool { read { phase != .idle } }
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
            self.operationID = UUID()
            let id = self.operationID
            self.phase = .permissions
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
                self.operationID = UUID()
                self.failBeforeStart(EngineError.cancelled)
            } else if self.phase != .stopping {
                self.beginStopping()
            }
        }
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
        captureSession.commitConfiguration()
        session = captureSession
        output = movie
        phase = .starting
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
        movie.startRecording(to: url, recordingDelegate: self)
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
        if phase == .recording { failureStage = .finalization }
        phase = .stopping
        startWatchdog?.cancel()
        stopMicrophoneMonitoring()
        savedElapsed = currentDuration()
        if output?.isRecording == true { output?.stopRecording() }
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
        stopMicrophoneMonitoring()
        savedElapsed = currentDuration()
        savedBytes = output?.recordedFileSize ?? savedBytes
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        session?.stopRunning()
        session = nil
        output = nil
        phase = .idle
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
            phase = .recording
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
        let seconds = CMTimeGetSeconds(movie.recordedDuration)
        return seconds.isFinite && seconds >= 0 ? max(savedElapsed, seconds) : savedElapsed
    }

    private func read<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return block() }
        return queue.sync(execute: block)
    }

    private func deliver(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
}

extension RecordingEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            guard self.output === output else { return }
            if self.phase == .stopping { output.stopRecording(); return }
            guard self.phase == .starting else { return }
            self.movieDidStart = true
            self.audioInactiveSince = nil
            self.refreshMicrophoneStatus()
            self.checkMicrophoneReadiness()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard self.output === output else { return }
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

#endif
