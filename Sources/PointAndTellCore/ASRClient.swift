import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ASRCancellable: AnyObject {
    func cancel()
}

public struct ASRHTTPResponse {
    public let statusCode: Int
    public let data: Data
    public let contentType: String?

    public init(statusCode: Int, data: Data, contentType: String? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.contentType = contentType
    }
}

public protocol ASRTransport {
    @discardableResult
    func send(_ request: URLRequest,
              completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) -> ASRCancellable
}

public enum ASRRequestBuilder {
    public static func makeRequest(wav: Data, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRError.missingAPIKey }
        // Header injection and accidentally pasted multiline keys are rejected.
        guard key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw ASRError.invalidAPIKey
        }
        let audio = try ASRWAVAudio(wav: wav)
        try audio.validateForRequest()
        let dataURI = ASRWAVAudio.dataURIPrefix + wav.base64EncodedString()
        let body: [String: Any] = [
            "model": ASRProvider.model,
            "input": ["messages": [[
                "role": "user",
                "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]
            ]]],
            "parameters": ["format": "wav", "sample_rate": "16000"]
        ]
        var request = URLRequest(url: ASRProvider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Qwen 3.0 publishes every final sentence's word timestamps in SSE for
        // audio >= 60 seconds. Non-streaming output.sentence may only describe
        // the last sentence, so disabling SSE loses the earlier timeline.
        let streamedTimeline = audio.durationSeconds >= 60
        request.setValue(streamedTimeline ? "enable" : "disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.setValue(streamedTimeline ? "text/event-stream, application/json" : "application/json", forHTTPHeaderField: "Accept")
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        catch { throw ASRError.requestEncoding }
        return request
    }
}

/// macOS 11-compatible delegate transport; no async URLSession APIs.
/// Each request buffers at most 8 MiB before JSON/SSE normalization. Oversized
/// bodies fail explicitly, including servers that omit or lie about Content-Length.
public final class ASRURLSessionTransport: ASRTransport {
    public static let defaultMaximumResponseBytes = 8 * 1_024 * 1_024
    private let configuration: URLSessionConfiguration
    public let maximumResponseBytes: Int

    /// A smaller cap can be supplied for tests. The production safety cap cannot
    /// be raised through this initializer.
    public init(configuration: URLSessionConfiguration = .ephemeral,
                maximumResponseBytes: Int = ASRURLSessionTransport.defaultMaximumResponseBytes) {
        let isolated = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCredentialStorage = nil
        isolated.timeoutIntervalForResource = 600
        self.configuration = isolated
        self.maximumResponseBytes = max(1, min(maximumResponseBytes, Self.defaultMaximumResponseBytes))
    }

    @discardableResult
    public func send(_ request: URLRequest,
                     completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) -> ASRCancellable {
        let operation = ASRURLSessionRequest(maximumResponseBytes: maximumResponseBytes, completion: completion)
        operation.start(request, configuration: configuration)
        return operation
    }
}

/// URLSession retains its delegate for the lifetime of a request. Every terminal
/// path clears the stored session and invalidates it, breaking that ownership
/// cycle. The lock also serializes explicit cancellation against delegate callbacks.
final class ASRURLSessionRequest: NSObject, URLSessionDataDelegate, ASRCancellable, @unchecked Sendable {
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var buffer = Data()
    private var completion: ((Result<ASRHTTPResponse, Error>) -> Void)?

    init(maximumResponseBytes: Int, completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) {
        self.maximumResponseBytes = maximumResponseBytes
        self.completion = completion
        super.init()
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        lock.lock()
        let isActive = completion != nil
        if isActive { self.session = session; self.task = task }
        lock.unlock()
        if isActive { task.resume() } else { session.invalidateAndCancel() }
    }

    func cancel() { finish(.failure(URLError(.cancelled))) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            finish(.failure(ASRError.invalidHTTPResponse))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            finish(.failure(ASRError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let isActive = completion != nil
        if isActive { self.response = httpResponse }
        lock.unlock()
        completionHandler(isActive ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        // Subtraction avoids overflow and no bytes beyond the cap are appended.
        let exceedsLimit = data.count > maximumResponseBytes - buffer.count
        if !exceedsLimit { buffer.append(data) }
        lock.unlock()
        if exceedsLimit { finish(.failure(ASRError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard completion != nil else { lock.unlock(); return }
        let response = self.response
        let data = buffer
        lock.unlock()
        if let error = error { finish(.failure(error)); return }
        guard let response = response else { finish(.failure(ASRError.invalidHTTPResponse)); return }
        finish(.success(ASRHTTPResponse(statusCode: response.statusCode, data: data,
                                       contentType: response.value(forHTTPHeaderField: "Content-Type"))))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the user's audio or key to a redirected destination.
        // The original 3xx response is returned and ASRClient treats it as failure.
        completionHandler(nil)
    }

    private func finish(_ result: Result<ASRHTTPResponse, Error>) {
        lock.lock()
        guard let callback = completion else { lock.unlock(); return }
        completion = nil
        let session = self.session
        self.session = nil
        task = nil
        response = nil
        buffer = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        callback(result)
    }
}

public final class ASRClient {
    private let transport: ASRTransport
    private let callbackQueue: DispatchQueue

    public init(transport: ASRTransport = ASRURLSessionTransport(), callbackQueue: DispatchQueue = .main) {
        self.transport = transport
        self.callbackQueue = callbackQueue
    }

    /// Sends exactly one normalized audio chunk. Never retries automatically;
    /// job persistence and explicit retry decisions belong to the caller.
    @discardableResult
    public func transcribe(wav: Data, apiKey: String,
                           completion: @escaping (Result<[ASRSentence], Error>) -> Void) -> ASRCancellable {
        let operation = ASROperation(queue: callbackQueue, completion: completion)
        do {
            let request = try ASRRequestBuilder.makeRequest(wav: wav, apiKey: apiKey)
            let task = transport.send(request) { result in
                let parsed: Result<[ASRSentence], Error> = result.mapError { ASRError.safeTransportError($0) }.flatMap { response in
                    guard (200..<300).contains(response.statusCode) else {
                        let metadata = ASRResponseParser.errorMetadata(response.data, redactingSecrets: [apiKey])
                        return .failure(ASRError.httpStatus(response.statusCode, code: metadata.code, requestID: metadata.requestID))
                    }
                    return Result {
                        try ASRResponseParser.parse(data: response.data, contentType: response.contentType,
                                                    redactingSecrets: [apiKey]).validatedSentences()
                    }
                }
                operation.finish(parsed)
            }
            operation.attach(task)
        } catch { operation.finish(.failure(error)) }
        return operation
    }
}

private final class ASROperation: ASRCancellable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var completion: ((Result<[ASRSentence], Error>) -> Void)?
    private var task: ASRCancellable?

    init(queue: DispatchQueue, completion: @escaping (Result<[ASRSentence], Error>) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    func attach(_ task: ASRCancellable) {
        lock.lock()
        let alreadyFinished = completion == nil
        if !alreadyFinished { self.task = task }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<[ASRSentence], Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        task = nil
        lock.unlock()
        if let callback = callback { queue.async { callback(result) } }
    }

    func cancel() {
        lock.lock()
        let callback = completion
        let pendingTask = task
        completion = nil
        task = nil
        lock.unlock()
        pendingTask?.cancel()
        if let callback = callback { queue.async { callback(.failure(URLError(.cancelled))) } }
    }
}
