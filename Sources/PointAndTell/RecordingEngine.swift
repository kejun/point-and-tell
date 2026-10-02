#if os(macOS)
import AppKit
import AVFoundation
import AudioToolbox
import CoreGraphics
import VideoToolbox

/// macOS 11-compatible screen + microphone recording. No frame arrays or unbounded
/// sample queues are kept in the application: AVFoundation streams to the movie.
/// Keep this object alive until stop's completion. All callbacks run on main.
final class RecordingEngine: NSObject {
    enum EngineError: LocalizedError {
        case busy, cancelled, notRecording, invalidDestination, destinationExists
        case screenPermission, microphonePermission, microphoneUnavailable
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
            case .displayUnavailable: return "The selected display is no longer available. Select a connected display."
            case .cannotConfigure(let detail): return "Recording could not be configured: \(detail)"
            case .notEnoughDiskSpace: return "The recording volume needs at least 256 MB free. Existing recordings have been preserved."
            case .startTimedOut: return "The screen recorder did not start. Check Screen Recording and Microphone permissions, then reopen the app."
            case .finishTimedOut: return "The recorder did not finish closing its movie. Its partial file has been preserved; do not overwrite it."
            case .interrupted(let reason): return "Recording stopped: \(reason). The existing movie has been preserved."
            }
        }
    }

    struct Status {
        let phase: String
        let elapsedSeconds: Double
        let recordedBytes: Int64
        let requestedFramesPerSecond: Int
        let videoWidth: Int
        let videoHeight: Int
        /// AVCaptureMovieFileOutput chooses its encoder internally. A hardware
        /// preference is not proof of hardware use, so never label it as measured.
        let encoderDescription: String
        let lastError: String?
    }

    /// Configure callbacks on main, before start. onFailure also reports an
    /// interruption when AVFoundation successfully finalized a recoverable movie.
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
    private var encoderDescription = "H.264, system-selected encoder"
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var startWatchdog: DispatchWorkItem?
    private var finishWatchdog: DispatchWorkItem?

    override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
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
                   lastError: lastErrorText)
        }
    }

    func start(displayID: CGDirectDisplayID, fps: Int = 5, outputURL: URL,
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
            self.startCompletion = completion
            self.destination = outputURL
            self.lastResult = nil
            self.savedElapsed = 0
            self.savedBytes = 0
            self.pendingFailure = nil
            self.lastErrorText = nil
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
        guard CGDisplayIsActive(displayID) != 0,
              let screen = AVCaptureScreenInput(displayID: displayID) else {
            throw EngineError.displayUnavailable
        }
        guard let url = destination else { throw EngineError.invalidDestination }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw EngineError.destinationExists }
        let disk = try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)
        if let free = disk[.systemFreeSize] as? NSNumber, free.int64Value < 256 * 1_024 * 1_024 {
            throw EngineError.notEnoughDiskSpace
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw EngineError.microphoneUnavailable }
        let micInput = try AVCaptureDeviceInput(device: microphone)
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
        // .inputPriority avoids a 16:9 preset cropping/stretching a 16:10 display.
        if captureSession.canSetSessionPreset(.inputPriority) { captureSession.sessionPreset = .inputPriority }
        movie.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        movie.minFreeDiskSpaceLimit = 128 * 1_024 * 1_024 // reserve space for finalization + project metadata
        guard let video = movie.connection(with: .video), let audio = movie.connection(with: .audio),
              movie.availableVideoCodecTypes.contains(.h264) else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("H.264 video and microphone connections are required")
        }
        let videoKeys = Set(movie.supportedOutputSettingsKeys(for: video))
        var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264]
        if videoKeys.contains(AVVideoWidthKey), videoKeys.contains(AVVideoHeightKey) {
            videoSettings[AVVideoWidthKey] = width
            videoSettings[AVVideoHeightKey] = height
        }
        if videoKeys.contains(AVVideoScalingModeKey) {
            videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspect
        }
        if videoKeys.contains(AVVideoCompressionPropertiesKey) {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: requestedFPS == 10 ? 3_000_000 : 2_000_000,
                AVVideoExpectedSourceFrameRateKey: requestedFPS,
                AVVideoMaxKeyFrameIntervalKey: requestedFPS * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        }
        encoderDescription = "H.264, system-selected encoder (hardware use is not exposed)"
        if videoKeys.contains(AVVideoEncoderSpecificationKey) {
            videoSettings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
            encoderDescription = "H.264, hardware acceleration preferred (not measured)"
        }
        movie.setOutputSettings(videoSettings, for: video)
        let audioKeys = Set(movie.supportedOutputSettingsKeys(for: audio))
        let wantedAudio: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        let audioSettings = wantedAudio.filter { audioKeys.contains($0.key) }
        guard audioSettings[AVFormatIDKey] != nil else {
            captureSession.commitConfiguration()
            throw EngineError.cannotConfigure("AAC microphone encoding is unavailable")
        }
        movie.setOutputSettings(audioSettings, for: audio)
        captureSession.commitConfiguration()
        session = captureSession
        output = movie
        phase = .starting
        observe(captureSession, operationID: id)
        captureSession.startRunning() // deliberately never blocks the main thread
        guard captureSession.isRunning else { throw EngineError.cannotConfigure("capture session did not start") }
        movie.startRecording(to: url, recordingDelegate: self)
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.operationID == id, self.phase == .starting else { return }
            self.pendingFailure = EngineError.startTimedOut
            self.beginStopping()
        }
        startWatchdog = watchdog
        queue.asyncAfter(deadline: .now() + 15, execute: watchdog)
    }

    private func observe(_ session: AVCaptureSession, operationID: UUID) {
        let center = NotificationCenter.default
        let runtime = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                ?? EngineError.interrupted("capture hardware reported an error")
            self?.interrupt(error, id: operationID)
        }
        observations.append((center, runtime))
        let interruption = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.interrupt(EngineError.interrupted("the capture session was interrupted"), id: operationID)
        }
        observations.append((center, interruption))
        let workspace = NSWorkspace.shared.notificationCenter
        let sleep = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.interrupt(EngineError.interrupted("the Mac is going to sleep"), id: operationID)
        }
        observations.append((workspace, sleep))
    }

    private func interrupt(_ error: Error, id: UUID) {
        queue.async {
            guard self.operationID == id, self.phase != .idle else { return }
            self.pendingFailure = self.pendingFailure ?? error
            if self.phase == .permissions { self.failBeforeStart(error) }
            else if self.phase != .stopping { self.beginStopping() }
        }
    }

    private func beginStopping() {
        phase = .stopping
        startWatchdog?.cancel()
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
        let callback = startCompletion
        startCompletion = nil
        finish(result: .failure(error), failure: error, notifyFinished: false)
        if let callback = callback { deliver { callback(.failure(error)) } }
    }

    private func finish(result: Result<URL, Error>, failure: Error?, notifyFinished: Bool = true) {
        startWatchdog?.cancel()
        finishWatchdog?.cancel()
        savedElapsed = currentDuration()
        savedBytes = output?.recordedFileSize ?? savedBytes
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
        session?.stopRunning()
        session = nil
        output = nil
        phase = .idle
        lastResult = result
        lastErrorText = failure?.localizedDescription
        let starts = startCompletion
        startCompletion = nil
        let stops = stopCompletions
        stopCompletions.removeAll()
        deliver {
            if let starts = starts { starts(.failure(failure ?? EngineError.cancelled)) }
            if let failure = failure { self.onFailure?(failure) }
            for completion in stops { completion(result) }
            if notifyFinished { self.onRecordingFinished?(result) }
        }
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
            self.startWatchdog?.cancel()
            self.phase = .recording
            let callback = self.startCompletion
            self.startCompletion = nil
            if let callback = callback { self.deliver { callback(.success(())) } }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            guard self.output === output else { return }
            let expectedStop = self.phase == .stopping
            let nsError = error as NSError?
            let savedSuccessfully = error == nil ||
                (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
            let exists = FileManager.default.fileExists(atPath: fileURL.path)
            let failure: Error? = self.pendingFailure ?? error ??
                (!savedSuccessfully || !exists
                    ? EngineError.interrupted("the movie could not be finalized")
                    : (expectedStop ? nil : EngineError.interrupted("the recorder ended unexpectedly")))
            let result: Result<URL, Error> = savedSuccessfully && exists
                ? .success(fileURL)
                : .failure(failure ?? EngineError.interrupted("the movie could not be finalized"))
            // Even a failed movie is never deleted: previous fragments may be recoverable.
            self.finish(result: result, failure: failure)
        }
    }
}

#endif
