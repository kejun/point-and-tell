#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia

/// A local amplitude probe, not a voice/speech detector. A quiet recording can
/// still contain useful speech, so suspectedSilence must never be a hard error.
struct AudioInspectionReport: Codable, Equatable {
    let audioTrackPresent: Bool
    /// Duration represented by decoded PCM frames. AVAssetReader may render
    /// empty timeline edits as silent frames; those frames count here too.
    let durationSeconds: Double
    /// Container track span, which can differ from the decoded sample duration.
    let trackSpanDurationSeconds: Double
    let decodedFrameCount: Int64
    let rmsDBFS: Double
    let peakDBFS: Double
    let suspectedSilence: Bool

    /// Contains no source path, decoder text, media bytes, or provider data.
    var safeSummary: String {
        let levels = String(format: "%.2f s decoded, %lld frames, RMS %.1f dBFS, peak %.1f dBFS",
                            durationSeconds, decodedFrameCount, rmsDBFS, peakDBFS)
        return levels + (suspectedSilence ? "; very low signal (amplitude only, not speech detection)" : "")
    }
}

enum AudioInspector {
    enum InspectionError: LocalizedError {
        case noAudioTrack, invalidDuration, noDecodedSamples, invalidSamples
        case decodeFailed(Int)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "Local audio validation failed: no readable audio track was found."
            case .invalidDuration: return "Local audio validation failed: the audio track has an invalid duration."
            case .noDecodedSamples: return "Local audio validation failed: the audio track contains no decoded samples."
            case .invalidSamples: return "Local audio validation failed: invalid decoded audio samples."
            case .decodeFailed(let code):
                return "Local audio validation failed: the audio track could not be decoded (code \(code))."
            }
        }
    }

    static let sampleRate = 16_000
    static let silenceThresholdDBFS = -60.0
    private static let minimumDBFS = -120.0

    /// Synchronous; call on a background queue. Reads MOV/AAC and WAV using the
    /// same 16 kHz mono PCM format as transcription. Never modifies the source.
    /// Decodes the entire track while retaining only one decoder sample buffer
    /// and a reusable 64 KiB copy buffer, irrespective of recording length.
    static func inspect(movieURL: URL) throws -> AudioInspectionReport {
        let asset = AVURLAsset(url: movieURL)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw InspectionError.noAudioTrack
        }
        // AVAssetWriter can put an initial empty edit inside this time range:
        // a 2 s signal starting at movie time 0.375 s can have a 2.375 s span.
        // The reader can render that empty edit as PCM silence. Always report
        // the frames actually decoded instead of guessing from track metadata.
        let trackSpanDuration = CMTimeGetSeconds(track.timeRange.duration)
        guard trackSpanDuration.isFinite, trackSpanDuration >= 0 else { throw InspectionError.invalidDuration }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw InspectionError.decodeFailed((error as NSError).code) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw InspectionError.decodeFailed(0) }
        reader.add(output)
        defer { if reader.status == .reading { reader.cancelReading() } }
        guard reader.startReading() else { throw InspectionError.decodeFailed(reader.error.map { ($0 as NSError).code } ?? 0) }

        var frameCount: Int64 = 0
        var sumSquares = 0.0
        var peak = 0.0
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)
        while reader.status == .reading {
            let consumed: Bool = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard CMSampleBufferDataIsReady(sample),
                      let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mFormatID == kAudioFormatLinearPCM,
                      abs(format.mSampleRate - Double(sampleRate)) < 0.01,
                      format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
                      format.mBytesPerFrame == 2,
                      (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0,
                      (format.mFormatFlags & kAudioFormatFlagIsFloat) == 0,
                      (format.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0,
                      let block = CMSampleBufferGetDataBuffer(sample) else { throw InspectionError.invalidSamples }
                let bytes = CMBlockBufferGetDataLength(block)
                let samples = CMSampleBufferGetNumSamples(sample)
                guard samples > 0, bytes > 0, bytes % 2 == 0, bytes / 2 == samples,
                      frameCount <= Int64.max - Int64(samples) else { throw InspectionError.invalidSamples }
                var offset = 0
                while offset < bytes {
                    let count = min(scratch.count, bytes - offset)
                    let status = scratch.withUnsafeMutableBytes { raw in
                        CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: count,
                                                   destination: raw.baseAddress!)
                    }
                    guard status == kCMBlockBufferNoErr else { throw InspectionError.invalidSamples }
                    for index in stride(from: 0, to: count, by: 2) {
                        let bits = UInt16(scratch[index]) | UInt16(scratch[index + 1]) << 8
                        let value = Double(Int16(bitPattern: bits)) / 32_768.0
                        sumSquares += value * value
                        peak = max(peak, abs(value))
                    }
                    offset += count
                }
                frameCount += Int64(samples)
                return true
            }
            if !consumed { break }
        }
        guard reader.status == .completed else { throw InspectionError.decodeFailed(reader.error.map { ($0 as NSError).code } ?? 0) }
        guard frameCount > 0, trackSpanDuration > 0 else { throw InspectionError.noDecodedSamples }
        let decodedDuration = Double(frameCount) / Double(sampleRate)
        let rms = sqrt(sumSquares / Double(frameCount))
        let rmsDBFS = rms > 0 ? max(minimumDBFS, 20 * log10(rms)) : minimumDBFS
        let peakDBFS = peak > 0 ? max(minimumDBFS, 20 * log10(peak)) : minimumDBFS
        return AudioInspectionReport(audioTrackPresent: true, durationSeconds: decodedDuration,
                                     trackSpanDurationSeconds: trackSpanDuration,
                                     decodedFrameCount: frameCount, rmsDBFS: rmsDBFS,
                                     peakDBFS: peakDBFS, suspectedSilence: rmsDBFS < silenceThresholdDBFS)
    }
}
#endif
