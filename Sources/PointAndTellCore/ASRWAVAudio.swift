import Foundation

public struct ASRAudioChunk: Equatable {
    public let wav: Data
    public let offsetMilliseconds: Int
    public let durationMilliseconds: Int
}

/// Reads already-normalized audio. Conversion and source-media decoding belong to
/// the media layer, never to the provider request builder.
public struct ASRWAVAudio {
    public static let sampleRate = 16_000
    public static let bytesPerSecond = 32_000
    public static let recommendedChunkSeconds = 180
    public static let maximumDurationSeconds = 300
    public static let maximumEncodedBytes = 10_000_000
    public static let dataURIPrefix = "data:audio/wav;base64,"

    public let wav: Data
    public let pcmRange: Range<Int>
    public var frameCount: Int { pcmRange.count / 2 }
    public var durationSeconds: Double { Double(frameCount) / Double(Self.sampleRate) }

    public init(wav: Data) throws {
        // A fresh Data copy normalizes indices even when passed a Data subsequence.
        let bytes = Data(wav)
        guard bytes.count >= 44, Self.tag(bytes, 0) == "RIFF", Self.tag(bytes, 8) == "WAVE" else {
            throw ASRError.invalidWAV("The RIFF/WAVE header is missing.")
        }
        let riffEnd = Int(Self.u32(bytes, 4)) + 8
        guard riffEnd == bytes.count else { throw ASRError.invalidWAV("The RIFF length is inconsistent.") }
        var cursor = 12
        var hasFormat = false
        var audioRange: Range<Int>?
        while cursor < riffEnd {
            guard cursor + 8 <= riffEnd else { throw ASRError.invalidWAV("A chunk header is truncated.") }
            let name = Self.tag(bytes, cursor)
            let length = Int(Self.u32(bytes, cursor + 4))
            let start = cursor + 8
            guard length <= riffEnd - start else { throw ASRError.invalidWAV("A chunk is truncated.") }
            let end = start + length
            if name == "fmt " {
                guard !hasFormat, length >= 16,
                      Self.u16(bytes, start) == 1,
                      Self.u16(bytes, start + 2) == 1,
                      Self.u32(bytes, start + 4) == 16_000,
                      Self.u32(bytes, start + 8) == 32_000,
                      Self.u16(bytes, start + 12) == 2,
                      Self.u16(bytes, start + 14) == 16 else {
                    throw ASRError.invalidWAV("The audio format is not 16 kHz, 16-bit mono PCM.")
                }
                hasFormat = true
            } else if name == "data" {
                guard audioRange == nil, length > 0, length % 2 == 0 else {
                    throw ASRError.invalidWAV("The PCM data must contain complete 16-bit samples.")
                }
                audioRange = start..<end
            }
            cursor = end + (length % 2)
            guard cursor <= riffEnd else { throw ASRError.invalidWAV("A chunk padding byte is missing.") }
        }
        guard hasFormat, let pcmRange = audioRange else { throw ASRError.invalidWAV("A format or audio chunk is missing.") }
        self.wav = bytes
        self.pcmRange = pcmRange
    }

    public func validateForRequest() throws {
        guard frameCount <= Self.maximumDurationSeconds * Self.sampleRate else { throw ASRError.audioTooLong }
        // Check before Base64 allocation. Decimal MB and prefix inclusion are conservative.
        let encodedSize = ((wav.count + 2) / 3) * 4 + Self.dataURIPrefix.utf8.count
        guard encodedSize <= Self.maximumEncodedBytes else { throw ASRError.encodedAudioTooLarge }
    }

    /// Splits without resampling, gaps or overlap, preserving exact sample boundaries.
    public func chunks(seconds: Int = ASRWAVAudio.recommendedChunkSeconds) throws -> [ASRAudioChunk] {
        guard (1...Self.maximumDurationSeconds).contains(seconds) else { throw ASRError.audioTooLong }
        let bytesPerChunk = seconds * Self.bytesPerSecond
        var start = pcmRange.lowerBound
        var result: [ASRAudioChunk] = []
        while start < pcmRange.upperBound {
            let end = min(start + bytesPerChunk, pcmRange.upperBound)
            let output = Self.makeWAV(pcm: wav.subdata(in: start..<end))
            try Self(wav: output).validateForRequest()
            result.append(ASRAudioChunk(wav: output,
                                        offsetMilliseconds: (start - pcmRange.lowerBound) * 1_000 / Self.bytesPerSecond,
                                        durationMilliseconds: (end - start) * 1_000 / Self.bytesPerSecond))
            start = end
        }
        return result
    }

    private static func tag(_ data: Data, _ offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }
    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
    private static func makeWAV(pcm: Data) -> Data {
        var header = Data()
        func append16(_ value: UInt16) {
            header.append(UInt8(truncatingIfNeeded: value))
            header.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { header.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        header.append(contentsOf: "RIFF".utf8); append32(UInt32(pcm.count + 36))
        header.append(contentsOf: "WAVEfmt ".utf8); append32(16)
        append16(1); append16(1); append32(16_000); append32(32_000)
        append16(2); append16(16)
        header.append(contentsOf: "data".utf8); append32(UInt32(pcm.count)); header.append(pcm)
        return header
    }
}
