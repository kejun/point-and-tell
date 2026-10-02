import Foundation

/// Normalizes JSON and SSE replies without inventing sentence or word timing.
/// SSE is buffered by the callback transport; only sentence_end:true events are retained.
public enum ASRResponseParser {
    public static func parse(data: Data, contentType: String? = nil,
                             redactingSecrets: [String] = []) throws -> ASRResult {
        guard var body = String(data: data, encoding: .utf8) else { throw ASRError.malformedResponse }
        if body.first == "\u{FEFF}" { body.removeFirst() }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ASRError.malformedResponse }
        // Sniff JSON first: short clips can return JSON despite the SSE request header.
        if trimmed.hasPrefix("{") {
            return try parseJSON(Data(trimmed.utf8), redactingSecrets: redactingSecrets)
        }
        let isSSE = contentType?.lowercased().contains("text/event-stream") == true
            || trimmed.hasPrefix("data:") || trimmed.hasPrefix("event:")
            || trimmed.hasPrefix("id:") || trimmed.hasPrefix(":")
        guard isSSE else { throw ASRError.malformedResponse }
        return try parseSSE(body, redactingSecrets: redactingSecrets)
    }

    static func errorMetadata(_ data: Data, redactingSecrets: [String] = []) -> (code: String?, requestID: String?) {
        // Error metadata must survive a malformed/irrelevant output field, but no
        // provider "message" is decoded or retained because it may echo the request.
        guard let value = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { return (nil, nil) }
        return (ASRSafeDiagnostics.code(value.code, redactingSecrets: redactingSecrets),
                ASRSafeDiagnostics.requestID(value.requestID, redactingSecrets: redactingSecrets))
    }

    private static func decode(_ data: Data, redactingSecrets: [String]) throws -> Envelope {
        if let metadata = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let code = metadata.code, !code.isEmpty {
            throw ASRError.provider(
                code: ASRSafeDiagnostics.code(code, redactingSecrets: redactingSecrets) ?? "UnrecognizedProviderError",
                requestID: ASRSafeDiagnostics.requestID(metadata.requestID, redactingSecrets: redactingSecrets))
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ASRError.malformedResponse }
        return envelope
    }

    private static func parseJSON(_ data: Data, redactingSecrets: [String]) throws -> ASRResult {
        let envelope = try decode(data, redactingSecrets: redactingSecrets)
        guard let output = envelope.output else { throw ASRError.malformedResponse }
        if let payloads = output.sentences ?? output.output?.sentences, !payloads.isEmpty {
            let sentences = try payloads.filter { $0.sentenceEnd != false }.map { try normalized($0) }
            guard !sentences.isEmpty else { throw ASRError.noFinalSentences }
            if let fullText = output.text ?? output.output?.text,
               fullText.filter({ !$0.isWhitespace }) != sentences.map(\.text).joined().filter({ !$0.isWhitespace }) {
                return ASRResult(sentences: [ASRSentence(text: fullText)])
            }
            return ASRResult(sentences: sentences, requestID: ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets))
        }
        if let payload = output.sentence ?? output.output?.sentence {
            guard payload.sentenceEnd != false else { throw ASRError.noFinalSentences }
            let sentence = try normalized(payload)
            if let fullText = output.text ?? output.output?.text,
               !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                != sentence.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Non-streaming output.sentence can describe only the last sentence.
                // Retain a verified final sentence's timing, but never apply it to the prefix.
                let tail = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let complete = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty, complete.hasSuffix(tail), fullText.hasSuffix(sentence.text) {
                    let prefix = String(fullText.dropLast(sentence.text.count))
                    return ASRResult(sentences: [ASRSentence(text: prefix), sentence],
                                     requestID: ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets))
                }
                return ASRResult(sentences: [ASRSentence(text: fullText)], requestID: ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets))
            }
            guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ASRError.noFinalSentences }
            return ASRResult(sentences: [sentence], requestID: ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets))
        }
        // Some JSON variants provide only complete text. Keep it explicitly untimed.
        if let text = output.text ?? output.output?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ASRResult(sentences: [ASRSentence(text: text)], requestID: ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets))
        }
        throw ASRError.noFinalSentences
    }

    private static func parseSSE(_ body: String, redactingSecrets: [String]) throws -> ASRResult {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var dataLines: [String] = []
        var sentences: [ASRSentence] = []
        var identityIndexes: [String: Int] = [:]
        var requestID: String?
        var sawPayload = false

        func flush() throws {
            guard !dataLines.isEmpty else { return }
            let json = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            if json.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return }
            let envelope = try decode(Data(json.utf8), redactingSecrets: redactingSecrets)
            sawPayload = true
            requestID = ASRSafeDiagnostics.requestID(envelope.requestID, redactingSecrets: redactingSecrets) ?? requestID
            guard let output = envelope.output else { throw ASRError.malformedResponse }
            guard let payload = output.sentence ?? output.output?.sentence else { return }
            guard payload.sentenceEnd == true else { return }
            let sentence = try normalized(payload)
            guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let identifier = sentence.sentenceID {
                let identity = "\(sentence.channelID ?? 0):\(identifier)"
                if let index = identityIndexes[identity] { sentences[index] = sentence }
                else { identityIndexes[identity] = sentences.count; sentences.append(sentence) }
            } else if !sentences.contains(sentence) {
                sentences.append(sentence)
            }
        }

        for line in lines {
            if line.isEmpty { try flush(); continue }
            if line.hasPrefix(":") { continue }
            // SSE permits a single optional space following the field colon.
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.first == " " { value.removeFirst() }
                dataLines.append(value)
            } else if line == "data" { dataLines.append("") }
            // event, retry and id fields are metadata, never transcript content.
        }
        try flush() // Accept the provider's final event without a trailing blank line.
        guard sawPayload else { throw ASRError.malformedResponse }
        guard !sentences.isEmpty else { throw ASRError.noFinalSentences }
        return ASRResult(sentences: sentences, requestID: requestID)
    }

    private static func normalized(_ payload: SentencePayload) throws -> ASRSentence {
        guard let text = payload.text else { throw ASRError.malformedResponse }
        // Invalid timing invalidates the response instead of creating plausible timestamps.
        if let begin = payload.beginTime, begin < 0 { throw ASRError.malformedResponse }
        if let end = payload.endTime, end < 0 { throw ASRError.malformedResponse }
        if let begin = payload.beginTime, let end = payload.endTime, end < begin {
            throw ASRError.malformedResponse
        }
        return ASRSentence(text: text, beginTimeMilliseconds: payload.beginTime,
                           endTimeMilliseconds: payload.endTime,
                           sentenceID: payload.sentenceID, channelID: payload.channelID,
                           words: normalizedWords(payload))
    }

    private static func normalizedWords(_ payload: SentencePayload) -> [ASRWord]? {
        guard let words = payload.words, !words.isEmpty else { return nil }
        var result: [ASRWord] = []
        for word in words {
            guard word.fixed != false, let text = word.text, !text.isEmpty,
                  let start = word.beginTime, let end = word.endTime,
                  start >= 0, end >= start,
                  start >= (payload.beginTime ?? 0), end <= (payload.endTime ?? Int.max),
                  start >= (result.last?.beginTimeMilliseconds ?? 0),
                  end >= (result.last?.endTimeMilliseconds ?? 0) else { return nil }
            let punctuation = word.punctuation ?? ""
            result.append(ASRWord(text: text.hasSuffix(punctuation) ? text : text + punctuation,
                                  beginTimeMilliseconds: start, endTimeMilliseconds: end))
        }
        return result
    }

    private struct ErrorEnvelope: Decodable {
        let code: String?
        let requestID: String?
        enum CodingKeys: String, CodingKey { case code; case requestID = "request_id" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decode(String.self, forKey: .code)
            requestID = try? container.decode(String.self, forKey: .requestID)
        }
    }

    private struct Envelope: Decodable {
        let output: Output?
        let code: String?
        let requestID: String?
        enum CodingKeys: String, CodingKey { case output, code; case requestID = "request_id" }
    }
    private struct Output: Decodable {
        let sentence: SentencePayload?
        let sentences: [SentencePayload]?
        let text: String?
        let output: InnerOutput?
    }
    private struct InnerOutput: Decodable {
        let sentence: SentencePayload?
        let sentences: [SentencePayload]?
        let text: String?
    }
    private struct SentencePayload: Decodable {
        let text: String?
        let sentenceEnd: Bool?
        let sentenceID: Int?
        let channelID: Int?
        let beginTime: Int?
        let endTime: Int?
        let words: [WordPayload]?
        enum CodingKeys: String, CodingKey {
            case text, words
            case sentenceEnd = "sentence_end", sentenceID = "sentence_id", channelID = "channel_id"
            case beginTime = "begin_time", endTime = "end_time"
        }
    }
    private struct WordPayload: Decodable {
        let text: String?
        let punctuation: String?
        let fixed: Bool?
        let beginTime: Int?
        let endTime: Int?
        enum CodingKeys: String, CodingKey {
            case text, punctuation, fixed
            case beginTime = "begin_time", endTime = "end_time"
        }
    }
}
