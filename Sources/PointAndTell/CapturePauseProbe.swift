#if os(macOS)
import AppKit
import AVFoundation
import PointAndTellCore

/// Opt-in local capture probe. Requires permissions already granted; never opens
/// a permission dialog, loads a key, or uploads media. CI reports absent hardware
/// or consent as unavailable, not as a successful device test.
final class CapturePauseProbe {
    private let recorder = RecordingEngine()
    private let directory: URL
    private var window: NSWindow?
    private var watchdog: DispatchWorkItem?
    private var events: [[String: Any]] = []
    private var completed = false
    private var pausedClock = 0.0
    private var finalClock = 0.0
    private var markerClock = 0.0
    private let completion: (Int32) -> Void
    init(directory: URL, completion: @escaping (Int32) -> Void) { self.directory = directory; self.completion = completion }
    func start() {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { finish("failed", detail: error.localizedDescription, code: 1); return }
        guard CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              !RecordingEngine.microphoneChoices().isEmpty, let screen = NSScreen.main else {
            finish("unavailable", detail: "Screen/microphone permission or an audio input is unavailable; no device capture was performed.", code: 77); return
        }
        let panel = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.backgroundColor = NSColor(deviceRed: 0.1, green: 0.7, blue: 0.2, alpha: 1)
        panel.makeKeyAndOrderFront(nil); window = panel
        recorder.onFailure = { [weak self] error in self?.finish("failed", detail: error.localizedDescription, code: 1) }
        let deadline = DispatchWorkItem { [weak self] in self?.finish("failed", detail: "Native capture probe timed out", code: 1) }
        watchdog = deadline; DispatchQueue.main.asyncAfter(deadline: .now() + 85, execute: deadline)
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        recorder.start(displayID: display, fps: 5, outputURL: directory.appendingPathComponent("pause-resume.mov")) { [weak self] result in
            guard let self = self, self.accept(result) else { return }
            self.note("started")
            self.later(10) { self.pause() }
        }
    }
    private func later(_ seconds: Double, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard self?.completed == false else { return }; action()
        }
    }
    private func pause() {
        recorder.pause { [weak self] result in
            guard let self = self, self.accept(result) else { return }
            self.note("paused"); self.pausedClock = self.recorder.elapsedSeconds
            // Change the test-only screen after the pause acknowledgement. Any
            // magenta central pixel in the finalized movie is a test failure.
            self.window?.backgroundColor = NSColor(deviceRed: 0.8, green: 0.1, blue: 0.8, alpha: 1)
            self.later(29.5) {
                guard abs(self.recorder.elapsedSeconds - self.pausedClock) < 0.001 else {
                    self.finish("failed", detail: "Paused effective clock advanced", code: 1); return
                }
                self.window?.backgroundColor = NSColor(deviceRed: 0.1, green: 0.2, blue: 0.8, alpha: 1)
                self.later(0.5) { self.resume() }
            }
        }
    }
    private func resume() {
        recorder.resume { [weak self] result in
            guard let self = self, self.accept(result) else { return }
            self.note("resumed")
            self.later(2) { self.markerClock = self.recorder.elapsedSeconds; self.note("marker-after-resume") }
            self.later(8) {
                self.recorder.stop { [weak self] result in
                    guard let self = self else { return }
                    switch result {
                    case .failure(let error): self.finish("failed", detail: error.localizedDescription, code: 1)
                    case .success(let url): self.inspect(url)
                    }
                }
            }
        }
    }
    private func inspect(_ url: URL) {
        note("finished")
        finalClock = recorder.elapsedSeconds
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () -> [String: Any] in
                let media = try RecordingMediaInspector.inspect(movieURL: url)
                guard abs(media.durationSeconds - 18) < 1.2 else { throw ProbeError("Paused wall time remained in MOV duration: \(media.durationSeconds)") }
                guard abs(self.finalClock - media.durationSeconds) < 0.5 else { throw ProbeError("Live media clock disagrees with finalized MOV: \(self.finalClock) vs \(media.durationSeconds)") }
                guard abs(self.markerClock - self.pausedClock - 2) < 0.6 else { throw ProbeError("Post-resume screenshot clock drifted") }
                let asset = AVURLAsset(url: url)
                var evidence: [String: Any] = ["duration": media.durationSeconds, "audioDecodedDuration": media.audio.durationSeconds]
                for type in [AVMediaType.video, .audio] {
                    guard let track = asset.tracks(withMediaType: type).first else { throw ProbeError("Missing media track") }
                    let reader = try AVAssetReader(asset: asset)
                    let settings: [String: Any]? = type == .video
                        ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : nil
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    output.alwaysCopiesSampleData = false; reader.add(output)
                    guard reader.startReading() else { throw ProbeError("Cannot read media PTS") }
                    var count = 0, markers = 0, first = Double.infinity, end = 0.0, gap = 0.0
                    // Preserve real internal empty edits. Leading audio offset
                    // is allowed and recorded, not silently independently reset.
                    for segment in track.segments where segment.isEmpty && segment.timeMapping.target.start.seconds > 0.05 {
                        gap = max(gap, segment.timeMapping.target.duration.seconds)
                    }
                    while reader.status == .reading {
                        let more: Bool = try autoreleasepool {
                            guard let sample = output.copyNextSampleBuffer() else { return false }
                            let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                            let duration = CMSampleBufferGetOutputDuration(sample).seconds
                            if CMSampleBufferGetNumSamples(sample) == 0 { markers += 1; return true }
                            guard pts.isFinite else { throw ProbeError("Invalid \(type.rawValue) media PTS in sample \(count)") }
                            if count > 0 { gap = max(gap, pts - end) }
                            first = min(first, pts); end = max(end, pts + (duration.isFinite ? max(0, duration) : 0)); count += 1
                            if let pixel = CMSampleBufferGetImageBuffer(sample) {
                                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                                let x = CVPixelBufferGetWidth(pixel) / 2, y = CVPixelBufferGetHeight(pixel) / 2
                                if let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) {
                                    let i = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
                                    if base[i] > 130 && base[i + 1] < 100 && base[i + 2] > 130 { throw ProbeError("Paused magenta screen was written into MOV") }
                                }
                            }
                            return true
                        }
                        if !more { break }
                    }
                    guard reader.status == .completed, count > 0, gap < (type == .video ? 0.8 : 0.25) else { throw ProbeError("Media read failed or pause left a PTS gap: \(gap)") }
                    evidence[type.rawValue] = ["firstPTS": first, "endPTS": end, "largestGap": gap, "samples": count, "controlMarkers": markers]
                }
                return evidence
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.finish("failed", detail: error.localizedDescription, code: 1)
                case .success(let evidence): self.events.append(["media": evidence]); self.extractAudio(url)
                }
            }
        }
    }
    private let chunker = AudioChunker()
    private func extractAudio(_ url: URL) {
        // Uses exactly the production MOV -> WAV path; a pause-sized PTS gap
        // would otherwise be rendered as silence by that path.
        chunker.chunk(movieURL: url, directory: directory.appendingPathComponent("audio")) { result in
            switch result {
            case .failure(let error): self.finish("failed", detail: error.localizedDescription, code: 1)
            case .success(let chunks):
                guard chunks.count == 1, let chunk = chunks.first,
                      abs(chunk.durationSeconds - 18) < 1.2 else { self.finish("failed", detail: "Extracted WAV retained a pause gap", code: 1); return }
                self.events.append(["wavDuration": chunk.durationSeconds, "wavStart": chunk.startSeconds])
                self.finish("passed", detail: "Real native 10s + 30s pause + 8s; MOV/PTS/WAV inspected. No ASR. Human audio/visual sync and Big Sur remain separate device checks.", code: 0)
            }
        }
    }
    private func note(_ name: String) { events.append(["event": name, "mediaSeconds": recorder.elapsedSeconds, "phase": recorder.status.phase]) }
    private func accept(_ result: Result<Void, Error>) -> Bool {
        if case .failure(let error) = result { finish("failed", detail: error.localizedDescription, code: 1); return false }
        return !completed
    }
    private func finish(_ status: String, detail: String, code: Int32) {
        guard !completed else { return }; completed = true; watchdog?.cancel(); window?.orderOut(nil)
        let report: [String: Any] = ["status": status, "detail": detail, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "events": events, "transitions": recorder.transitionDiagnostics]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("results.json"), options: .atomic) }
        catch { print("CAPTURE_PAUSE_PROBE: could not save evidence: \(error.localizedDescription)") }
        print("CAPTURE_PAUSE_PROBE \(status): \(detail)")
        if recorder.isBusy { recorder.stop { _ in self.completion(code) } } else { completion(code) }
    }
    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
