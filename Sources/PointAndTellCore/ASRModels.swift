import Foundation

/// Provider times are milliseconds relative to the submitted audio chunk.
/// Missing times remain nil. Callers may add a chunk offset only to actual times.
public struct ASRSentence: Codable, Equatable {
    public let text: String
    public let beginTimeMilliseconds: Int?
    public let endTimeMilliseconds: Int?
    public let sentenceID: Int?
    public let channelID: Int?

    public init(text: String, beginTimeMilliseconds: Int? = nil,
                endTimeMilliseconds: Int? = nil, sentenceID: Int? = nil,
                channelID: Int? = nil) {
        self.text = text
        self.beginTimeMilliseconds = beginTimeMilliseconds
        self.endTimeMilliseconds = endTimeMilliseconds
        self.sentenceID = sentenceID
        self.channelID = channelID
    }

    public var hasCompleteTiming: Bool {
        guard let start = beginTimeMilliseconds, let end = endTimeMilliseconds else { return false }
        return start >= 0 && end >= start
    }
}

public struct ASRResult: Equatable {
    public let sentences: [ASRSentence]
    public let requestID: String?

    public init(sentences: [ASRSentence], requestID: String? = nil) {
        self.sentences = sentences
        self.requestID = requestID
    }
}

public enum ASRError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidWAV(String)
    case audioTooLong
    case encodedAudioTooLarge
    case invalidHTTPResponse
    case responseTooLarge
    case httpStatus(Int, code: String?, requestID: String?)
    case provider(code: String, requestID: String?)
    case malformedResponse
    case noFinalSentences

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Enter an ASR API key before sending audio."
        case .invalidAPIKey: return "The API key contains invalid characters."
        case .invalidWAV(let detail): return "ASR needs a valid 16 kHz, 16-bit mono PCM WAV. \(detail)"
        case .audioTooLong: return "An ASR request cannot exceed five minutes. Split the audio into approximately three-minute chunks."
        case .encodedAudioTooLarge: return "The Base64 audio exceeds the 10 MB request limit. Use smaller chunks."
        case .invalidHTTPResponse: return "The ASR service did not return an HTTP response."
        case .responseTooLarge: return "The ASR response exceeded the safe download limit. Your audio was not marked complete."
        case .httpStatus(let status, _, _): return "The ASR service returned HTTP \(status). Your audio was not marked complete."
        case .provider: return "The ASR provider rejected the request. Your audio was not marked complete."
        case .malformedResponse: return "The ASR response could not be read safely."
        case .noFinalSentences: return "The ASR response contained no finalized transcript."
        }
    }
}

/// No live provider request or credential was used while implementing this adapter.
public enum ASRProvider {
    public static let endpoint = URL(string: "https://maas.qianwenaiapi.com/api/v1/services/aigc/multimodal-generation/generation")!
    public static let model = "qwen-audio-3.0-asr-flash"
    public static let integrationVerified = false
    public static let verificationNotice = "Provider integration unverified: only offline fixtures and transport stubs have been used."
    public static let documentationURL = URL(string: "https://help.aliyun.com/en/model-studio/fun-asr-flash-recorded-speech-recognition-http-api")!
}
