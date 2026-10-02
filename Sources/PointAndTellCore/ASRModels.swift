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

/// The failing step, independent of provider text or an underlying error's userInfo.
public enum ASRFailureStage: String, Equatable {
    case requestValidation = "Request validation"
    case transport = "Transport"
    case http = "HTTP"
    case provider = "Provider"
    case responseParsing = "Response parsing"
}

public enum ASRError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidWAV(String)
    case audioTooLong
    case encodedAudioTooLarge
    case requestEncoding
    case transport(code: Int?)
    case invalidHTTPResponse
    case responseTooLarge
    case httpStatus(Int, code: String?, requestID: String?)
    case provider(code: String, requestID: String?)
    case malformedResponse
    case noFinalSentences

    public var stage: ASRFailureStage {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .invalidWAV, .audioTooLong,
             .encodedAudioTooLarge, .requestEncoding: return .requestValidation
        case .transport, .invalidHTTPResponse, .responseTooLarge: return .transport
        case .httpStatus: return .http
        case .provider: return .provider
        case .malformedResponse, .noFinalSentences: return .responseParsing
        }
    }

    /// Use this at UI/persistence boundaries rather than arbitrary localizedDescription.
    /// No underlying error text, URLs, response body or provider message is included.
    public static func safeDescription(for error: Error) -> String {
        if let error = error as? ASRError {
            return error.errorDescription ?? "ASR failed."
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return ASRError.transport(code: value.code).errorDescription ?? "ASR transport failed."
        }
        return "ASR: An unexpected error occurred. The audio was not marked complete; retry after checking the local recording."
    }

    /// Retain only a URL-loading code, never arbitrary userInfo such as failing URLs.
    /// Cancellation keeps the existing URLError contract for callers.
    static func safeTransportError(_ error: Error) -> Error {
        if let error = error as? ASRError { return error }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return ASRError.transport(code: nil) }
        if value.code == URLError.Code.cancelled.rawValue { return URLError(.cancelled) }
        return ASRError.transport(code: value.code)
    }

    public var errorDescription: String? {
        let detail: String
        switch self {
        case .missingAPIKey:
            detail = "Enter an ASR API key before sending audio."
        case .invalidAPIKey:
            detail = "The API key contains invalid characters. Paste a single-line key."
        case .invalidWAV(let reason):
            let safeReason = ASRSafeDiagnostics.wavReason(reason)
            detail = "ASR needs a valid 16 kHz, 16-bit mono PCM WAV." + (safeReason.map { " \($0)" } ?? "")
        case .audioTooLong:
            detail = "An ASR request cannot exceed five minutes. Split the audio into approximately three-minute chunks."
        case .encodedAudioTooLarge:
            detail = "The encoded audio exceeds the 10 MB request limit. Use smaller chunks."
        case .requestEncoding:
            detail = "The audio request could not be prepared. No audio was sent."
        case .transport(let code):
            detail = Self.transportDescription(code)
        case .invalidHTTPResponse:
            detail = "The service did not return an HTTP response. Check the connection and retry."
        case .responseTooLarge:
            detail = "The response exceeded the safe download limit. The audio was not marked complete."
        case .httpStatus(let status, let code, let requestID):
            let safeCode = ASRSafeDiagnostics.code(code)
            detail = "HTTP \(status)" + ASRSafeDiagnostics.metadata(code: safeCode, requestID: requestID)
                + ". " + (ASRSafeDiagnostics.providerReason(safeCode) ?? Self.httpReason(status))
        case .provider(let code, let requestID):
            let safeCode = ASRSafeDiagnostics.code(code)
            detail = "The provider rejected the request" + ASRSafeDiagnostics.metadata(code: safeCode, requestID: requestID)
                + ". " + (ASRSafeDiagnostics.providerReason(safeCode) ?? "No safe reason is available. Check service/model access and retry; the audio was not marked complete.")
        case .malformedResponse:
            detail = "The response was not valid finalized JSON/SSE. The audio was not marked complete. Check service compatibility or retry."
        case .noFinalSentences:
            detail = "The response contained no finalized transcript. Replay the local recording and check that speech is audible; silence or an incomplete response can cause this. The audio was not marked complete."
        }
        return "ASR [\(stage.rawValue)]: \(detail)"
    }

    private static func transportDescription(_ code: Int?) -> String {
        let advice: String
        switch code ?? Int.max {
        case URLError.Code.cancelled.rawValue:
            advice = "Cancelled."
        case URLError.Code.timedOut.rawValue:
            advice = "The connection timed out. Check the network and retry."
        case URLError.Code.notConnectedToInternet.rawValue:
            advice = "The network is offline. Reconnect and retry."
        case URLError.Code.networkConnectionLost.rawValue:
            advice = "The connection was interrupted. Check the network and retry."
        case URLError.Code.cannotFindHost.rawValue, URLError.Code.dnsLookupFailed.rawValue:
            advice = "The service address could not be resolved. Check the network/DNS."
        case URLError.Code.cannotConnectToHost.rawValue:
            advice = "The service could not be reached. Check the network and retry."
        case URLError.Code.secureConnectionFailed.rawValue,
             URLError.Code.serverCertificateHasBadDate.rawValue,
             URLError.Code.serverCertificateUntrusted.rawValue,
             URLError.Code.serverCertificateHasUnknownRoot.rawValue,
             URLError.Code.serverCertificateNotYetValid.rawValue,
             URLError.Code.clientCertificateRejected.rawValue,
             URLError.Code.clientCertificateRequired.rawValue:
            advice = "A secure connection could not be established. Check the system clock/network; do not disable certificate checks."
        default:
            advice = "The request could not be completed over the network. Check the connection and retry."
        }
        let identifier = code.map { " (URL error \($0))" } ?? ""
        return advice + identifier + " The audio was not marked complete."
    }

    private static func httpReason(_ status: Int) -> String {
        switch status {
        case 300..<400: return "A redirect was refused to protect the audio and key. Check the configured service endpoint."
        case 401: return "Authentication was rejected. Check the key and its service/workspace."
        case 403: return "Access was denied. Check model/service permissions for the account and workspace."
        case 413: return "The request was too large. Use a smaller audio chunk."
        case 429: return "The service limited this request. Check quota and retry later."
        case 500..<600: return "The service reported a server error. Retry later."
        default: return "The request was rejected. The audio was not marked complete; check service/model compatibility."
        }
    }
}

/// Provider messages are deliberately not decoded: even plausible error prose can
/// echo speech, request JSON or secrets. Reasons below are app-owned allowlisted text.
enum ASRSafeDiagnostics {
    private static let providerReasons: [String: String] = [
        "InvalidApiKey": "Authentication was rejected. Check the key and its service/workspace.",
        "InvalidApiKeyError": "Authentication was rejected. Check the key and its service/workspace.",
        "Unauthorized": "Authentication was rejected. Check the key and its service/workspace.",
        "AccessDenied": "Access was denied. Check the account, model and workspace permissions.",
        "Forbidden": "Access was denied. Check the account, model and workspace permissions.",
        "Model.AccessDenied": "Access to this model was denied. Check model/workspace permissions.",
        "InvalidParameter": "The service rejected a request parameter. Check the audio format and model compatibility.",
        "InvalidParameter.UnsupportedFormat": "The service rejected the audio format. Check that the local chunk is valid PCM WAV.",
        "InvalidParameter.UnsupportedAudioFormat": "The service rejected the audio format. Check that the local chunk is valid PCM WAV.",
        "InvalidParameter.AudioIsEmpty": "The service reported empty audio. Replay the recording and check microphone capture.",
        "InvalidParameter.AudioTooLong": "The service rejected the audio length. Use smaller chunks.",
        "MissingParameter": "The service reported a missing parameter. Check model/API compatibility.",
        "DataInspectionFailed": "The service rejected the submitted content under its content policy.",
        "Throttling": "The service limited this request. Wait before retrying.",
        "Throttling.RateQuota": "The service rate limit was reached. Wait before retrying.",
        "Throttling.AllocationQuota": "The service quota was reached. Check the account quota.",
        "Throttling.AllocationQuotaExhausted": "The service quota was exhausted. Check the account quota.",
        "QuotaExhausted": "The service quota was exhausted. Check the account quota.",
        "Arrearage": "The service reported an account billing restriction. Check the account status.",
        "ModelNotFound": "The service could not find this model. Check model/workspace compatibility.",
        "Model.NotFound": "The service could not find this model. Check model/workspace compatibility.",
        "InvalidModel": "The service rejected the model selection. Check model/workspace compatibility.",
        "InternalError": "The provider reported an internal error. Retry later.",
        "InternalError.Algo": "The provider could not process the audio. Check the recording and retry.",
        "ServiceUnavailable": "The provider is temporarily unavailable. Retry later.",
        "RequestTimeout": "The provider timed out while processing the request. Retry later."
    ]

    static func providerReason(_ code: String?) -> String? {
        guard let code = code else { return nil }
        return providerReasons[code]
    }

    /// Unknown codes are omitted rather than trusting a token-shaped echoed secret.
    static func code(_ value: String?, redactingSecrets: [String] = []) -> String? {
        guard let value = value, value.utf8.count <= 64,
              !containsSecret(value, secrets: redactingSecrets),
              providerReasons[value] != nil else { return nil }
        return value
    }

    /// Reject the whole value rather than extracting a "safe" fragment from a URL,
    /// JSON, audio data URI or credential. Never truncate a secret into a visible ID.
    static func requestID(_ value: String?, redactingSecrets: [String] = []) -> String? {
        guard let value = value, !value.isEmpty, value.utf8.count <= 96,
              !containsSecret(value, secrets: redactingSecrets) else { return nil }
        let lower = value.lowercased()
        guard !["sk-", "sk_", "bearer", "data", "authorization", "base64", "uklg"]
            .contains(where: { lower.hasPrefix($0) }) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Long opaque payloads are omitted; UUIDs and short segmented request IDs remain.
        let parts = value.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard !parts.isEmpty, parts.allSatisfy({ $0.count <= 32 }) else { return nil }
        if parts.count == 1 {
            let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
            let digits = CharacterSet.decimalDigits
            let shortID = value.count <= 16 && value.unicodeScalars.contains(where: { digits.contains($0) })
            let hexID = value.count == 32 && value.unicodeScalars.allSatisfy({ hex.contains($0) })
            guard shortID || hexID else { return nil }
        }
        return value
    }

    static func metadata(code: String?, requestID: String?) -> String {
        var detail = ""
        if let code = self.code(code) { detail += "; code \(code)" }
        if let requestID = self.requestID(requestID) { detail += "; request ID \(requestID)" }
        return detail
    }

    private static func containsSecret(_ value: String, secrets: [String]) -> Bool {
        let lower = value.lowercased()
        return secrets.contains {
            let secret = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !secret.isEmpty else { return false }
            let encoded = Data(secret.utf8).base64EncodedString().lowercased()
            return lower.contains(secret.lowercased()) || lower.contains(encoded)
        }
    }

    static func wavReason(_ value: String) -> String? {
        let reasons: Set<String> = [
            "The RIFF/WAVE header is missing.",
            "The RIFF length is inconsistent.",
            "A chunk header is truncated.",
            "A chunk is truncated.",
            "The audio format is not 16 kHz, 16-bit mono PCM.",
            "The PCM data must contain complete 16-bit samples.",
            "A chunk padding byte is missing.",
            "A format or audio chunk is missing."
        ]
        return reasons.contains(value) ? value : nil
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
