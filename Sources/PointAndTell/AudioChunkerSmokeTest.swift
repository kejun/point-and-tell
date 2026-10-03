#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import PointAndTellCore

/// Offline integration coverage for the actual AAC-in-MOV -> 16 kHz WAV path.
/// Fixtures are synthesized by native AVAssetWriter, not an external encoder.
/// Requires a running main run loop. Never captures a device or calls ASR.
enum AudioChunkerSmokeTest {
    static func run(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
        Runner(directory: directory, completion: completion).start()
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { "Native audio integration test: " + message }
    }

    private struct Fixture {
        let name: String
        let rate: Int32
        let seconds: Int
        let offset: Double
        let amplitude: Double
        var timingTolerance: Double { 2 * 1_024 / Double(rate) + 1 / 16_000.0 }
    }

    private struct FixtureResult: Codable {
        let name: String
        let sourceCodec: String
        let sourceSampleRateHz: Int32
        let sourceDurationSeconds: Double
        let sourceTrackSpanDurationSeconds: Double
        let sourceDecodedFrames: Int64
        let rmsDBFS: Double
        let peakDBFS: Double
        let suspectedSilence: Bool
        let chunkDurationsSeconds: [Double]
        let chunkStartSeconds: [Double]
        let detectedSignalStartSeconds: Double?
        let playbackReadyChecked: Bool
    }

    private struct SmokeReport: Codable {
        let status: String
        let fixtures: [FixtureResult]
        let passedChecks: [String]
        let failure: String?
    }

    private final class Runner {
        private let baseDirectory: URL
        private let completion: (Result<String, Error>) -> Void
        private let work = DispatchQueue(label: "PointAndTell.NativeAudioIntegration", qos: .utility)
        private let chunker = AudioChunker()
        private let deadline = DispatchTime.now() + 180
        private var watchdog: DispatchWorkItem?
        // Only touched on main.
        private var finished = false
        private let sampleRate = 16_000
        private let frequency = 1_000.0
        private var fixtureResults: [FixtureResult] = []
        private var passedChecks: [String] = []

        init(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
            baseDirectory = directory
            self.completion = completion
        }

        func start() {
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(TestFailure(message: "timed out after 180 seconds; the main run loop must be running.")))
            }
            watchdog = timeout
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: timeout)
            work.async {
                var runDirectory: URL?
                do {
                    let directory = self.baseDirectory.appendingPathComponent("native-audio-" + UUID().uuidString.lowercased(), isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    runDirectory = directory
                    let fixtures = [
                        Fixture(name: "44100-short", rate: 44_100, seconds: 2, offset: 0, amplitude: 0.35),
                        Fixture(name: "48000-short", rate: 48_000, seconds: 2, offset: 0, amplitude: 0.35),
                        Fixture(name: "44100-long", rate: 44_100, seconds: 181, offset: 0, amplitude: 0.35),
                        Fixture(name: "48000-long", rate: 48_000, seconds: 181, offset: 0, amplitude: 0.35),
                        Fixture(name: "48000-delayed", rate: 48_000, seconds: 2, offset: 0.375, amplitude: 0.35),
                        Fixture(name: "44100-silent", rate: 44_100, seconds: 1, offset: 0, amplitude: 0)
                    ]
                    for fixture in fixtures {
                        try self.checkDeadline()
                        try autoreleasepool { try self.checkFixture(fixture, in: directory) }
                    }
                    let missing = directory.appendingPathComponent("video-without-audio.mov")
                    try self.writeMovie(to: missing, fixture: nil)
                    try self.require(AVURLAsset(url: missing).tracks(withMediaType: .video).count == 1,
                                     "no-audio fixture is not a valid video MOV")
                    try self.checkRejectedSource(missing, directory: directory)
                    let corrupt = directory.appendingPathComponent("corrupt.mov")
                    try Data("intentionally invalid MOV fixture".utf8).write(to: corrupt, options: .withoutOverwriting)
                    try self.checkRejectedSource(corrupt, directory: directory)
                    try self.writeTestReport(to: directory, status: "passed", failure: nil)
                    self.finish(.success("PASS: native AAC-in-MOV at 44.1/48 kHz (2 s and 181 s), delayed audio, silence, missing audio and corruption; 16 kHz mono PCM WAV headers, durations, offsets, RMS/peak, 1 kHz tone correlation, source/WAV inspection, main-queue completion, safe retry and source/partial-file preservation. No device capture or ASR. Fixtures: \(directory.path)"))
                } catch {
                    if let directory = runDirectory {
                        let safeFailure = (error as? TestFailure)?.localizedDescription
                            ?? "Native framework or filesystem error during fixture generation/validation."
                        try? self.writeTestReport(to: directory, status: "failed", failure: safeFailure)
                    }
                    self.finish(.failure(error))
                }
            }
        }

        private func checkFixture(_ fixture: Fixture, in directory: URL) throws {
            let source = directory.appendingPathComponent(fixture.name + ".mov")
            let output = directory.appendingPathComponent(fixture.name + "-audio", isDirectory: true)
            try writeMovie(to: source, fixture: fixture)
            let asset = AVURLAsset(url: source)
            try require(!asset.tracks(withMediaType: .video).isEmpty, "\(fixture.name): missing fixture video")
            guard let audio = asset.tracks(withMediaType: .audio).first,
                  let description = audio.formatDescriptions.first else {
                throw TestFailure(message: "\(fixture.name): writer did not create audio")
            }
            let formatDescription = description as! CMAudioFormatDescription
            guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else {
                throw TestFailure(message: "\(fixture.name): missing source audio format")
            }
            try require(format.mFormatID == kAudioFormatMPEG4AAC &&
                        abs(format.mSampleRate - Double(fixture.rate)) < 0.01,
                        "\(fixture.name): source is not AAC at the requested native rate")
            let originalDigest = try digest(source)
            let media = try RecordingMediaInspector.inspect(movieURL: source)
            let report = media.audio
            try require(media.durationSeconds > 0, "Final movie duration is invalid")
            try require(report.audioTrackPresent && report.decodedFrameCount > 0, "\(fixture.name): source inspector lost samples")
            // A reader may omit the empty edit (first PTS is the audio offset)
            // or render it as leading PCM silence (first PTS is near zero).
            // Both are valid only if the WAV's actual signal stays at the same
            // absolute movie time; validate() tests that independently below.
            let signalDuration = Double(fixture.seconds)
            let renderedDuration = signalDuration + fixture.offset
            try require(min(abs(report.durationSeconds - signalDuration),
                            abs(report.durationSeconds - renderedDuration)) < fixture.timingTolerance,
                        "\(fixture.name): decoded audio duration \(report.durationSeconds), frames \(report.decodedFrameCount), track span \(report.trackSpanDurationSeconds)")
            try require(abs(report.durationSeconds - Double(report.decodedFrameCount) / Double(sampleRate)) <= 1.0 / Double(sampleRate),
                        "\(fixture.name): reported duration disagrees with actual decoded frames")
            try require(abs(report.trackSpanDurationSeconds - CMTimeGetSeconds(audio.timeRange.duration)) <= 1.0 / Double(sampleRate),
                        "\(fixture.name): source track span was not preserved separately")
            if fixture.offset > 0 {
                let movieDuration = CMTimeGetSeconds(asset.duration)
                try require(abs(movieDuration - Double(fixture.seconds) - fixture.offset) <= fixture.timingTolerance,
                            "\(fixture.name): delayed fixture movie does not include its initial empty edit")
                try require(report.durationSeconds <= movieDuration + fixture.timingTolerance,
                            "\(fixture.name): decoded duration exceeds the movie timeline")
            }
            try require(report.rmsDBFS.isFinite && report.peakDBFS.isFinite, "inspection produced non-finite decibels")
            // Exact digital silence is represented by finite -120 dBFS values,
            // so the diagnostic can be safely encoded into JSON.
            _ = try JSONEncoder().encode(report)
            if fixture.amplitude == 0 {
                try require(report.suspectedSilence && report.rmsDBFS < -70, "silent source was not reported as low signal")
            } else {
                try require(!report.suspectedSilence && report.rmsDBFS > -16 && report.rmsDBFS < -9,
                            "\(fixture.name): source tone level was not preserved")
            }
            let checkedPlayback = fixture.name == "44100-short" || fixture.name == "48000-short"
            if checkedPlayback {
                try verifyPlayback(source)
                passedChecks.append(fixture.name + ": local AVPlayerItem readyToPlay, muted, never started")
            }
            let chunks = try extract(source, directory: output).get()
            let detectedSignalStart = try validate(chunks, fixture: fixture, directory: output)
            try require(try digest(source) == originalDigest, "\(fixture.name): source MOV was modified")

            // Retry a long movie to exercise both a completed full-sized chunk
            // and a final short chunk, alongside a crash-leftover sentinel.
            if fixture.name == "48000-long" {
                let digests = try chunks.map { try digest(output.appendingPathComponent($0.relativePath)) }
                let abandoned = output.appendingPathComponent("extraction-interrupted", isDirectory: true)
                try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
                let partial = abandoned.appendingPathComponent("chunk-0000.wav")
                let sentinel = Data("preserved partial audio sentinel".utf8)
                try sentinel.write(to: partial, options: .withoutOverwriting)
                let retry = try extract(source, directory: output).get()
                _ = try validate(retry, fixture: fixture, directory: output)
                try require(Set(chunks.map(\.relativePath)).isDisjoint(with: Set(retry.map(\.relativePath))),
                            "retry overwrote an existing extraction path")
                for (chunk, expected) in zip(chunks, digests) {
                    try require(try digest(output.appendingPathComponent(chunk.relativePath)) == expected,
                                "retry modified a completed WAV")
                }
                try require(try Data(contentsOf: partial) == sentinel, "retry modified an interrupted WAV")
                try require(try digest(source) == originalDigest, "retry modified the original MOV")
                passedChecks.append("48000-long: unique retry paths; original MOV, completed WAVs and interrupted file unchanged")
            }
            fixtureResults.append(FixtureResult(name: fixture.name, sourceCodec: "AAC",
                sourceSampleRateHz: fixture.rate, sourceDurationSeconds: report.durationSeconds,
                sourceTrackSpanDurationSeconds: report.trackSpanDurationSeconds,
                sourceDecodedFrames: report.decodedFrameCount, rmsDBFS: report.rmsDBFS,
                peakDBFS: report.peakDBFS, suspectedSilence: report.suspectedSilence,
                chunkDurationsSeconds: chunks.map(\.durationSeconds),
                chunkStartSeconds: chunks.map(\.startSeconds), detectedSignalStartSeconds: detectedSignalStart,
                playbackReadyChecked: checkedPlayback))
            passedChecks.append(fixture.name + ": MOV/WAV inspection, PCM16 mono 16 kHz format, duration and timeline, "
                + (fixture.amplitude == 0 ? "soft silence warning" : "absolute signal onset, quiet leading interval, RMS/peak and 1 kHz tone correlation")
                + ", unchanged source")
        }

        private func validate(_ chunks: [AudioChunk], fixture: Fixture, directory: URL) throws -> Double? {
            let expectedCount = fixture.seconds > 180 ? 2 : 1
            try require(chunks.count == expectedCount, "\(fixture.name): expected \(expectedCount) chunks, got \(chunks.count)")
            let frameTolerance = 1.0 / Double(sampleRate)
            var duration = 0.0
            var detectedSignalStart: Double?
            for (index, chunk) in chunks.enumerated() {
                try checkDeadline()
                try require(chunk.index == index && chunk.startSeconds.isFinite && chunk.startSeconds >= 0 && chunk.durationSeconds.isFinite,
                            "invalid chunk metadata")
                try require(chunk.durationSeconds > 0 && chunk.durationSeconds <= 180, "chunk exceeds the 180-second boundary")
                try require(!chunk.relativePath.hasPrefix("/") && !chunk.relativePath.split(separator: "/").contains(".."),
                            "chunk path is not safely relative")
                if index == 0 {
                    try require(min(abs(chunk.startSeconds), abs(chunk.startSeconds - fixture.offset)) <= fixture.timingTolerance,
                                "\(fixture.name): first chunk \(chunk.startSeconds) is neither full-span nor offset-trimmed PCM")
                } else {
                    let previous = chunks[index - 1]
                    try require(abs(chunk.startSeconds - previous.startSeconds - previous.durationSeconds) <= frameTolerance,
                                "\(fixture.name): gap or overlap between WAV chunks")
                }
                if index < chunks.count - 1 {
                    try require(abs(chunk.durationSeconds - 180) <= frameTolerance, "full chunk does not end at 180 seconds")
                }
                let url = directory.appendingPathComponent(chunk.relativePath)
                // Only one <=5.76 MB WAV is resident; the source and the whole
                // long recording are never accumulated in an in-memory array.
                try autoreleasepool {
                    let wav = try Data(contentsOf: url, options: .mappedIfSafe)
                    let parsed = try ASRWAVAudio(wav: wav)
                    try parsed.validateForRequest()
                    try require(abs(parsed.durationSeconds - chunk.durationSeconds) <= frameTolerance,
                                "PCM sample count disagrees with chunk metadata")
                    let inspection = try AudioInspector.inspect(movieURL: url)
                    try require(inspection.decodedFrameCount == Int64(parsed.frameCount),
                                "WAV inspector sample count disagrees with the WAV header")
                    try require(abs(inspection.durationSeconds - parsed.durationSeconds) <= frameTolerance,
                                "WAV inspection duration disagrees with PCM sample count")
                    try require(abs(inspection.trackSpanDurationSeconds - parsed.durationSeconds) <= frameTolerance,
                                "WAV track span disagrees with PCM sample count")
                    if fixture.amplitude == 0 {
                        try require(inspection.suspectedSilence && inspection.rmsDBFS < -70,
                                    "silent WAV should succeed with a soft amplitude warning")
                    } else {
                        try require(!inspection.suspectedSilence, "non-silent WAV falsely flagged as silence")
                        if index == 0 {
                            detectedSignalStart = try validateSignalOnset(parsed, chunk: chunk, fixture: fixture)
                        }
                        let leadingFrames = max(0, Int(((fixture.offset - chunk.startSeconds) * Double(sampleRate)).rounded()))
                        try validateTone(parsed, name: fixture.name, leadingFrames: leadingFrames)
                    }
                }
                duration += chunk.durationSeconds
            }
            let endTime = chunks[0].startSeconds + duration
            let expectedEnd = fixture.offset + Double(fixture.seconds)
            try require(abs(endTime - expectedEnd) <= fixture.timingTolerance,
                        "\(fixture.name): WAV timeline ends at \(endTime), expected \(expectedEnd)")
            return detectedSignalStart
        }

        /// Measure actual PCM energy on the original movie timeline, so merely
        /// allowing both legal empty-edit representations cannot hide a shift.
        /// The 30 ms onset tolerance is much smaller than the 375 ms delay and
        /// accommodates AAC attack/transients and the 10 ms measurement window.
        private func validateSignalOnset(_ audio: ASRWAVAudio, chunk: AudioChunk, fixture: Fixture) throws -> Double {
            func value(at frame: Int) -> Double {
                let offset = audio.pcmRange.lowerBound + frame * 2
                let bits = UInt16(audio.wav[offset]) | UInt16(audio.wav[offset + 1]) << 8
                return Double(Int16(bitPattern: bits)) / 32_768.0
            }
            let leadingSeconds = max(0, fixture.offset - chunk.startSeconds)
            // Ignore 50 ms immediately before the attack to avoid interpreting
            // codec pre-ringing as an alignment error in known digital silence.
            let quietFrames = min(audio.frameCount, max(0, Int((leadingSeconds - 0.05) * Double(sampleRate))))
            if quietFrames > 0 {
                var squares = 0.0
                var peak = 0.0
                for frame in 0..<quietFrames {
                    let sample = value(at: frame)
                    squares += sample * sample
                    peak = max(peak, abs(sample))
                }
                let rms = sqrt(squares / Double(quietFrames))
                try require(rms < 0.002 && peak < 0.01,
                            "\(fixture.name): signal appeared before its intended movie offset (leading RMS \(rms), peak \(peak))")
            }
            let windowFrames = sampleRate / 100
            let limit = min(audio.frameCount, Int((leadingSeconds + 0.5) * Double(sampleRate)))
            var consecutive = 0
            for first in stride(from: 0, through: limit - windowFrames, by: windowFrames) {
                var squares = 0.0
                for frame in first..<(first + windowFrames) {
                    let sample = value(at: frame)
                    squares += sample * sample
                }
                let rms = sqrt(squares / Double(windowFrames))
                consecutive = rms >= 0.08 ? consecutive + 1 : 0
                if consecutive == 3 {
                    let onset = chunk.startSeconds + Double(first - 2 * windowFrames) / Double(sampleRate)
                    try require(abs(onset - fixture.offset) <= 0.03,
                                "\(fixture.name): actual signal onset \(onset), expected movie time \(fixture.offset)")
                    return onset
                }
            }
            throw TestFailure(message: "\(fixture.name): no sustained tone near the expected movie offset")
        }

        private func validateTone(_ audio: ASRWAVAudio, name: String, leadingFrames: Int) throws {
            // Skip only the fixture's known leading silence and AAC start/end
            // transients. A phase-independent sine/cosine
            // projection detects wrong resampling, zero-filled output, noise and
            // frequency changes without depending on lossy AAC bit identity.
            let trim = 1_280
            let startFrame = leadingFrames + trim
            let count = min(32_000, audio.frameCount - startFrame - trim)
            try require(count > 4_000, "\(name): too few tone samples")
            var squares = 0.0
            var peak = 0.0
            var sine = 0.0
            var cosine = 0.0
            for index in 0..<count {
                let offset = audio.pcmRange.lowerBound + (startFrame + index) * 2
                let bits = UInt16(audio.wav[offset]) | UInt16(audio.wav[offset + 1]) << 8
                let value = Double(Int16(bitPattern: bits)) / 32_768.0
                let angle = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
                squares += value * value
                peak = max(peak, abs(value))
                sine += value * sin(angle)
                cosine += value * cos(angle)
            }
            let rms = sqrt(squares / Double(count))
            let toneFraction = 2 * (sine * sine + cosine * cosine) / (Double(count) * squares)
            try require(rms > 0.18 && rms < 0.30 && peak > 0.28 && peak < 0.45,
                        "\(name): non-silent tone amplitude not preserved (RMS \(rms), peak \(peak))")
            try require(toneFraction.isFinite && toneFraction > 0.95,
                        "\(name): 1 kHz correlation failed (\(toneFraction)); check resampling")
        }

        private func checkRejectedSource(_ source: URL, directory: URL) throws {
            let original = try digest(source)
            var rejected = false
            do { _ = try AudioInspector.inspect(movieURL: source) }
            catch is AudioInspector.InspectionError { rejected = true }
            try require(rejected, "\(source.lastPathComponent): invalid source passed local inspection")
            let output = directory.appendingPathComponent(source.lastPathComponent + "-rejected", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let sentinelURL = output.appendingPathComponent("preserve-existing.wav")
            let sentinel = Data("preserve files after failed extraction".utf8)
            try sentinel.write(to: sentinelURL, options: .withoutOverwriting)
            switch try extract(source, directory: output) {
            case .success: throw TestFailure(message: "\(source.lastPathComponent): invalid source was extracted successfully")
            case .failure(let error):
                guard let failure = error as? AudioChunker.ChunkingError else {
                    throw TestFailure(message: "failed extraction did not return its preservation report")
                }
                try require(failure.preservedChunks.isEmpty, "invalid source produced supposedly valid chunks")
            }
            try require(try digest(source) == original, "failed extraction changed its source")
            try require(try Data(contentsOf: sentinelURL) == sentinel, "failed extraction deleted existing audio")
            passedChecks.append(source.lastPathComponent + ": inspection/extraction rejected; source and existing audio preserved")
        }

        private func writeTestReport(to directory: URL, status: String, failure: String?) throws {
            let report = SmokeReport(status: status, fixtures: fixtureResults, passedChecks: passedChecks, failure: failure)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        }

        /// Preparing a muted, paused player verifies local playback readiness
        /// independently of AVAssetReader. This does not assert audible speakers.
        private func verifyPlayback(_ source: URL) throws {
            let signal = DispatchSemaphore(value: 0)
            var result: Result<Void, Error>?
            let readyDeadline = min(deadline.uptimeNanoseconds,
                                    (DispatchTime.now() + 20).uptimeNanoseconds)
            DispatchQueue.main.async {
                let player = AVPlayer(url: source)
                player.isMuted = true
                func poll() {
                    let status = player.currentItem?.status ?? .failed
                    if status == .readyToPlay {
                        player.replaceCurrentItem(with: nil)
                        result = .success(())
                        signal.signal()
                    } else if status == .failed || DispatchTime.now().uptimeNanoseconds >= readyDeadline {
                        player.replaceCurrentItem(with: nil)
                        result = .failure(TestFailure(message: "local AVPlayerItem did not become readyToPlay within 20 seconds"))
                        signal.signal()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { poll() }
                    }
                }
                poll()
            }
            guard signal.wait(timeout: deadline) == .success, let result = result else {
                throw TestFailure(message: "timed out waiting for local playback readiness")
            }
            try result.get()
        }

        /// Blocks only this private test queue; production completion must reach
        /// the main queue, which remains free for the app's command-line runner.
        private func extract(_ source: URL, directory: URL) throws -> Result<[AudioChunk], Error> {
            try checkDeadline()
            let signal = DispatchSemaphore(value: 0)
            var result: Result<[AudioChunk], Error>?
            chunker.chunk(movieURL: source, directory: directory) { value in
                result = Thread.isMainThread ? value : .failure(TestFailure(message: "chunk completion was not on main"))
                signal.signal()
            }
            guard signal.wait(timeout: deadline) == .success, let result = result else {
                throw TestFailure(message: "timed out waiting for audio extraction")
            }
            return result
        }

        /// Each MOV has a tiny native H.264 track. Audio is PCM16 generated in
        /// 4096-frame blocks and encoded by AVAssetWriter as 44.1/48 kHz AAC.
        /// Starting video at zero makes the delayed-audio timeline unambiguous.
        private func writeMovie(to url: URL, fixture: Fixture?) throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 32,
                AVVideoHeightKey: 32
            ])
            video.expectsMediaDataInRealTime = false
            try require(writer.canAdd(video), "native writer rejected the video fixture input")
            writer.add(video)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 32,
                    kCVPixelBufferHeightKey as String: 32
                ])
            var audioInput: AVAssetWriterInput?
            var audioFormat: CMAudioFormatDescription?
            if let fixture = fixture {
                var format = AudioStreamBasicDescription(mSampleRate: Double(fixture.rate),
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                    mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
                let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
                    layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                    extensions: nil, formatDescriptionOut: &audioFormat)
                try require(status == noErr && audioFormat != nil, "could not describe native PCM fixture")
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Double(fixture.rate),
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ], sourceFormatHint: audioFormat)
                input.expectsMediaDataInRealTime = false
                try require(writer.canAdd(input), "native writer rejected AAC fixture input")
                writer.add(input)
                audioInput = input
            }
            guard writer.startWriting() else { throw TestFailure(message: "native writer could not start") }
            defer { if writer.status == .writing { writer.cancelWriting() } }
            writer.startSession(atSourceTime: .zero)

            var pixel: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
                                           nil, &pixel) == kCVReturnSuccess, "could not create fixture video frame")
            guard let pixel = pixel else { throw TestFailure(message: "missing fixture video frame") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let address = CVPixelBufferGetBaseAddress(pixel) {
                memset(address, 0, CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            for index in 0..<2 {
                try waitUntilReady(video, writer: writer)
                try require(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)),
                            "could not append fixture video")
            }
            video.markAsFinished()

            if let fixture = fixture, let input = audioInput, let format = audioFormat {
                let totalFrames = Int(fixture.rate) * fixture.seconds
                let offsetFrames = Int64((fixture.offset * Double(fixture.rate)).rounded())
                var cursor = 0
                while cursor < totalFrames {
                    try checkDeadline()
                    try waitUntilReady(input, writer: writer)
                    let count = min(4_096, totalFrames - cursor)
                    try autoreleasepool {
                        var pcm = [Int16](repeating: 0, count: count)
                        for index in 0..<count {
                            let phase = 2 * Double.pi * frequency * Double(cursor + index) / Double(fixture.rate)
                            pcm[index] = Int16((fixture.amplitude * sin(phase) * 32_767).rounded()).littleEndian
                        }
                        var block: CMBlockBuffer?
                        let byteCount = count * MemoryLayout<Int16>.size
                        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                            memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                            flags: 0, blockBufferOut: &block)
                        try require(blockStatus == kCMBlockBufferNoErr && block != nil, "could not allocate PCM fixture block")
                        guard let block = block else { throw TestFailure(message: "missing PCM fixture block") }
                        let copyStatus = pcm.withUnsafeBytes { bytes in
                            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                                          offsetIntoDestination: 0, dataLength: byteCount)
                        }
                        try require(copyStatus == kCMBlockBufferNoErr, "could not copy PCM fixture block")
                        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fixture.rate),
                            presentationTimeStamp: CMTime(value: offsetFrames + Int64(cursor), timescale: fixture.rate),
                            decodeTimeStamp: .invalid)
                        var size = 2
                        var sample: CMSampleBuffer?
                        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
                            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                            sampleBufferOut: &sample)
                        try require(sampleStatus == noErr && sample != nil, "could not create timed PCM fixture")
                        guard let sample = sample, input.append(sample) else {
                            throw TestFailure(message: "native AAC encoder rejected PCM fixture")
                        }
                    }
                    cursor += count
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(value: offsetFrames + Int64(totalFrames), timescale: fixture.rate))
            } else {
                writer.endSession(atSourceTime: CMTime(value: 2, timescale: 30))
            }
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            try require(done.wait(timeout: deadline) == .success, "timed out finalizing native fixture")
            try require(writer.status == .completed, "native writer failed to finalize fixture")
        }

        private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
            while !input.isReadyForMoreMediaData {
                try checkDeadline()
                try require(writer.status == .writing, "native fixture writer stopped before input was ready")
                Thread.sleep(forTimeInterval: 0.002)
            }
        }

        private func checkDeadline() throws {
            try require(DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds, "180-second integration deadline exceeded")
        }

        private func digest(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 64 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw TestFailure(message: message) }
        }

        private func finish(_ result: Result<String, Error>) {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { self.finish(result) }
                return
            }
            guard !finished else { return }
            finished = true
            watchdog?.cancel()
            watchdog = nil
            completion(result)
        }
    }
}
#endif
