import Foundation

/// Synthetic fixtures following the official schema; none came from a paid call.
enum ASRFixtures {
    static let tinyWAV = Data(base64Encoded: "UklGRiYAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQIAAAAAAA==")!
    static let request = #"{"model":"qwen-audio-3.0-asr-flash","input":{"messages":[{"role":"user","content":[{"type":"input_audio","input_audio":{"data":"data:audio/wav;base64,UklGRiYAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YQIAAAAAAA=="}}]}]},"parameters":{"format":"wav","sample_rate":"16000"}}"#
    static let json = #"{"output":{"sentence":{"begin_time":760,"end_time":3800,"sentence_end":true,"sentence_id":1,"channel_id":0,"text":"Hello world."},"text":"Hello world."},"usage":{"duration":4},"request_id":"fixture-json"}"#
    static let nestedJSON = #"{"output":{"output":{"sentence":{"begin_time":100,"end_time":900,"sentence_end":true,"sentence_id":1,"text":"Nested."}}},"request_id":"fixture-nested"}"#
    static let missingTimingJSON = #"{"output":{"sentence":{"sentence_end":true,"sentence_id":1,"text":"No timing supplied."}},"request_id":"fixture-untimed"}"#
    static let partialTimingJSON = #"{"output":{"sentence":{"begin_time":200,"sentence_end":true,"text":"Only a start."}}}"#
    static let fullTextJSON = #"{"output":{"sentence":{"begin_time":1500,"end_time":2000,"sentence_end":true,"text":"Second."},"text":"First. Second."}}"#
    static let sse = """
    : heartbeat
    id:1
    event:result
    :HTTP_STATUS/200
    data:{"output":{"sentence":{"sentence_id":1,"sentence_end":false,"begin_time":0,"text":"interim"}},"request_id":"fixture-sse"}

    id:2
    event:result
    data:{"output":{"sentence":{"sentence_id":1,"sentence_end":true,"begin_time":100,"end_time":900,"text":"First."}},"request_id":"fixture-sse"}

    id:3
    event:result
    data: {"output":{"output":{"sentence":{"sentence_id":2,"sentence_end":true,"begin_time":1100,"end_time":2100,"text":"第二句。"}}},"request_id":"fixture-sse"}

    data:[DONE]

    """
    static let providerError = #"{"code":"InvalidApiKey","message":"Provider detail must not be exposed or logged","request_id":"fixture-error"}"#

    static func wav(seconds: Int, sampleRate: UInt32 = 16_000, channels: UInt16 = 1,
                    bitsPerSample: UInt16 = 16, extraMetadata: Bool = false) -> Data {
        wav(pcm: Data(repeating: 0, count: seconds * Int(sampleRate) * Int(channels) * Int(bitsPerSample / 8)),
            sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample, extraMetadata: extraMetadata)
    }

    static func wav(pcm: Data, sampleRate: UInt32 = 16_000, channels: UInt16 = 1,
                    bitsPerSample: UInt16 = 16, extraMetadata: Bool = false) -> Data {
        var data = Data()
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(UInt32(pcm.count + 36 + (extraMetadata ? 12 : 0)))
        data.append(contentsOf: "WAVEfmt ".utf8); append32(16)
        let alignment = channels * bitsPerSample / 8
        append16(1); append16(channels); append32(sampleRate); append32(sampleRate * UInt32(alignment))
        append16(alignment); append16(bitsPerSample)
        if extraMetadata {
            data.append(contentsOf: "JUNK".utf8); append32(3)
            data.append(contentsOf: [0, 1, 2, 0])
        }
        data.append(contentsOf: "data".utf8); append32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
