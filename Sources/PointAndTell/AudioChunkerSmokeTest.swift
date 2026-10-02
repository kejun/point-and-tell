#if os(macOS)
import Foundation
import CryptoKit
import PointAndTellCore

/// Deterministic AVFoundation decoder + WAV writer integration test. Requires a
/// running main run loop because the production chunker completes on main. No
/// microphone, screen, network request, or provider credential is involved.
enum AudioChunkerSmokeTest {
    static func run(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
        Runner(directory: directory, completion: completion).start()
    }

    private struct TestFailure: LocalizedError {
        let message: String
        var errorDescription: String? { "Audio chunker smoke test: " + message }
    }

    private final class Runner {
        private let baseDirectory: URL
        private let completion: (Result<String, Error>) -> Void
        private let work = DispatchQueue(label: "PointAndTell.AudioChunkerSmokeTest", qos: .utility)
        private let chunker = AudioChunker()
        private var watchdog: DispatchWorkItem?
        // Only touched by finish, on main.
        private var finished = false
        private let sampleRate = 16_000
        private let fixtureSeconds = 181

        init(directory: URL, completion: @escaping (Result<String, Error>) -> Void) {
            baseDirectory = directory
            self.completion = completion
        }

        func start() {
            let timeout = DispatchWorkItem { [weak self] in
                self?.finish(.failure(TestFailure(message: "timed out after 60 seconds; the main run loop must be running.")))
            }
            watchdog = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
            work.async {
                do {
                    let runDirectory = self.baseDirectory.appendingPathComponent("smoke-" + UUID().uuidString.lowercased(), isDirectory: true)
                    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                    let input = runDirectory.appendingPathComponent("181-second-source.wav")
                    let output = runDirectory.appendingPathComponent("audio", isDirectory: true)
                    try self.writeFixture(to: input)
                    let originalDigest = try self.digest(input)
                    self.chunker.chunk(movieURL: input, directory: output) { firstResult in
                        guard Thread.isMainThread else {
                            self.finish(.failure(TestFailure(message: "chunk completion was not delivered on main.")))
                            return
                        }
                        self.work.async {
                            do {
                                let first = try firstResult.get()
                                try self.validate(first, directory: output)
                                let originalChunks = try first.map { try self.digest(output.appendingPathComponent($0.relativePath)) }
                                // Simulate leftovers from an interrupted older
                                // extraction. A retry must not touch this file.
                                let partial = output.appendingPathComponent("interrupted-older-attempt.wav")
                                let sentinel = Data("preserved partial audio sentinel".utf8)
                                try sentinel.write(to: partial, options: .withoutOverwriting)
                                self.chunker.chunk(movieURL: input, directory: output) { retryResult in
                                    guard Thread.isMainThread else {
                                        self.finish(.failure(TestFailure(message: "retry completion was not delivered on main.")))
                                        return
                                    }
                                    self.work.async {
                                        do {
                                            let retry = try retryResult.get()
                                            try self.validate(retry, directory: output)
                                            let oldPaths = Set(first.map(\.relativePath))
                                            let newPaths = Set(retry.map(\.relativePath))
                                            try self.require(oldPaths.isDisjoint(with: newPaths), "retry reused an existing output path")
                                            for (chunk, expectedDigest) in zip(first, originalChunks) {
                                                try self.require(try self.digest(output.appendingPathComponent(chunk.relativePath)) == expectedDigest,
                                                                 "retry modified a completed WAV")
                                            }
                                            try self.require(try Data(contentsOf: partial) == sentinel, "retry modified a partial older file")
                                            try self.require(try self.digest(input) == originalDigest, "extraction modified the source WAV")
                                            self.finish(.success("PASS: AVFoundation decoded a streamed 181-second PCM fixture into 180-second + 1-second WAVs; sample counts, movie-relative offsets, main-queue callbacks, request validation, and non-destructive retry all passed. Fixtures: \(runDirectory.path)"))
                                        } catch { self.finish(.failure(error)) }
                                    }
                                }
                            } catch { self.finish(.failure(error)) }
                        }
                    }
                } catch { self.finish(.failure(error)) }
            }
        }

        private func validate(_ chunks: [AudioChunk], directory: URL) throws {
            try require(chunks.count == 2, "expected two chunks, got \(chunks.count)")
            let expectedSeconds = [180.0, 1.0]
            let expectedStarts = [0.0, 180.0]
            let tolerance = 1.0 / Double(sampleRate)
            for (index, chunk) in chunks.enumerated() {
                try require(chunk.index == index, "chunk index is out of sequence")
                try require(chunk.startSeconds.isFinite && abs(chunk.startSeconds - expectedStarts[index]) <= tolerance,
                            "chunk \(index) starts at \(chunk.startSeconds), expected \(expectedStarts[index])")
                try require(chunk.durationSeconds.isFinite && abs(chunk.durationSeconds - expectedSeconds[index]) <= tolerance,
                            "chunk \(index) duration is \(chunk.durationSeconds), expected \(expectedSeconds[index])")
                try require(!chunk.relativePath.hasPrefix("/") && !chunk.relativePath.split(separator: "/").contains(".."),
                            "chunk path is not safely relative")
                // Hold only one <=5.76 MB output at a time. The source fixture and
                // all chunk PCM data are never accumulated into one big buffer.
                try autoreleasepool {
                    let wav = try Data(contentsOf: directory.appendingPathComponent(chunk.relativePath), options: .mappedIfSafe)
                    let parsed = try ASRWAVAudio(wav: wav)
                    try parsed.validateForRequest()
                    let expectedFrames = Int(expectedSeconds[index]) * sampleRate
                    try require(parsed.frameCount == expectedFrames,
                                "chunk \(index) has \(parsed.frameCount) samples, expected \(expectedFrames)")
                    try require(abs(parsed.durationSeconds - chunk.durationSeconds) <= tolerance,
                                "WAV duration and chunk metadata disagree")
                    try require(parsed.wav[parsed.pcmRange].allSatisfy { $0 == 0 }, "decoded silent fixture contains unexpected nonzero samples")
                }
            }
        }

        private func writeFixture(to url: URL) throws {
            let payloadBytes = fixtureSeconds * sampleRate * 2
            var header = Data()
            func tag(_ value: String) { header.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) {
                header.append(UInt8(truncatingIfNeeded: value))
                header.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            func u32(_ value: UInt32) {
                for shift in stride(from: 0, to: 32, by: 8) { header.append(UInt8(truncatingIfNeeded: value >> shift)) }
            }
            tag("RIFF"); u32(UInt32(payloadBytes + 36)); tag("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
            u16(2); u16(16); tag("data"); u32(UInt32(payloadBytes))
            try header.write(to: url, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            let zeros = Data(count: 64 * 1_024)
            var remaining = payloadBytes
            while remaining > 0 {
                let count = min(remaining, zeros.count)
                try handle.write(contentsOf: zeros.prefix(count))
                remaining -= count
            }
            try handle.synchronize()
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
