import XCTest
@testable import PointAndTellCore

final class ASRWAVAudioTests: XCTestCase {
    func testCanonicalPCMFormatAndDuration() throws {
        let audio = try ASRWAVAudio(wav: ASRFixtures.wav(seconds: 3))
        XCTAssertEqual(audio.frameCount, 48_000)
        XCTAssertEqual(audio.durationSeconds, 3)
        XCTAssertNoThrow(try audio.validateForRequest())
    }

    func testOddAncillaryChunkPaddingIsSupported() throws {
        let audio = try ASRWAVAudio(wav: ASRFixtures.wav(seconds: 1, extraMetadata: true))
        XCTAssertEqual(audio.frameCount, 16_000)
        XCTAssertEqual(audio.pcmRange.lowerBound, 56)
    }

    func testWrongFormatAndTruncationRejected() {
        let values = [Data("not audio".utf8), ASRFixtures.wav(seconds: 1, sampleRate: 44_100),
                      ASRFixtures.wav(seconds: 1, channels: 2), ASRFixtures.wav(seconds: 1, bitsPerSample: 8),
                      ASRFixtures.wav(seconds: 0), Data(ASRFixtures.tinyWAV.dropLast())]
        for data in values { XCTAssertThrowsError(try ASRWAVAudio(wav: data)) }
    }

    func testFiveMinuteDurationGuard() throws {
        let audio = try ASRWAVAudio(wav: ASRFixtures.wav(seconds: 301))
        XCTAssertThrowsError(try audio.validateForRequest()) { XCTAssertEqual($0 as? ASRError, .audioTooLong) }
    }

    func testBase64GuardCountsEncodedSizeRatherThanRawPCM() throws {
        let audio = try ASRWAVAudio(wav: ASRFixtures.wav(seconds: 240))
        XCTAssertLessThan(audio.wav.count, 10_000_000)
        XCTAssertThrowsError(try audio.validateForRequest()) { XCTAssertEqual($0 as? ASRError, .encodedAudioTooLarge) }
    }

    func testDefaultChunksAreThreeMinutesWithExactOffsets() throws {
        let original = try ASRWAVAudio(wav: ASRFixtures.wav(seconds: 365))
        let chunks = try original.chunks()
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.offsetMilliseconds), [0, 180_000, 360_000])
        XCTAssertEqual(chunks.map(\.durationMilliseconds), [180_000, 180_000, 5_000])
        var reconstructed = Data()
        for chunk in chunks {
            let audio = try ASRWAVAudio(wav: chunk.wav)
            XCTAssertNoThrow(try audio.validateForRequest())
            reconstructed.append(audio.wav.subdata(in: audio.pcmRange))
        }
        XCTAssertEqual(reconstructed, original.wav.subdata(in: original.pcmRange))
    }

    func testChunkingPreservesNonzeroSamplesAndFinalPartialSecond() throws {
        let sampleBytes = Data((0..<64_008).map { UInt8(truncatingIfNeeded: $0) })
        let audio = try ASRWAVAudio(wav: ASRFixtures.wav(pcm: sampleBytes))
        let chunks = try audio.chunks(seconds: 1)
        XCTAssertEqual(chunks.count, 3)
        var reconstructed = Data()
        for chunk in chunks {
            let parsed = try ASRWAVAudio(wav: chunk.wav)
            reconstructed.append(parsed.wav.subdata(in: parsed.pcmRange))
        }
        XCTAssertEqual(reconstructed, sampleBytes)
    }

    func testInvalidChunkSizeRejected() throws {
        let audio = try ASRWAVAudio(wav: ASRFixtures.tinyWAV)
        XCTAssertThrowsError(try audio.chunks(seconds: 0))
        XCTAssertThrowsError(try audio.chunks(seconds: 301))
    }
}
