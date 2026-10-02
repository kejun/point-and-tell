#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// Each WAV is mono signed 16-bit little-endian PCM at 16 kHz. startSeconds is
/// relative to the original MOV timeline, NOT the beginning of its audio track.
struct AudioChunk: Codable, Equatable {
    let index: Int
    /// Relative to the directory passed to AudioChunker.chunk, not the MOV.
    let relativePath: String
    let startSeconds: Double
    let durationSeconds: Double
}

/// Streams decoded samples to at most three-minute WAVs (~5.76 MB each). Neither
/// the complete movie nor a complete chunk is accumulated in memory. The movie
/// remains the source of truth and is never modified, even if extraction fails.
final class AudioChunker {
    struct ChunkingError: LocalizedError {
        let message: String
        let preservedChunks: [AudioChunk]
        let underlyingError: Error?
        var errorDescription: String? {
            let detail = underlyingError.map { " \($0.localizedDescription)" } ?? ""
            return message + detail + " The original recording and any already-written audio files have been preserved."
        }
    }

    private enum Failure: LocalizedError {
        case noAudio, cannotRead, invalidTimestamp, invalidPCM, fileExists(String), cannotCreate(String)
        var errorDescription: String? {
            switch self {
            case .noAudio: return "This movie contains no readable microphone audio."
            case .cannotRead: return "The microphone track could not be decoded."
            case .invalidTimestamp: return "The microphone track contains invalid timing information."
            case .invalidPCM: return "The decoder did not return 16 kHz, mono, 16-bit PCM audio."
            case .fileExists(let name): return "Audio output \(name) already exists. Choose an empty extraction directory."
            case .cannotCreate(let name): return "Audio output \(name) could not be created."
            }
        }
    }

    private let queue = DispatchQueue(label: "PointAndTell.AudioChunker", qos: .utility)
    static let sampleRate = 16_000
    static let maximumChunkSeconds = 180

    /// Completion runs on main. Calls on the same object are serialized. Each
    /// attempt writes to a fresh subdirectory, so a retry safely regenerates the
    /// WAVs without overwriting completed or crash-interrupted earlier attempts.
    /// Returned paths include that subdirectory and remain relative to directory.
    func chunk(movieURL: URL, directory: URL,
               completion: @escaping (Result<[AudioChunk], Error>) -> Void) {
        queue.async {
            let result: Result<[AudioChunk], Error>
            do { result = .success(try self.extract(movieURL: movieURL, directory: directory)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func extract(movieURL: URL, directory: URL) throws -> [AudioChunk] {
        let attemptName = "extraction-" + UUID().uuidString.lowercased()
        let attemptDirectory = directory.appendingPathComponent(attemptName, isDirectory: true)
        let sink = try ChunkSink(directory: attemptDirectory, relativePrefix: attemptName)
        var reader: AVAssetReader?
        do {
            let asset = AVURLAsset(url: movieURL)
            guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure.noAudio }
            let assetReader = try AVAssetReader(asset: asset)
            reader = assetReader
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard assetReader.canAdd(output) else { throw Failure.cannotRead }
            assetReader.add(output)
            guard assetReader.startReading() else { throw assetReader.error ?? Failure.cannotRead }
            while assetReader.status == .reading {
                // Prevent Objective-C decoder temporaries from collecting over
                // multi-hour recordings. Only one CMSampleBuffer is retained.
                let consumed: Bool = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    try self.consume(sample, sink: sink)
                    return true
                }
                if !consumed { break }
            }
            guard assetReader.status == .completed else { throw assetReader.error ?? Failure.cannotRead }
            try sink.finish()
            guard !sink.chunks.isEmpty else { throw Failure.noAudio }
            return sink.chunks
        } catch {
            reader?.cancelReading()
            // A current WAV has a checkpointed header. Best-effort finalization
            // keeps all successfully written samples useful after an I/O error.
            try? sink.finish()
            throw ChunkingError(message: "Audio extraction did not finish.",
                                preservedChunks: sink.chunks, underlyingError: error)
        }
    }

    private func consume(_ sample: CMSampleBuffer, sink: ChunkSink) throws {
        guard CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              abs(format.mSampleRate - Double(Self.sampleRate)) < 0.01,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
              format.mBytesPerFrame == 2,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0,
              (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0,
              let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.invalidPCM }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = CMTimeGetSeconds(pts)
        guard seconds.isFinite, abs(seconds) < Double(Int64.max / Int64(Self.sampleRate)) else {
            throw Failure.invalidTimestamp
        }
        let startFrame = Int64((seconds * Double(Self.sampleRate)).rounded())
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount % 2 == 0 else { throw Failure.invalidPCM }
        let frames = Int64(byteCount / 2)
        guard frames > 0 else { return }
        // AssetReader supplies presentation timestamps on the movie timeline.
        // Preserve the microphone's initial offset in metadata. Insert bounded
        // silence for later timestamp gaps; trim overlaps instead of shifting
        // every later word and visual anchor.
        let trimFrames = try sink.align(to: startFrame, frames: frames)
        var byteOffset = Int(trimFrames * 2)
        while byteOffset < byteCount {
            let length = min(64 * 1_024, byteCount - byteOffset)
            var data = Data(count: length)
            let status: OSStatus = data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return OSStatus(-1) }
                return CMBlockBufferCopyDataBytes(block, atOffset: byteOffset, dataLength: length, destination: base)
            }
            guard status == kCMBlockBufferNoErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: "Could not copy decoded microphone samples."])
            }
            try sink.append(data)
            byteOffset += length
        }
        try sink.checkpoint()
    }

    private final class ChunkSink {
        let directory: URL
        private let relativePrefix: String
        private(set) var chunks: [AudioChunk] = []
        private var file: FileHandle?
        private var fileURL: URL?
        private var chunkStartFrame: Int64 = 0
        private var chunkFrames: Int64 = 0
        private var timelineFrame: Int64?
        private let maxFrames = Int64(AudioChunker.sampleRate * AudioChunker.maximumChunkSeconds)
        private let silence = Data(count: 64 * 1_024)

        init(directory: URL, relativePrefix: String) throws {
            self.directory = directory
            self.relativePrefix = relativePrefix
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw Failure.fileExists(directory.lastPathComponent)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit { try? file?.close() }

        /// Returns leading source frames to skip (negative priming / overlaps).
        func align(to start: Int64, frames: Int64) throws -> Int64 {
            if timelineFrame == nil { timelineFrame = max(0, start) }
            let cursor = timelineFrame ?? 0
            if start < cursor { return min(frames, cursor - start) }
            var gapFrames = start - cursor
            while gapFrames > 0 {
                let count = Int(min(gapFrames, Int64(silence.count / 2)))
                try append(silence.prefix(count * 2))
                gapFrames -= Int64(count)
            }
            return 0
        }

        func append(_ data: Data) throws {
            guard data.count % 2 == 0 else { throw Failure.invalidPCM }
            var offset = 0
            while offset < data.count {
                if file == nil { try openChunk() }
                let frameCount = min(Int64((data.count - offset) / 2), maxFrames - chunkFrames)
                let count = Int(frameCount * 2)
                guard let file = file else { throw Failure.cannotCreate("WAV") }
                // Each write is at most 64 KiB. A disk error throws here and the
                // caller retains the source MOV and previously completed WAVs.
                try file.write(contentsOf: data.subdata(in: offset..<(offset + count)))
                chunkFrames += frameCount
                timelineFrame = (timelineFrame ?? 0) + frameCount
                offset += count
                if chunkFrames == maxFrames { try finishChunk() }
            }
        }

        func checkpoint() throws {
            guard let file = file else { return }
            try file.seek(toOffset: 0)
            try file.write(contentsOf: Self.wavHeader(dataBytes: UInt32(chunkFrames * 2)))
            try file.seek(toOffset: 44 + UInt64(chunkFrames * 2))
        }

        func finish() throws { if file != nil { try finishChunk() } }

        private func openChunk() throws {
            let name = String(format: "chunk-%04d.wav", chunks.count)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.fileExists(name) }
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure.cannotCreate(name) }
            let handle = try FileHandle(forWritingTo: url)
            file = handle
            fileURL = url
            chunkFrames = 0
            chunkStartFrame = timelineFrame ?? 0
            try handle.write(contentsOf: Self.wavHeader(dataBytes: 0))
        }

        private func finishChunk() throws {
            guard let handle = file, let url = fileURL else { return }
            try checkpoint()
            try handle.synchronize()
            try handle.close()
            file = nil
            fileURL = nil
            if chunkFrames > 0 {
                chunks.append(AudioChunk(index: chunks.count, relativePath: relativePrefix + "/" + url.lastPathComponent,
                                         startSeconds: Double(chunkStartFrame) / Double(AudioChunker.sampleRate),
                                         durationSeconds: Double(chunkFrames) / Double(AudioChunker.sampleRate)))
            }
        }

        private static func wavHeader(dataBytes: UInt32) -> Data {
            var data = Data()
            func text(_ value: String) { data.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            func u32(_ value: UInt32) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            text("RIFF"); u32(36 + dataBytes); text("WAVE")
            text("fmt "); u32(16); u16(1); u16(1)
            u32(UInt32(AudioChunker.sampleRate)); u32(UInt32(AudioChunker.sampleRate * 2))
            u16(2); u16(16); text("data"); u32(dataBytes)
            return data
        }
    }
}

#endif
